# How-to: 并发模式
[English](../howto/concurrency.md) · **简体中文**

PAR 的并发有 3 个层次，由外到内：

## 1. 多个 agent 并行

最外层——独立 agent 任务同时跑：

```ocaml
Eio.Switch.run (fun sw ->
  let rt = Runtime.create ~config ... sw in
  (* 启动 3 个独立 agent *)
  let results = Eio.Fiber.all [
    fun () -> Runtime.invoke rt "agent-a" "task 1";
    fun () -> Runtime.invoke rt "agent-b" "task 2";
    fun () -> Runtime.invoke rt "agent-c" "task 3";
  ] in
  (* results 是 [(result_a, error_b, result_c) ...] *)
  List.iter (function
    | Ok r -> Printf.printf "OK: %s\n" r
    | Error e -> Printf.printf "FAIL: %s\n" (error_to_string e)) results
)
```

**注意**：`Eio.Fiber.all` 是结构化并发——一个 fiber 失败，switch cancel 全部。如果你要"fire-and-forget 独立"，用 `Eio.Fiber.fork` 各自管理生命周期。

## 2. 同一 agent 的多次 invoke

如果同一个 agent 收到多个独立问题（比如批量处理）：

```ocaml
let inputs = ["问题 1"; "问题 2"; ...; "问题 N"] in
let tasks = List.map (fun input ->
  fun () -> Runtime.invoke rt agent_id input
) inputs in
let results = Eio.Fiber.all tasks in
```

`Runtime` 内部有 `task_semaphore`（`runtime_config.default_quota.max_concurrent_tasks`），自动限流不会撑爆。

## 3. 并行 tool 调用（v0.3.0+）

当 LLM 一次返回多个 tool_call 时（典型："先 search 再 fetch"），PAR 默认**并行执行**：

```ocaml
(* runtime_config.parallel_tool_execution = true (默认) *)
(* ReAct 循环一次 LLM 响应触发 → 并发跑所有 tool_call → 串行回填结果 *)
```

**关掉**（如果 LLM 响应里 tool_call 有依赖关系）：

```ocaml
let config = {
  ...
  parallel_tool_execution = false;  (* 串行执行 tool *)
  ...
}
```

**细粒度控制**——单个 tool 标 `concurrency_limit`：

```ocaml
let my_tool = { descriptor = {
  name = "expensive_db_query";
  ...
  concurrency_limit = Some 2;  (* 同时最多 2 个并发 *)
}; handler = ... } in
Runtime.register_tool rt my_tool;
```

## 4. bash 工具并发（v0.3.1）

bash 工具默认 `concurrency_limit = Some 4`（同 agent 最多 4 个 bash 并发）。这是 v0.3.1 故意设的——bash 子进程重，4 个就够并行 LLM 工作流了。

**v0.3.1 加**：`sandboxed_path` 抽象保证不同 bash 调用的 cwd 不会冲突。

## 5. 限流（rate limit）

`lib/middleware/rate_limit.ml` 提供 token-bucket 限流：

```ocaml
(* 全局：每秒最多 60 次 LLM 调用 *)
let config = {
  ...
  middleware = [Par_middleware.rate_limit ~max_requests:60 ~window_seconds:1.0 ()];
}
```

或 per-agent：

```ocaml
let agent = {
  ...
  middleware = [Par_middleware.rate_limit ~max_requests:10 ~window_seconds:1.0 ()];
}
```

## 6. Workflow 内的并发

`lib/core/workflow.ml` 支持 sequential / parallel / map-reduce：

```ocaml
let workflow = {
  id = "fan-out-fan-in";
  steps = [
    Parallel [
      Tool_call { tool_name = "fetch_url"; input = `Assoc [...url_a...] };
      Tool_call { tool_name = "fetch_url"; input = `Assoc [...url_b...] };
      Tool_call { tool_name = "fetch_url"; input = `Assoc [...url_c...] };
    ];
    Map_reduce {
      over = Expression.Variable "results";
      step = Tool_call { tool_name = "summarize"; input = ... };
      reduce = Expression.Call (Variable "concat", [Variable "acc"; Variable "item"]);
    };
  ];
}
```

`Parallel` 并发跑，`Map_reduce` 串行 reduce。详细看 [docs/sdk/workflow.md](../sdk/workflow.md)。

## 反模式

- **不要** 在 tool handler 里手动 `Thread.create`——会脱离 Eio switch 的取消控制
- **不要** 用 `Lwt` 或 `Async`——PAR 整个栈是 Eio，混进 Lwt 会死锁
- **不要** 给 `concurrency_limit = None`（除非你 100% 确定没风险）——OOM 风险
