<!-- language: zh -->

[English](../../sdk/invoke_context.md) · **简体中文**

# invoke_context — 每次调用隔离

## 概览

当多个 `Runtime.invoke` 调用在同一个运行时上并发执行时，每次调用都需要独立的隔离状态：session id、metrics、工具调用 hooks、skill 快照和转向队列。如果没有隔离，一次调用的 hooks 会泄漏到另一次，metrics 会在不同 session 间混合，一次调用的 system prompt appendix 也会流入下一次调用。

`Invoke_context` 模块通过 Eio 的 fiber-local 绑定解决这个问题。每次 `Runtime.invoke` 都会获得一个全新的 `invoke_context` 记录，使用 `Eio.Fiber.with_binding` 绑定到调用 fiber 上。这个绑定会自动传播到 Engine 并行工具分发所生成的子 fiber，因此同一调用内并发运行的工具共享相同的上下文，同时与其他调用保持隔离。

该模块是 v0.7.1 发布的并发架构的一部分，采用混合载体模型：每次调用的状态存储在通过 fiber-local 传递的记录中，而非通过函数参数逐层传递。

## invoke_context 类型

```ocaml
type invoke_context = private {
  session_id : string;
  metrics_accumulator : Metrics.counters;
  user_activated_skills_snapshot : string list;
  tool_call_hooks_snapshot : Hook.tool_call_hook list;
  steering_queue : Steering_queue.t;
  followup_queue : Steering_queue.t;
  system_prompt_appendix : string option;
}
```

该类型是 `private` 的，意味着你可以读取字段但不能直接构造记录。请使用 `Invoke_context.create` 构造。

| 字段 | 说明 |
|------|------|
| `session_id` | 标识对话会话。记忆工具用它做范围隔离。 |
| `metrics_accumulator` | 每次调用的计数器（LLM 调用次数、工具调用次数、任务完成数）。 |
| `user_activated_skills_snapshot` | 此次调用时激活的 skill id，入口处快照。 |
| `tool_call_hooks_snapshot` | 此次调用时激活的工具调用 hooks，入口处快照。 |
| `steering_queue` | 调用过程中的转向指令队列。 |
| `followup_queue` | 当前轮次结束后追加的后续消息队列。 |
| `system_prompt_appendix` | 此次调用追加到 system prompt 的可选文本。 |

### create

```ocaml
val create :
  ?session_id:string ->
  ?metrics:Metrics.counters ->
  ?hooks:Hook.tool_call_hook list ->
  ?skills:string list ->
  ?steering:Steering_queue.t ->
  ?followup:Steering_queue.t ->
  ?system_prompt_appendix:string ->
  unit ->
  invoke_context
```

构造一个全新的 `invoke_context`。所有可选参数默认为空值：`session_id` 为 `"unknown"`，列表为 `[]`，队列为空队列，`system_prompt_appendix` 为 `None`。

你很少需要直接调用 `create`。`Runtime.invoke` 内部从运行时当前状态构造上下文。此函数暴露出来用于高级场景，比如测试或构建自定义分发循环。

## 每次调用隔离

### 工作原理

当 `Runtime.invoke` 被调用时，它：

1. 将运行时的当前状态（session id、hooks、skills）快照到一个新的 `invoke_context` 中。
2. 使用 `Invoke_context.with_context` 将该上下文绑定到调用 fiber（底层使用 `Eio.Fiber.with_binding`）。
3. 在该绑定范围内运行 ReAct 循环。

绑定会自动传播。当 Engine 的并行工具分发通过 `Eio.Fiber.fork_promise` 生成子 fiber 时，这些子 fiber 继承相同的 `invoke_context`。这意味着同一调用内的所有工具看到相同的 session id、相同的 hooks 和相同的 metrics 计数器。

### 重入安全性

因为每次 `Runtime.invoke` 都创建自己的上下文，同一运行时上的两次并发调用不会互相干扰。调用 A 的 metrics 留在调用 A 的计数器中。调用 B 的转向队列与调用 A 的不同。调用 A 的 session id 不会泄漏到调用 B。

这是让 `Runtime.invoke` 安全支持重入的核心保证：在工具处理器内调用 invoke、在 fiber 中调用、或多线程同时调用都是安全的。

### 访问当前上下文

在工具处理器、中间件或任何运行在 `invoke` 调用内的代码中，使用 `get_current` 或 `get_current_exn` 读取绑定的上下文：

```ocaml
val get_current : unit -> invoke_context option
val get_current_exn : unit -> invoke_context
```

`get_current` 在没有绑定上下文时返回 `None`（例如，在 `Runtime.invoke` 外运行的代码）。用于在载体迁移前的代码路径中优雅降级。

`get_current_exn` 在没有上下文时抛出 `Failure`。用于热路径，那里绑定必须存在，因为缺失表示编程错误（在不通过 `Runtime.invoke` 的情况下调用仅限 invoke 的代码）。

### with_context

```ocaml
val with_context : invoke_context -> (unit -> 'a) -> 'a
```

将 `ctx` 绑定到 `f` 的执行期间。绑定会传播到 `f` 内 fork 的所有 fiber。这是 `Runtime.invoke` 内部使用的基础原语。你也可以直接使用它来构建自定义执行上下文，比如在测试中模拟特定的 session id：

```ocaml
let ctx = Invoke_context.create ~session_id:"test-session-42" () in
Invoke_context.with_context ctx (fun () ->
  let current = Invoke_context.get_current_exn () in
  assert (current.session_id = "test-session-42")
)
```

## invoke_async — 后台执行

`Runtime.invoke_async` 在后台 fiber 中运行调用，立即返回一个句柄，你可以用它来等待、取消或轮询结果。

### 签名

```ocaml
val Runtime.invoke_async :
  runtime ->
  agent_id:string ->
  message:string ->
  ?workspace:Workspace.workspace ->
  ?cancellation_token:cancellation_token ->
  ?conversation:conversation ->
  ?on_tool_event:(event -> unit) ->
  ?on_chunk:(llm_response_chunk -> unit) option ->
  ?enable_handoff:bool ->
  ?system_prompt_appendix:string ->
  ?context:Invoke_context.invoke_context ->
  unit ->
  Invoke_context.invoke_handle
```

签名与 `Runtime.invoke` 相同，只是返回类型不同：不是阻塞到完成，而是立即返回一个 `invoke_handle`。

### invoke_handle 类型

```ocaml
type invoke_handle  (* 不透明类型 *)

val invoke_handle_await :
  invoke_handle ->
  (invoke_result, error_category * conversation) result

val invoke_handle_cancel : invoke_handle -> unit

val invoke_handle_status : invoke_handle -> invoke_status

val invoke_handle_token : invoke_handle -> cancellation_token
```

| 函数 | 说明 |
|------|------|
| `invoke_handle_await` | 阻塞直到调用到达终止状态并返回结果。 |
| `invoke_handle_cancel` | 请求取消。幂等操作。fiber 在下一次检查时观察到取消并终止。 |
| `invoke_handle_status` | 非阻塞地轮询当前状态。 |
| `invoke_handle_token` | 返回支撑此句柄的取消令牌。用于与父 switch 组合。 |

`invoke_status` 类型跟踪后台 fiber 的生命周期：

```ocaml
type invoke_status = Running | Completed | Cancelled | Failed
```

### 示例：并发分发两个 agent

```ocaml
open Par

let parallel_agents rt =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun switch ->
      let h1 = Runtime.invoke_async rt
        ~agent_id:"researcher"
        ~message:"查找关于 OCaml effects 的最新论文" () in
      let h2 = Runtime.invoke_async rt
        ~agent_id:"summarizer"
        ~message:"总结 Eio 库的文档" () in
      (* 两者并发运行；分别等待 *)
      match Invoke_context.invoke_handle_await h1,
            Invoke_context.invoke_handle_await h2 with
      | Ok r1, Ok r2 ->
        Printf.printf "Research: %s\nSummary: %s\n"
          (result_text r1) (result_text r2)
      | Error (e1, _), _ -> Printf.eprintf "Agent 1 failed\n"
      | _, Error (e2, _) -> Printf.eprintf "Agent 2 failed\n"
    )
  )
```

### 从外部取消

```ocaml
let h = Runtime.invoke_async rt ~agent_id:"slow-agent"
  ~message:"执行耗时操作" () in
(* 用户可能改变了主意 *)
Invoke_context.invoke_handle_cancel h;
match Invoke_context.invoke_handle_status h with
| Invoke_context.Cancelled -> Printf.printf "已取消\n"
| _ -> Printf.printf "仍在运行或已完成\n"
```

## 自定义上下文

`Runtime.invoke` 和 `Runtime.invoke_async` 都接受一个可选的 `?context` 参数：

```ocaml
val Runtime.invoke :
  runtime ->
  agent_id:string ->
  message:string ->
  ...
  ?context:Invoke_context.invoke_context ->
  unit ->
  (invoke_result, error_category * conversation) result
```

提供时，运行时使用此上下文而不是创建新的。这让你能显式控制 session id、system prompt appendix 和其他每次调用的状态。

### 何时使用自定义上下文

- **Session 固定**：强制多次 invoke 共享相同的 session id，保持对话连续性。
- **测试**：使用已知 session id 创建上下文，测试记忆范围隔离或 metrics 隔离。
- **System prompt 注入**：在上下文中附加 `system_prompt_appendix`，注入每轮动态内容。

### 默认行为

省略 `?context`（常见情况）时，`Runtime.invoke` 内部构造一个全新的 `invoke_context`。session id 默认为 `"unknown"`（除非之前调用了 `Runtime.set_session_id`），hooks 和 skills 从运行时当前状态快照，`system_prompt_appendix` 为 `None`。

## 动态 System Prompt

`?system_prompt_appendix` 参数让你为单次调用注入文本到 system prompt，而无需修改 agent 的配置。

```ocaml
val Runtime.invoke :
  runtime ->
  agent_id:string ->
  message:string ->
  ...
  ?system_prompt_appendix:string ->
  ...
```

### 在提示中的位置

appendix 追加在基础 system prompt、skill overlay 和工具后缀**之后**。最终 system prompt 的组装顺序为：

1. 基础 system prompt（来自 `agent_config.system_prompt` 或渲染后的 `system_prompt_template`）
2. Skill overlay（来自活跃 skill 的 `system_prompt_override`）
3. 工具后缀（格式化的可用工具列表）
4. **System prompt appendix**（来自 `?system_prompt_appendix` 或 `invoke_context.system_prompt_appendix`）

### 示例：注入时间敏感上下文

```ocaml
let now = Unix.gettimeofday () in
let time_str = Unix.(gmtime now) |> fun tm ->
  Printf.sprintf "%04d-%02d-%02d %02d:%02d UTC"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min in
let appendix = Printf.sprintf "Current time: %s. Use this for time-sensitive decisions." time_str in
Runtime.invoke rt ~agent_id:"analyst"
  ~message:"今天发生了什么？" ~system_prompt_appendix:appendix ()
```

该参数同样适用于 `invoke_async` 和 `invoke_generate`。当同时提供 `?context` 且该上下文有自己的 `system_prompt_appendix` 时，显式的 `?system_prompt_appendix` 参数优先。

## Appendix 文本辅助函数

```ocaml
val Invoke_context.appendix_text : unit -> string
```

从当前 invoke context 中返回 `system_prompt_appendix`，有值时前缀 `"\n\n"`，无上下文或无 appendix 时返回 `""`。内部由 prompt 构建器使用，用于干净地追加 appendix 文本。

## 另请参阅

- [Agent API](agent.md) — `Runtime.invoke`、agent 配置、工具注册
- [Memory API](memory.md) — 记忆工具使用 `Invoke_context.get_current_exn().session_id` 做范围隔离
- [并发模型](../../explanation/concurrency-model.md) — Eio 结构化并发在 PAR 中的工作原理
- [How-to: 并发](../../howto/concurrency.md) — 实用并发模式
