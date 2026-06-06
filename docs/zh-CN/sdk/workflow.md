# Workflow API 参考
[English](../sdk/workflow.md) · **简体中文**

本文档描述 P-A-R SDK 的工作流定义、执行和状态管理 API。

## 概述

工作流是多步骤编排引擎，支持将 Agent 调用、工具调用、人工审批等组合为有结构的执行计划。工作流具备检查点机制，可在人工审批点挂起和恢复。

## workflow 类型

```ocaml
type workflow = {
  id : string;
  name : string;
  version : int;
  steps : workflow_step;                         (* 入口步骤 *)
  variables : (string * Yojson.Safe.t) list;    (* 模板变量 *)
  failure_policy : failure_policy;
  parallel_limit : int;
  timeout : float;
  on_complete : (workflow_result -> unit) option;  (* 可选完成回调 *)
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

### Tool_call

直接调用已注册的工具：

```ocaml
Tool_call {
  tool_name = "calculator";
  input = `Assoc [("expression", `String "2 + 3")];
}
```

### Sequential

按顺序执行多个步骤：

```ocaml
Sequential [
  Agent_call { agent_id = "agent-a"; prompt_template = "Describe X" };
  Agent_call { agent_id = "agent-b"; prompt_template = "Critique: {{result}}" };
]
```

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

### Sub_workflow

嵌套执行另一个已注册的工作流，变量会合并：

```ocaml
Sub_workflow {
  workflow_id = "data-processing";
  variables = [("source", `String "input.csv")];
}
```

## 运行时 API

### 注册工作流定义

```ocaml
val Runtime.register_workflow : runtime -> workflow -> (unit, error_category) result
```

### 提交工作流执行

```ocaml
val Runtime.submit_workflow : runtime -> workflow ->
  (Workflow_run_id.t, error_category) result
```

返回工作流运行 ID，可用于后续状态查询。

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

### 恢复挂起的工作流

```ocaml
val Runtime.resume_workflow : runtime -> Workflow_run_id.t ->
  (workflow_result option, error_category) result
```

## 变量与上下文传播

工作流支持 `{{变量名}}` 模板语法。变量在以下位置可用：

- `Agent_call.prompt_template` -- 替换为 JSON 值的字符串表示
- `Human_approval.prompt_template` -- 同上

变量来源：

1. `workflow.variables` -- 工作流定义时声明的初始变量
2. `Sub_workflow.variables` -- 子工作流可传递额外变量（与父工作流合并）
3. `Map_reduce` -- 当前遍历的元素自动作为同名变量注入

表达式求值（`Conditional` 的 condition）使用 variables 作为上下文，
支持 `Variable "key"` 引用变量值。

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
  step_path : int list;                        (* 步骤路径索引 *)
  variables : (string * Yojson.Safe.t) list;   (* 当前变量快照 *)
  step_results : Yojson.Safe.t list;           (* 已完成步骤的结果 *)
}
```

工作流在 `Human_approval` 步骤处自动创建检查点并挂起。
检查点通过持久化层保存到数据库，支持跨进程恢复。

### 恢复流程

1. 工作流到达 `Human_approval` -> 状态变为 `Wf_suspended`
2. 外部系统调用 `Runtime.approve_workflow` 或 `Runtime.resume_workflow`
3. 工作流从检查点恢复执行后续步骤
4. 若超过 timeout，自动变为 `Wf_failed Timeout`

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

## 审批超时 (v0.2.0)

当工作流到达 `Human_approval` 步骤时，引擎自动注册一个超时 fiber：
- 在 timeout 时间内等待审批
- 超时后自动移除 deadline，将工作流标记为 `Wf_failed Timeout`
- 同时持久化状态变更到数据库

超时机制通过 `Workflow_engine.Approval_deadline` 模块内部管理。

## 持久化工作流状态

工作流状态通过 `persistence_service` 的以下函数持久化：

```ocaml
save_workflow_state_fn : Workflow_run_id.t -> workflow_status ->
  workflow_checkpoint option -> (unit, error_category) result
load_workflow_state_fn : Workflow_run_id.t ->
  (workflow_checkpoint option, error_category) result
```

SQLite 后端自动创建 `workflow_states` 表，保存状态和检查点 JSON。

## 完整工作流示例

```ocaml
open Par

let wf = {
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
      prompt_template = "Summarize the research on: {{topic}}";
    };
  ];
  variables = [("topic", `String "OCaml 5 concurrency")];
  failure_policy = Fail_fast;
  parallel_limit = 3;
  timeout = 600.0;
  on_complete = None;
} in
ignore (Runtime.register_workflow rt wf);
match Runtime.submit_workflow rt wf with
| Ok run_id ->
  Printf.printf "Workflow started: %s\n" (Workflow_run_id.to_string run_id)
| Error err ->
  Printf.eprintf "Workflow submission failed\n"
```

## JSON 工作流格式

工作流可以从 JSON 加载（需自行反序列化到 `workflow` record）：

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

步骤序列化格式为 `["步骤类型", 参数]`。参数结构取决于步骤类型。

## See also

- [Overview](overview.md) -- SDK 架构概览
- [Agent API](agent.md) -- Agent 配置和运行时管理
- [examples/sequential_workflow.json](../../../examples/sequential_workflow.json) -- 工作流 JSON 示例
