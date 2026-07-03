<!-- language: zh -->

[English](../sdk/workflow.md) · **简体中文**

> 源真相：`lib/core/types.ml` 中的 OCaml 类型和 `lib/core/workflow_engine.ml` 中的引擎。

# Workflow API 参考

本文档描述 P-A-R SDK 的工作流定义、执行和状态管理 API。

## 概述

工作流是多步骤编排引擎。它将 Agent 调用、工具调用和人工审批组合为有结构的执行计划。工作流支持检查点机制，可在人工审批点挂起和恢复。

## workflow_def 和 workflow 类型

工作流模型分为两个记录：一个是可序列化的定义，一个是运行时值（可能携带可选的完成回调）。

```ocaml
(* 可序列化定义。通过 [@@deriving yojson] 与 JSON 互转。 *)
type workflow_def = {
  id : string;
  name : string;
  version : int;
  steps : workflow_step;                          (* 入口步骤 *)
  variables : (string * Yojson.Safe.t) list;      (* 模板变量 *)
  failure_policy : failure_policy;
  parallel_limit : int;
  timeout : float;
}
[@@deriving yojson]

(* 运行时值。携带定义加上可选的完成钩子。
   不可序列化：on_complete 是闭包。 *)
type workflow = {
  def : workflow_def;
  on_complete : (workflow_result -> unit) option;  (* 最终结果触发一次 *)
}
```

字段访问通过 `wf.def`：`wf.def.id`、`wf.def.variables`、`wf.def.steps` 等。只有 `wf.on_complete` 直接从 `workflow` 记录读取。

构建工作流时，可以直接构造记录，也可以将 JSON 反序列化为 `workflow_def` 然后包装：

```ocaml
let wf : workflow = {
  def = { id; name; version = 1; steps; variables;
          failure_policy = Fail_fast; parallel_limit = 4; timeout = 600.0 };
  on_complete = None;
}
```

### failure_policy

```ocaml
type failure_policy =
  | Fail_fast                              (* 遇错即停，默认 *)
  | Continue_on_failure                    (* 跳过失败步骤，继续执行 *)
  | Conditional of { on_failure : workflow_step }  (* 失败时执行补偿步骤 *)
```

### workflow_result

工作流执行完成后的结果：

```ocaml
type workflow_result = {
  outputs : (string * Yojson.Safe.t) list;  (* 键值对输出 *)
  status : [ `Success | `Partial | `Failed ];
  elapsed : float;                          (* 执行耗时（秒） *)
  metadata : (string * string) list;        (* workflow_id, workflow_name *)
}
```

## 步骤类型

### workflow_step

```ocaml
type workflow_step =
  | Agent_call of {
      agent_id : string;
      prompt_template : string;           (* 支持 {{变量}} 模板 *)
    }
  | Tool_call of {
      tool_name : string;
      input : Yojson.Safe.t;
    }
  | Parallel of workflow_step list
  | Sequential of workflow_step list
  | Conditional of {
      condition : expression;             (* 见 Expression 模块 *)
      then_step : workflow_step;
      else_step : workflow_step option;
    }
  | Map_reduce of {
      over : string;                      (* 要遍历的变量名 *)
      step : workflow_step;               (* 应用于每个元素 *)
      reduce : [ `Collect_all | `First_success | `Majority ];
    }
  | Human_approval of {
      prompt_template : string;
      timeout : float;                   (* 审批超时（秒） *)
      allowed_roles : string list;
    }
  | Sub_workflow of {
      workflow_id : string;
      variables : (string * Yojson.Safe.t) list;
    }
```

### Agent_call

调用已注册的 Agent。`prompt_template` 支持 `{{变量名}}` 占位符：

```ocaml
Agent_call {
  agent_id = "summarizer";
  prompt_template = "Please summarize: {{content}}";
}
```

`Agent_call` 的结果是形如 `` `Assoc [("text", `String _); ("tool_calls", `List _)] `` 的结构化 JSON 值。Sequential 中的下游步骤可以分别引用各部分，例如 `{{result.text}}` 获取助手文本，`{{result.tool_calls}}` 获取工具调用数组。完整绑定规则见[变量与上下文传播](#变量与上下文传播)。

### Tool_call

直接调用已注册的工具。`input` JSON 的每个字符串叶节点都会递归应用 `{{variable}}` 模板替换，因此任何嵌套字符串都可以引用工作流上下文或先前 Sequential 步骤中的变量：

```ocaml
Tool_call {
  tool_name = "calculator";
  input = `Assoc [("expression", `String "{{result.text}}")];  (* 从上一步替换 *)
}
```

字面值（无模板）也可以：

```ocaml
Tool_call {
  tool_name = "calculator";
  input = `Assoc [("expression", `String "2 + 3")];
}
```

### Sequential

按顺序执行多个步骤。每个完成的步骤将其结果传播给同一 Sequential 中所有后续兄弟步骤（见[变量与上下文传播](#变量与上下文传播)）：

```ocaml
Sequential [
  Agent_call { agent_id = "agent-a"; prompt_template = "Describe X" };
  Agent_call { agent_id = "agent-b"; prompt_template = "Critique: {{result.text}}" };
]
```

在第二步中，`{{result.text}}` 解析为 `agent-a` 产生的结构化结果的 `text` 字段。如果上一步返回裸字符串（非 `Assoc`），`{{result}}` 直接解析为该字符串。

### Parallel

并行执行多个步骤，受 `parallel_limit` 信号量控制：

```ocaml
Parallel [
  Tool_call { tool_name = "fetch_url"; input = `Assoc [("url", `String "https://a.com")] };
  Tool_call { tool_name = "fetch_url"; input = `Assoc [("url", `String "https://b.com")] };
]
```

### Conditional

基于表达式条件分支。表达式的求值使用工作流的 variables 作为上下文：

```ocaml
Conditional {
  condition = Greater_than (
    Variable "score", Literal (`Int 80)
  );
  then_step = Agent_call { agent_id = "approver"; prompt_template = "Approve" };
  else_step = Tool_call { tool_name = "echo"; input = `Assoc [("msg", `String "Rejected")] };
}
```

### Map_reduce

对变量中的数组元素逐一执行步骤，然后聚合结果：

```ocaml
(* variables 中需包含 items = [1, 2, 3, ...] *)
Map_reduce {
  over = "items";
  step = Tool_call { tool_name = "calculator"; input = `Assoc [("expression", `String "{{item}}")] };
  reduce = `Collect_all;
}
```

三种 reduce 策略：

| 策略 | 行为 |
|------|------|
| `Collect_all` | 收集所有成功结果，返回列表 |
| `First_success` | 返回第一个成功结果 |
| `Majority` | 返回出现次数最多的结果 |

### Human_approval

暂停工作流等待人工审批。超时后工作流自动标记为失败：

```ocaml
Human_approval {
  prompt_template = "请审核操作: {{action}}";
  timeout = 300.0;        (* 5 分钟超时 *)
  allowed_roles = ["admin"; "reviewer"];
}
```

`allowed_roles` 列表在挂起时被截入检查点，并由 `Runtime.approve_workflow` 执行验证。

### Sub_workflow

嵌套执行另一个已注册的工作流，变量会合并：

```ocaml
Sub_workflow {
  workflow_id = "data-processing";
  variables = [("source", `String "input.csv")];
}
```

## 运行时 API

本节所有函数都接受由 `Runtime.create` 创建的 `runtime` 值。同一个 runtime 也服务于 `Runtime.invoke`（直接 agent 调用），因此工作流和单次调用可以共享状态、工具和事件订阅者。

### 注册工作流定义

```ocaml
val Runtime.register_workflow : runtime -> workflow -> (unit, error_category) result
```

将工作流存储在 `wf.def.id` 下，以便 `Sub_workflow` 引用并在恢复时重新加载。同一个记录可以直接传给 `submit_workflow` 而无需先注册。

### 提交工作流执行

三个入口覆盖常见模式。三者都接受可选的 `?inputs` 列表，该列表会合并到（并覆盖）`wf.def.variables`（仅限本次运行）。工作流定义本身不会被修改，因此一个定义可以在不同运行中以不同参数化方式使用。

```ocaml
(* 同步。阻塞调用方 fiber，直到工作流到达终态
   （Completed / Failed）或在 Human_approval 处挂起。 *)
val Runtime.submit_workflow :
  runtime ->
  ?inputs:(string * Yojson.Safe.t) list ->
  workflow ->
  (Workflow_run_id.t, error_category) result

(* 发射即忘。在后台 fork 执行并立即返回运行 ID。
   通过 get_workflow_status 或订阅 runtime 事件总线来跟踪进度。 *)
val Runtime.submit_workflow_async :
  runtime ->
  ?inputs:(string * Yojson.Safe.t) list ->
  workflow ->
  (Workflow_run_id.t, error_category) result

(* 便捷包装。调用 submit_workflow_async 然后阻塞直到工作流终止。
   完成时返回 [Some result]，挂起时返回 [None]，失败时返回 [Error]。
   适合测试和短工作流。 *)
val Runtime.invoke_workflow_sync :
  runtime ->
  ?inputs:(string * Yojson.Safe.t) list ->
  workflow ->
  (workflow_result option, error_category) result
```

对于长时间运行的工作流，推荐使用 `submit_workflow_async` 以避免阻塞调用方 fiber。

### 查询工作流状态

```ocaml
val Runtime.get_workflow_status : runtime -> Workflow_run_id.t ->
  (workflow_status, error_category) result
```

### 取消工作流

```ocaml
val Runtime.cancel_workflow : runtime -> Workflow_run_id.t ->
  (unit, error_category) result
```

### 审批挂起的工作流

```ocaml
val Runtime.approve_workflow : runtime -> Workflow_run_id.t -> approver:string ->
  (unit, error_category) result
```

`approver` 字符串会与检查点中的 `allowed_roles`（在挂起时从 `Human_approval` 步骤截入）进行验证。如果 `allowed_roles = Some roles` 且 `approver` 不在列表中，调用返回 `Permission_denied` 而不恢复。当 `allowed_roles = None` 时，检查不受限。审批成功后，引擎发布 `Approval_granted` 事件，移除审批截止时间，并恢复工作流。

### 恢复挂起的工作流

```ocaml
val Runtime.resume_workflow : runtime -> Workflow_run_id.t ->
  (workflow_result option, error_category) result
```

从检查点恢复支持 `Sequential` 和 `Conditional` 步骤类型。挂起 `step_path` 处的 `Parallel` 和 `Map_reduce` 会返回 `Error`，因为无法从检查点安全重建迭代中的并发状态。唯一能产生挂起的步骤类型是 `Human_approval`，因此实际上此限制仅在审批位于 Parallel 或 Map_reduce 分支内时才有关。

返回 `Ok (Some result)` 表示工作流执行完毕，`Ok None` 表示在后续审批处再次挂起，其他情况返回 `Error`。

## 变量与上下文传播

工作流支持 `{{变量名}}` 模板语法。变量在以下位置可用：

- `Agent_call.prompt_template`，替换为 JSON 值的字符串表示（对于嵌套字段，点分键如 `{{result.text}}` 解析到叶节点）
- `Human_approval.prompt_template`，规则同上
- `Tool_call.input`，递归应用于 JSON 树中的每个字符串叶节点

变量来源，按优先级顺序（后来源覆盖先来源的同名键）：

1. `workflow_def.variables`（工作流定义声明的初始变量）
2. `Sub_workflow.variables`（子工作流可传递额外变量，与父工作流合并）
3. `Map_reduce` 迭代绑定（当前迭代元素以 `over` 字段的同名变量注入）
4. **先前 `Sequential` 兄弟步骤的结果。** Sequential 中每个完成的步骤在三组键下发布其输出：
   - `result` 是最近兄弟步骤的输出
   - `result_N`（零索引：`result_0`、`result_1`、...）是兄弟步骤 N 的输出
   - `results` 是到目前为止所有兄弟步骤输出的累积数组

   当步骤结果是 `Assoc`（`Agent_call` 产生的形态）时，还会添加扁平的点分绑定：`result.text`、`result.tool_calls`、`result_0.text`、`result_1.tool_calls` 等。这就是 Sequential 示例中 `Critique: {{result.text}}` 模式的工作原理。

表达式求值（`Conditional` 的 `condition`）使用 `variables` 作为上下文，支持 `Variable "key"` 引用变量值。

## 工作流生命周期事件

引擎在每次状态转换时向 runtime 的事件总线发出事件。外部系统通过 `Runtime.create ~event_bus: ...` 订阅，并监听 `event` 类型的以下变体：

| 事件 | 触发时机 | 载荷 |
|-------|------|---------|
| `Workflow_started` | 工作流运行开始 | `{ workflow_run_id }` |
| `Workflow_step_completed` | 任何步骤成功完成 | `{ step_id }`，其中 `step_id` 是点分路径如 `"0.1.2"` |
| `Workflow_completed` | 运行到达终态成功 | `{ workflow_run_id }` |
| `Workflow_failed` | 运行到达终态失败 | `{ workflow_run_id; error }` |
| `Approval_requested` | `Human_approval` 步骤挂起运行 | `{ prompt; allowed_roles }` |
| `Approval_granted` | `approve_workflow` 成功并恢复运行 | `{ approver }` |
| `Approval_timeout` | 审批截止时间到达但未授予 | （无载荷） |

对于长时间运行或跨进程的工作流，建议订阅事件总线而非轮询 `get_workflow_status`。

## 检查点与恢复

### workflow_status

```ocaml
type workflow_status =
  | Wf_pending
  | Wf_running
  | Wf_suspended of workflow_checkpoint    (* 人工审批挂起 *)
  | Wf_completed of workflow_result
  | Wf_failed of error_category
```

### workflow_checkpoint

```ocaml
type workflow_checkpoint = {
  workflow_id : string;                          (* 标识 workflow_def 以便恢复 *)
  step_path : int list;                          (* 点分路径，指向挂起点 *)
  variables : (string * Yojson.Safe.t) list;     (* 当前变量快照 *)
  step_results : Yojson.Safe.t list;             (* 已完成步骤的结果 *)
  allowed_roles : string list option;            (* None = 不受限 *)
}
[@@deriving yojson]
```

`workflow_id` 让引擎在恢复时从 `rt.workflow_defs` 查找原始 `workflow_def`，因此新进程可以接管另一个进程挂起的运行。`allowed_roles` 在挂起步骤是带非空角色列表的 `Human_approval` 时为 `Some roles`，`Runtime.approve_workflow` 会对其进行检查。`None` 表示审批不受限。

工作流在到达 `Human_approval` 步骤时自动创建检查点并挂起。持久化层将检查点保存到数据库，支持跨进程恢复。

### 恢复流程

1. 工作流到达 `Human_approval`，状态变为 `Wf_suspended`。检查点携带 `workflow_id`、`step_path`、累积的 `variables`、`step_results` 和 `allowed_roles`。
2. 外部系统调用 `Runtime.approve_workflow`（执行角色检查、发布 `Approval_granted`、然后内部触发恢复）或 `Runtime.resume_workflow`（跳过角色检查直接恢复）。
3. 引擎通过 `checkpoint.workflow_id` 重新加载工作流定义，从检查点恢复变量，并执行剩余步骤。
4. 若审批超时先到达，状态自动变为 `Wf_failed Timeout`，并发布 `Approval_timeout` 事件。

限制：从检查点恢复支持 `Sequential` 和 `Conditional` 步骤类型。挂起 `step_path` 处的 `Parallel` 和 `Map_reduce` 会返回 `Error`，因为无法安全重建迭代中的并发状态。

### workflow_run

```ocaml
type workflow_run = {
  id : Workflow_run_id.t;
  workflow_id : string;
  status : workflow_status;
  checkpoint : workflow_checkpoint option;
  created_at : float;
  updated_at : float;
}
```

## 审批超时

当工作流到达 `Human_approval` 步骤时，引擎自动注册一个超时 fiber。该 fiber 等待审批直到超时到达。一旦截止时间过去，引擎移除截止时间，将工作流标记为 `Wf_failed Timeout`，发布 `Approval_timeout` 事件，并将状态变更持久化到数据库。

超时机制通过 `Workflow_engine.Approval_deadline` 模块内部管理。

## 持久化与恢复

工作流状态通过 `persistence_service` 的以下函数持久化：

```ocaml
save_workflow_state_fn : Workflow_run_id.t -> workflow_status ->
  workflow_checkpoint option -> (unit, error_category) result
load_workflow_state_fn : Workflow_run_id.t ->
  (workflow_checkpoint option, error_category) result
load_all_suspended_workflows_fn : unit ->
  ((Workflow_run_id.t * workflow_status) list, error_category) result
```

SQLite 后端自动创建 `workflow_states` 表，以 JSON 格式保存状态和检查点。

### 启动时重新水合

在 `Runtime.create` 时，runtime 查询 `load_all_suspended_workflows_fn`，并用持久化层中找到的挂起运行填充其内存中的 `rt.workflows` 表。这些运行随后可通过 `Runtime.resume_workflow`（或 `Runtime.approve_workflow`）恢复，无需额外设置。

重新水合**不会**自动恢复任何东西。数据库中的挂起运行保持挂起状态，直到有东西显式审批或恢复它。runtime 也不会在启动时重新启动审批截止时间 fiber；如果你希望原始超时在进程重启后继续滴答，请通过自己的调度器处理。

## 完整工作流示例

下面的 runtime `rt` 由 `Runtime.create` 创建（完整创建流程见 [Agent API](agent.md)）。同一个 `rt` 也用于工作流之外的 `Runtime.invoke` 直接 agent 调用。

```ocaml
open Par

let wf : workflow = {
  def = {
    id = "research-workflow";
    name = "Research and Summary";
    version = 1;
    steps = Sequential [
      Agent_call {
        agent_id = "researcher";
        prompt_template = "Research the topic: {{topic}}";
      };
      Human_approval {
        prompt_template = "Research complete. Continue to summarize?";
        timeout = 60.0;
        allowed_roles = ["admin"];
      };
      Agent_call {
        agent_id = "summarizer";
        prompt_template = "Summarize this: {{result.text}}";
      };
    ];
    variables = [("topic", `String "OCaml 5 concurrency")];
    failure_policy = Fail_fast;
    parallel_limit = 3;
    timeout = 600.0;
  };
  on_complete = None;
} in
ignore (Runtime.register_workflow rt wf);
match Runtime.submit_workflow_async rt wf with
| Ok run_id ->
  Printf.printf "Workflow started: %s\n" (Workflow_run_id.to_string run_id)
| Error err ->
  Printf.eprintf "Workflow submission failed\n"
```

第三步使用 `{{result.text}}` 从前一个 `Agent_call` 兄弟步骤中提取助手文本。因为审批步骤位于两个 agent 之间，该处的 `result` 指向 researcher 的结构化输出。

## JSON 工作流格式

工作流定义可以从 JSON 加载。反序列化为 `workflow_def`（带 `[@@deriving yojson]`），然后包装为 `on_complete = None` 的 `workflow` 记录：

```json
{
  "id": "test-wf-seq",
  "name": "Sequential Workflow",
  "version": 1,
  "steps": ["Sequential", [
    ["Agent_call", {
      "agent_id": "default-agent",
      "prompt_template": "Describe OCaml in 3 words"
    }],
    ["Agent_call", {
      "agent_id": "default-agent",
      "prompt_template": "Describe Rust in 3 words"
    }]
  ]],
  "variables": [],
  "failure_policy": "Fail_fast",
  "parallel_limit": 5,
  "timeout": 60.0
}
```

步骤序列化格式为 `["步骤类型", 参数]`。参数结构取决于步骤类型。只有 `workflow_def` 可 JSON 序列化；`workflow.on_complete` 是闭包，不包含在线格式中。

## 另请参阅

- [Overview](overview.md) — SDK 架构概览
- [Agent API](agent.md) — Agent 配置和运行时管理
- [examples/sequential_workflow.json](../../../examples/sequential_workflow.json) — 工作流 JSON 示例
