# 并行多 Agent 分发 API 参考

[English](https://github.com/jcz2020/par/blob/main/sdk/parallel.md) · **简体中文**

> 源码真相：`lib/core/runtime.ml`、`lib/core/types.ml`、`lib/core/workflow_engine.ml`。

本文档涵盖 `Runtime.invoke_parallel`，这是在单个 Runtime 内并发分发多个 Agent 的便捷 API。每个 Agent 在独立的 Eio fiber 中运行，拥有隔离的工具注册表，结果会被收集并可选择性合并。

## 概述

并行分发解决了"扇出-扇入"模式：对 N 个 Agent 运行不同输入（或相同输入不同配置），收集结果，合并为单一输出。这是 LangGraph `Send` 或 CrewAI `and_()` 的 OCaml 等价物。

```ocaml
val Runtime.invoke_parallel :
  rt:runtime ->
  specs:agent_dispatch_spec list ->
  ?parallel_limit:int ->
  ?failure_policy:failure_policy ->
  ?merge_fn:(Yojson.Safe.t list -> Yojson.Safe.t) ->
  ?cancellation_token:Eio.Switch.t ->
  unit ->
  parallel_invoke_result
```

## `agent_dispatch_spec`

每个 Agent 的并行分发配置：

```ocaml
type agent_dispatch_spec = {
  agent_id          : string;
  input             : string option;
  workspace         : Workspace.workspace option;
  approval_handler  : Approval.approval_handler option;
  blocking_approval : bool;
}
```

| 字段 | 描述 |
|------|------|
| `agent_id` | 必填。要分发的 Agent（必须通过 `make_agent` 注册）。 |
| `input` | 可选的 prompt 覆盖。如果为 `None`，Agent 使用默认行为。 |
| `workspace` | 可选的每 Agent 工作空间。覆盖运行时级别的工作空间，用于该 Agent 的工具处理器。适用于将并行 Agent 沙箱化到不同的文件系统根目录。 |
| `approval_handler` | 可选的每 Agent 处理器覆盖。当同时存在 `agent_config` 上的处理器时，优先使用此处的处理器。 |
| `blocking_approval` | 默认 `false`。设为 `true` 时，如果该 Agent 在执行期间触发审批，整个并行节点会等待解析。设为 `false`（默认）时，只有该 Agent 的分支挂起，其他分支继续运行。 |

## `parallel_invoke_result`

所有分支完成（或 `Fail_fast` 停止它们）后返回：

```ocaml
type parallel_invoke_result = {
  successes : Types.invoke_result list;
  failures  : (agent_dispatch_spec * error_category) list;
  merged    : Yojson.Safe.t option;
}
```

| 字段 | 描述 |
|------|------|
| `successes` | 成功完成的 Agent 的结果。 |
| `failures` | 失败的 Agent，与各自的 spec 和错误配对。 |
| `merged` | 对所有成功结果应用 `merge_fn` 的结果。如果没有结果或没有 `merge_fn`，为 `None`。 |

## 控制并行度

### `parallel_limit`

通过 `Eio.Semaphore` 控制最大并发 Agent 数：

```ocaml
(* 即使有 10 个 spec，也最多同时运行 3 个 Agent *)
Runtime.invoke_parallel ~rt ~specs ~parallel_limit:3 ()
```

当限制小于 spec 数量时，Agent 会排队，等待可用插槽。

### `failure_policy`

复用工作流引擎的 `failure_policy`：

```ocaml
type failure_policy =
  | Fail_fast                                     (* 遇到第一个错误停止 *)
  | Continue_on_failure                           (* 跳过失败步骤，继续运行 *)
  | Conditional of { on_failure : workflow_step } (* 失败时运行补偿步骤 *)
```

| 策略 | 行为 |
|------|------|
| `Fail_fast` | 第一个错误停止所有分支，剩余分支被取消。 |
| `Continue_on_failure` | 跳过失败分支。只有成功的结果出现在 `successes` 中。 |
| `Conditional` | 失败时运行 `on_failure` 步骤（例如，后备 Agent、清理）。 |

## 使用 `merge_fn` 合并结果

`merge_fn` 参数让你将分支结果组合为单一输出，类似 LangGraph 的 reducer 模式：

```ocaml
(* 默认：将结果包装在 JSON 列表中 *)
let default_merge results = `List results

(* 自定义：连接文本输出 *)
let concat_merge results =
  let texts = List.filter_map (fun r ->
    match r.Types.response.text with t -> Some t | _ -> None
  ) results in
  `String (String.concat "\n---\n" texts)

(* 自定义：计数成功 *)
let count_merge results = `Int (List.length results)
```

如果未提供 `merge_fn`，结果被包装在 JSON 列表中（`\`List [...]`）。

```ocaml
let result =
  Runtime.invoke_parallel ~rt
    ~specs:[
      { agent_id = "summarizer"; input = Some "Summarize doc A"; ... };
      { agent_id = "summarizer"; input = Some "Summarize doc B"; ... };
      { agent_id = "summarizer"; input = Some "Summarize doc C"; ... };
    ]
    ~merge_fn:concat_merge
    ()
in
match result.merged with
| Some (`String text) -> print_endline text
| _ -> print_endline "No merged result"
```

## 每 Agent 工作空间隔离

每个并行分支都有自己的 `per_call_registry`（工具注册表）。如果在 spec 上提供 `workspace`，该 Agent 的工具在不同的文件系统根目录下运行：

```ocaml
let spec_a =
  { agent_id = "reader"; input = Some "Read /project-a/README.md";
    workspace = Some (Workspace.create "/project-a"); ... }
in
let spec_b =
  { agent_id = "reader"; input = Some "Read /project-b/README.md";
    workspace = Some (Workspace.create "/project-b"); ... }
in
(* 每个 Agent 只看到自己的工作空间 *)
```

当 `workspace` 为 `None` 时，Agent 使用运行时级别的工作空间。

## HITL x 并行交互

并行分发与 [HITL 框架](hitl.md) 集成：

- **非阻塞（默认）**：如果 Agent 通过 async 或 webhook 处理器触发审批，只有该分支挂起。其他分支继续运行。
- **阻塞**（`blocking_approval = true`）：如果在 spec 上设置，整个并行节点会等待该 Agent 的审批解析后再收集结果。
- **每 Agent 处理器**：每个 spec 可以覆盖审批处理器。这意味着同一批并行中的不同 Agent 可以使用不同的审批策略。

```ocaml
let specs = [
  { agent_id = "safe_agent";    input = Some "Analyze data";
    approval_handler = None; blocking_approval = false; ... };
  { agent_id = "risky_agent";   input = Some "Send notification";
    approval_handler = Some webhook_handler;
    blocking_approval = false; ... };  (* 独立挂起 *)
]
```

## 取消

传递 `Eio.Switch.t` 作为 `cancellation_token` 来取消所有分支：

```ocaml
Eio.Switch.run (fun cancel_switch ->
  (* 在后台 fiber 中启动并行分发 *)
  let fiber = Eio.Fiber.fork_promise (fun () ->
    Runtime.invoke_parallel ~rt ~specs
      ~cancellation_token:cancel_switch ())
  in
  (* 稍后：取消所有分支 *)
  Eio.Switch.release cancel_switch)
```

取消时，分支停止，部分结果（如果有）被收集。

## 完整示例

```ocaml
open Par

let () = Eio_main.run (fun env ->
  Eio.Switch.run (fun switch ->
    let config = Runtime.default_config ~persistence:(`Sqlite ":memory:") () in
    match Runtime.create ~config switch with
    | Error e -> prerr_endline (Runtime.string_of_error_category e)
    | Ok rt ->
      (* 创建 Agent *)
      let summarizer =
        Runtime.make_agent ~id:"summarizer" ~model:"openai/gpt-4o-mini" ()
      in
      let translator =
        Runtime.make_agent ~id:"translator" ~model:"openai/gpt-4o-mini" ()
      in
      ignore (summarizer, translator);

      (* 分发 3 个并行摘要任务 *)
      let specs = List.map (fun topic ->
        Types.{ agent_id = "summarizer";
                input = Some ("Summarize: " ^ topic);
                workspace = None;
                approval_handler = None;
                blocking_approval = false }
      ) ["AI safety"; "Quantum computing"; "Climate change"]
      in
      let result =
        Runtime.invoke_parallel ~rt ~specs
          ~failure_policy:Fail_fast
          ~merge_fn:(fun results ->
            let texts = List.filter_map (fun r ->
              Some r.Types.response.text) results in
            `String (String.concat "\n\n" texts))
          ()
      in
      Printf.printf "Successes: %d\n" (List.length result.Types.successes);
      Printf.printf "Failures: %d\n" (List.length result.Types.failures);
      (match result.merged with
       | Some (`String t) -> print_endline t
       | _ -> print_endline "No merged result");
      ignore (Runtime.close rt)))
```

## Python 交叉引用

Python 绑定通过 ctypes 暴露并行分发。详见 [Python FFI 文档](https://github.com/jcz2020/par/blob/main/bindings/python/)：

- `Runtime.invoke_parallel(specs: list[dict]) -> dict`，每个 spec 字典包含 `agent_id`、`input`、`workspace`、`approval_handler`、`blocking_approval` 键。
- 每 Agent 的工作空间和审批处理器覆盖与 OCaml API 行为一致。

## 与 Workflow API 的关系

`Runtime.invoke_parallel` 是现有 [Workflow API](workflow.md) `Parallel` 步骤类型的便捷封装。内部构造一个包含 `Parallel` 节点的工作流，每个 spec 对应一个 `Agent_call`，提交后收集结果。

如果你需要更复杂的编排（顺序步骤混合并行、条件分支、检查点），直接使用 Workflow API。如果你只需要"N 个 Agent 并行运行并合并结果"，`invoke_parallel` 是更简单的入口。
