<!-- language: en -->

> Translated to English for v0.3.2. Source-of-truth: the OCaml types in lib/core/workflow.ml.

# Workflow API Reference

This document describes the P-A-R SDK's workflow definition, execution, and state management API.

## Overview

A workflow is a multi-step orchestration engine. It composes agent calls, tool calls, and human approvals into a structured execution plan. Workflows support checkpointing and can suspend or resume at human approval points.

## workflow type

```ocaml
type workflow = {
  id : string;
  name : string;
  version : int;
  steps : workflow_step;                         (* Entry step *)
  variables : (string * Yojson.Safe.t) list;    (* Template variables *)
  failure_policy : failure_policy;
  parallel_limit : int;
  timeout : float;
  on_complete : (workflow_result -> unit) option;  (* Optional completion callback *)
}
```

### failure_policy

```ocaml
type failure_policy =
  | Fail_fast                              (* Stop on first error, default *)
  | Continue_on_failure                    (* Skip failed steps and keep running *)
  | Conditional of { on_failure : workflow_step }  (* Run a compensation step on failure *)
```

### workflow_result

Result returned after a workflow execution completes:

```ocaml
type workflow_result = {
  outputs : (string * Yojson.Safe.t) list;  (* Key-value pair outputs *)
  status : [ `Success | `Partial | `Failed ];
  elapsed : float;                          (* Execution time in seconds *)
  metadata : (string * string) list;        (* workflow_id, workflow_name *)
}
```

## Step types

### workflow_step

```ocaml
type workflow_step =
  | Agent_call of {
      agent_id : string;
      prompt_template : string;           (* Supports {{variable}} templates *)
    }
  | Tool_call of {
      tool_name : string;
      input : Yojson.Safe.t;
    }
  | Parallel of workflow_step list
  | Sequential of workflow_step list
  | Conditional of {
      condition : expression;             (* See the Expression module *)
      then_step : workflow_step;
      else_step : workflow_step option;
    }
  | Map_reduce of {
      over : string;                      (* Variable name to iterate over *)
      step : workflow_step;               (* Applied to each element *)
      reduce : [ `Collect_all | `First_success | `Majority ];
    }
  | Human_approval of {
      prompt_template : string;
      timeout : float;                   (* Approval timeout in seconds *)
      allowed_roles : string list;
    }
  | Sub_workflow of {
      workflow_id : string;
      variables : (string * Yojson.Safe.t) list;
    }
```

### Agent_call

Calls a registered agent. `prompt_template` supports `{{variable_name}}` placeholders:

```ocaml
Agent_call {
  agent_id = "summarizer";
  prompt_template = "Please summarize: {{content}}";
}
```

### Tool_call

Calls a registered tool directly:

```ocaml
Tool_call {
  tool_name = "calculator";
  input = `Assoc [("expression", `String "2 + 3")];
}
```

### Sequential

Executes a list of steps in order:

```ocaml
Sequential [
  Agent_call { agent_id = "agent-a"; prompt_template = "Describe X" };
  Agent_call { agent_id = "agent-b"; prompt_template = "Critique: {{result}}" };
]
```

### Parallel

Executes multiple steps concurrently, bounded by the `parallel_limit` semaphore:

```ocaml
Parallel [
  Tool_call { tool_name = "fetch_url"; input = `Assoc [("url", `String "https://a.com")] };
  Tool_call { tool_name = "fetch_url"; input = `Assoc [("url", `String "https://b.com")] };
]
```

### Conditional

Branches on an expression. Expression evaluation uses the workflow's `variables` as its context:

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

Runs a step against each element of an array variable, then aggregates the results:

```ocaml
(* variables must contain items = [1, 2, 3, ...] *)
Map_reduce {
  over = "items";
  step = Tool_call { tool_name = "calculator"; input = `Assoc [("expression", `String "{{item}}")] };
  reduce = `Collect_all;
}
```

Three reduce strategies:

| Strategy | Behavior |
|------|------|
| `Collect_all` | Collect every successful result and return the list |
| `First_success` | Return the first successful result |
| `Majority` | Return the result that appears most often |

### Human_approval

Suspends the workflow pending human approval. When the timeout elapses, the workflow is automatically marked as failed:

```ocaml
Human_approval {
  prompt_template = "Please review the action: {{action}}";
  timeout = 300.0;        (* 5 minute timeout *)
  allowed_roles = ["admin"; "reviewer"];
}
```

### Sub_workflow

Nests another registered workflow. Variables are merged with the parent:

```ocaml
Sub_workflow {
  workflow_id = "data-processing";
  variables = [("source", `String "input.csv")];
}
```

## Runtime API

All functions in this section take a `runtime` value created by `Runtime.create`. The same runtime also serves `Runtime.invoke` for direct agent calls, so a workflow and a single-shot invocation can share state, tools, and event subscribers.

### Register a workflow definition

```ocaml
val Runtime.register_workflow : runtime -> workflow -> (unit, error_category) result
```

### Submit a workflow execution

```ocaml
val Runtime.submit_workflow : runtime -> workflow ->
  (Workflow_run_id.t, error_category) result
```

Returns the workflow run ID, which can be used for subsequent status queries.

### Query workflow status

```ocaml
val Runtime.get_workflow_status : runtime -> Workflow_run_id.t ->
  (workflow_status, error_category) result
```

### Cancel a workflow

```ocaml
val Runtime.cancel_workflow : runtime -> Workflow_run_id.t ->
  (unit, error_category) result
```

### Approve a suspended workflow

```ocaml
val Runtime.approve_workflow : runtime -> Workflow_run_id.t -> approver:string ->
  (unit, error_category) result
```

### Resume a suspended workflow

```ocaml
val Runtime.resume_workflow : runtime -> Workflow_run_id.t ->
  (workflow_result option, error_category) result
```

## Variables and context propagation

Workflows support the `{{variable_name}}` template syntax. Variables are available at the following places:

- `Agent_call.prompt_template` -- substituted with the string representation of a JSON value
- `Human_approval.prompt_template` -- same as above

Variable sources:

1. `workflow.variables` -- initial variables declared with the workflow definition
2. `Sub_workflow.variables` -- a sub-workflow can pass extra variables (merged with the parent's)
3. `Map_reduce` -- the current iteration element is injected as a variable of the same name

Expression evaluation (the `condition` of `Conditional`) uses `variables` as its context and supports `Variable "key"` to reference a value.

## Checkpoint and resume

### workflow_status

```ocaml
type workflow_status =
  | Wf_pending
  | Wf_running
  | Wf_suspended of workflow_checkpoint    (* Suspended for human approval *)
  | Wf_completed of workflow_result
  | Wf_failed of error_category
```

### workflow_checkpoint

```ocaml
type workflow_checkpoint = {
  step_path : int list;                        (* Step path index *)
  variables : (string * Yojson.Safe.t) list;   (* Current variable snapshot *)
  step_results : Yojson.Safe.t list;           (* Results of completed steps *)
}
```

A workflow automatically creates a checkpoint and suspends when it reaches a `Human_approval` step. The persistence layer saves the checkpoint to the database, which makes cross-process recovery possible.

### Resume flow

1. The workflow reaches `Human_approval` and its status becomes `Wf_suspended`.
2. An external system calls `Runtime.approve_workflow` or `Runtime.resume_workflow`.
3. The workflow resumes from the checkpoint and runs the remaining steps.
4. If the timeout elapses, the status becomes `Wf_failed Timeout` automatically.

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

## Approval timeout (v0.2.0)

When a workflow reaches a `Human_approval` step, the engine automatically registers a timeout fiber. The fiber waits for approval until the timeout elapses. Once the deadline passes, the engine removes the deadline, marks the workflow as `Wf_failed Timeout`, and persists the state change to the database.

The timeout mechanism is managed internally by the `Workflow_engine.Approval_deadline` module.

## Persisting workflow state

Workflow state is persisted through the following functions on `persistence_service`:

```ocaml
save_workflow_state_fn : Workflow_run_id.t -> workflow_status ->
  workflow_checkpoint option -> (unit, error_category) result
load_workflow_state_fn : Workflow_run_id.t ->
  (workflow_checkpoint option, error_category) result
```

The SQLite backend automatically creates a `workflow_states` table that stores the status and checkpoint as JSON.

## Complete workflow example

The runtime `rt` below is created with `Runtime.create` (see [Agent API](agent.md) for the full creation sequence). The same `rt` is also used by `Runtime.invoke` for direct agent invocations outside a workflow.

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

## JSON workflow format

A workflow can be loaded from JSON (you deserialize it into the `workflow` record yourself):

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

A step is serialized as `["StepType", arguments]`. The argument shape depends on the step type.

## See also

- [Overview](overview.md) -- SDK architecture overview
- [Agent API](agent.md) -- Agent configuration and runtime management
- [examples/sequential_workflow.json](../../examples/sequential_workflow.json) -- Workflow JSON example
