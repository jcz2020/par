<!-- language: en -->

**English** · [简体中文](../zh/sdk/workflow.md)

> Source-of-truth: the OCaml types in lib/core/types.ml and the engine in lib/core/workflow_engine.ml.

# Workflow API Reference

This document describes the P-A-R SDK's workflow definition, execution, and state management API.

## Overview

A workflow is a multi-step orchestration engine. It composes agent calls, tool calls, and human approvals into a structured execution plan. Workflows support checkpointing and can suspend or resume at human approval points.

## workflow_def and workflow types

The workflow model is split into two records: a serializable definition and a runtime value that may carry an optional completion callback.

```ocaml
(* Serializable definition. Round-trips to JSON via [@@deriving yojson]. *)
type workflow_def = {
  id : string;
  name : string;
  version : int;
  steps : workflow_step;                          (* Entry step *)
  variables : (string * Yojson.Safe.t) list;      (* Template variables *)
  failure_policy : failure_policy;
  parallel_limit : int;
  timeout : float;
}
[@@deriving yojson]

(* Runtime value. Carries the definition plus an optional completion hook.
   Not serializable: on_complete is a closure. *)
type workflow = {
  def : workflow_def;
  on_complete : (workflow_result -> unit) option;  (* Invoked once with the final result *)
}
```

Field access goes through `wf.def`: `wf.def.id`, `wf.def.variables`, `wf.def.steps`, and so on. Only `wf.on_complete` is read directly off the `workflow` record.

To build a workflow, either construct the records directly or deserialize JSON into a `workflow_def` and wrap it:

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
  | Fail_fast                                     (* Stop on first error, default *)
  | Continue_on_failure                           (* Skip failed steps and keep running *)
  | Conditional of { on_failure : workflow_step } (* Run a compensation step on failure *)
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

If `wf.on_complete` is set, the engine invokes it with this record exactly once when the workflow reaches a terminal state.

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
      input : Yojson.Safe.t;              (* {{var}} substitution applied to string leaves *)
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
      timeout : float;                    (* Approval timeout in seconds *)
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
  response_schema = None;  (* optional JSON Schema for schema-validated structured output *)
}
```

The result of an `Agent_call` is a structured JSON value of shape `` `Assoc [("text", `String _); ("tool_calls", `List _)] ``. Downstream steps in a Sequential can reference the parts individually, for example `{{result.text}}` for the assistant text and `{{result.tool_calls}}` for the tool-call array. When `response_schema` is `Some _`, a third key `output` is added with the schema-validated JSON object, and `Conditional` steps can reference nested fields via dot-paths (e.g. `result.output.sentiment`). See [Variables and context propagation](#variables-and-context-propagation) for the full binding rules.

### Tool_call

Calls a registered tool directly. The `input` JSON has `{{variable}}` template substitution applied recursively to every string leaf, so any nested string can reference variables from the workflow context or from prior Sequential steps:

```ocaml
Tool_call {
  tool_name = "calculator";
  input = `Assoc [("expression", `String "{{result.text}}")];  (* substituted from previous step *)
}
```

A literal value (no templates) works too:

```ocaml
Tool_call {
  tool_name = "calculator";
  input = `Assoc [("expression", `String "2 + 3")];
}
```

### Sequential

Executes a list of steps in order. Each completed step propagates its result to all subsequent siblings in the same Sequential (see [Variables and context propagation](#variables-and-context-propagation)):

```ocaml
Sequential [
  Agent_call { agent_id = "agent-a"; prompt_template = "Describe X"; response_schema = None };
  Agent_call { agent_id = "agent-b"; prompt_template = "Critique: {{result.text}}"; response_schema = None };
]
```

In the second step, `{{result.text}}` resolves to the `text` field of the structured result produced by `agent-a`. If the previous step returned a bare string (not an `Assoc`), `{{result}}` resolves to that string directly.

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
  then_step = Agent_call { agent_id = "approver"; prompt_template = "Approve"; response_schema = None };
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

The `allowed_roles` list is captured into the checkpoint at suspension time and enforced by `Runtime.approve_workflow`.

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

Stores the workflow under `wf.def.id` so it can be referenced by `Sub_workflow` and reloaded on resume. The same record can be passed straight to `submit_workflow` without registering first.

### Submit a workflow execution

Three entry points cover the common patterns. All three accept an optional `?inputs` list that is merged into (and overrides) `wf.def.variables` for this run only. The workflow definition itself is not mutated, so one definition can be parameterized differently per run.

```ocaml
(* Synchronous. Blocks the caller fiber until the workflow reaches a
   terminal state (Completed / Failed) or suspends at Human_approval. *)
val Runtime.submit_workflow :
  runtime ->
  ?inputs:(string * Yojson.Safe.t) list ->
  workflow ->
  (Workflow_run_id.t, error_category) result

(* Fire-and-forget. Forks execution in a background fiber and returns the
   run id immediately. Track progress via get_workflow_status or by
   subscribing to events on the runtime's event bus. *)
val Runtime.submit_workflow_async :
  runtime ->
  ?inputs:(string * Yojson.Safe.t) list ->
  workflow ->
  (Workflow_run_id.t, error_category) result

(* Convenience wrapper. Calls submit_workflow_async then blocks until the
   workflow terminates. Returns [Some result] on completion, [None] on
   suspension, [Error] on failure. Handy for tests and short workflows. *)
val Runtime.invoke_workflow_sync :
  runtime ->
  ?inputs:(string * Yojson.Safe.t) list ->
  workflow ->
  (workflow_result option, error_category) result
```

For long-running workflows prefer `submit_workflow_async` so the caller fiber is not pinned.

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

The `approver` string is validated against the checkpoint's `allowed_roles` (captured from the `Human_approval` step at suspension time). If `allowed_roles = Some roles` and `approver` is not on that list, the call returns `Permission_denied` without resuming. When `allowed_roles = None` the check is unrestricted. On a successful approve the engine publishes an `Approval_granted` event, removes the approval deadline, and resumes the workflow.

### Resume a suspended workflow

```ocaml
val Runtime.resume_workflow : runtime -> Workflow_run_id.t ->
  (workflow_result option, error_category) result
```

Resume from checkpoint supports `Sequential` and `Conditional` step types. `Parallel` and `Map_reduce` at the suspension `step_path` return an `Error`, because mid-iteration concurrency state cannot be safely reconstructed from a checkpoint. The only step type that can produce a suspension is `Human_approval`, so in practice this limitation only matters when the approval sits inside a Parallel or Map_reduce branch.

Returns `Ok (Some result)` if the workflow ran to completion, `Ok None` if it suspended again at a later approval, and `Error` otherwise.

## Variables and context propagation

Workflows support the `{{variable_name}}` template syntax. Variables are available at the following places:

- `Agent_call.prompt_template`, substituted with the string representation of a JSON value (for nested fields, dotted keys like `{{result.text}}` resolve to the leaf)
- `Human_approval.prompt_template`, same rules as above
- `Tool_call.input`, applied recursively to every string leaf in the JSON tree

Variable sources, in order of precedence (later sources override earlier ones for the same key):

1. `workflow_def.variables` (initial variables declared with the workflow definition)
2. `Sub_workflow.variables` (a sub-workflow can pass extra variables, merged with the parent's)
3. `Map_reduce` iteration binding (the current iteration element is injected as a variable of the same name as the `over` field)
4. **Step results from preceding `Sequential` siblings.** Each completed step in a Sequential publishes its output under three families of keys:
   - `result` is the most recent sibling's output
   - `result_N` (zero-indexed: `result_0`, `result_1`, ...) is sibling N's output
   - `results` is the accumulated array of every sibling output so far

   When the step result is an `Assoc` (the shape `Agent_call` produces), flat dotted bindings are added too: `result.text`, `result.tool_calls`, `result_0.text`, `result_1.tool_calls`, and so on. This is what makes the `Critique: {{result.text}}` pattern in the Sequential example work.

Expression evaluation (the `condition` of `Conditional`) uses `variables` as its context and supports `Variable "key"` to reference a value.

## Workflow lifecycle events

The engine emits an event on the runtime's event bus at every state transition. External systems subscribe via `Runtime.create ~event_bus: ...` and listen for these variants of the `event` type:

| Event | Emitted when | Payload |
|-------|------|---------|
| `Workflow_started` | A workflow run begins | `{ workflow_run_id }` |
| `Workflow_step_completed` | Any step finishes successfully | `{ step_id }` where `step_id` is a dot-separated path like `"0.1.2"` |
| `Workflow_completed` | A run reaches a terminal success state | `{ workflow_run_id }` |
| `Workflow_failed` | A run reaches a terminal failure state | `{ workflow_run_id; error }` |
| `Approval_requested` | A `Human_approval` step suspends the run | `{ prompt; allowed_roles }` |
| `Approval_granted` | `approve_workflow` succeeds and resumes the run | `{ approver }` |
| `Approval_timeout` | An approval deadline elapses without a grant | (no payload) |

For long-running or cross-process workflows, subscribe to the event bus rather than polling `get_workflow_status`.

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
  workflow_id : string;                          (* Identifies the workflow_def for resume *)
  step_path : int list;                          (* Dot-separated path to the suspension point *)
  variables : (string * Yojson.Safe.t) list;     (* Current variable snapshot *)
  step_results : Yojson.Safe.t list;             (* Results of completed steps *)
  allowed_roles : string list option;            (* None = unrestricted *)
}
[@@deriving yojson]
```

`workflow_id` lets the engine look up the original `workflow_def` from `rt.workflow_defs` at resume time, so a fresh process can pick up a run that another process suspended. `allowed_roles` is `Some roles` when the suspending step was a `Human_approval` with a non-empty role list, and is what `Runtime.approve_workflow` checks against. `None` means the approval is unrestricted.

A workflow automatically creates a checkpoint and suspends when it reaches a `Human_approval` step. The persistence layer saves the checkpoint to the database, which makes cross-process recovery possible.

### Resume flow

1. The workflow reaches `Human_approval` and its status becomes `Wf_suspended`. The checkpoint carries `workflow_id`, `step_path`, accumulated `variables`, `step_results`, and `allowed_roles`.
2. An external system calls `Runtime.approve_workflow` (which performs the role check, publishes `Approval_granted`, then triggers resume internally) or `Runtime.resume_workflow` (skips the role check and resumes directly).
3. The engine reloads the workflow definition by `checkpoint.workflow_id`, restores variables from the checkpoint, and runs the remaining steps.
4. If the approval timeout elapses first, the status becomes `Wf_failed Timeout` automatically and an `Approval_timeout` event is published.

Limitation: resume from checkpoint supports `Sequential` and `Conditional` step types. `Parallel` and `Map_reduce` at the suspension `step_path` return an `Error` because mid-iteration concurrency state cannot be safely reconstructed.

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

## Approval timeout

When a workflow reaches a `Human_approval` step, the engine automatically registers a timeout fiber. The fiber waits for approval until the timeout elapses. Once the deadline passes, the engine removes the deadline, marks the workflow as `Wf_failed Timeout`, publishes an `Approval_timeout` event, and persists the state change to the database.

The timeout mechanism is managed internally by the `Workflow_engine.Approval_deadline` module.

## Persistence and recovery

Workflow state is persisted through the following functions on `persistence_service`:

```ocaml
save_workflow_state_fn : Workflow_run_id.t -> workflow_status ->
  workflow_checkpoint option -> (unit, error_category) result
load_workflow_state_fn : Workflow_run_id.t ->
  (workflow_checkpoint option, error_category) result
load_all_suspended_workflows_fn : unit ->
  ((Workflow_run_id.t * workflow_status) list, error_category) result
```

The SQLite backend automatically creates a `workflow_states` table that stores the status and checkpoint as JSON.

### Rehydration at boot

At `Runtime.create`, the runtime queries `load_all_suspended_workflows_fn` and populates its in-memory `rt.workflows` table with any suspended runs found in the persistence layer. Those runs are then resumable via `Runtime.resume_workflow` (or `Runtime.approve_workflow`) without further setup.

Rehydration does **not** auto-resume anything. A suspended run sitting in the database stays suspended until something explicitly approves or resumes it. The runtime also does not re-arm the approval deadline fiber on boot; if you want the original timeout to keep ticking across a process restart, surface that through your own scheduler.

## Complete workflow example

The runtime `rt` below is created with `Runtime.create` (see [Agent API](agent.md) for the full creation sequence). The same `rt` is also used by `Runtime.invoke` for direct agent invocations outside a workflow.

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
        response_schema = None;
      };
      Human_approval {
        prompt_template = "Research complete. Continue to summarize?";
        timeout = 60.0;
        allowed_roles = ["admin"];
      };
      Agent_call {
        agent_id = "summarizer";
        prompt_template = "Summarize this: {{result.text}}";
        response_schema = None;
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

The third step uses `{{result.text}}` to pull the assistant text from the previous `Agent_call` sibling. Because the approval step sits between the two agents, `result` at that point refers to the researcher's structured output.

## JSON workflow format

A workflow definition can be loaded from JSON. Deserialize into a `workflow_def` (which carries `[@@deriving yojson]`) and wrap it in a `workflow` record with `on_complete = None`:

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

A step is serialized as `["StepType", arguments]`. The argument shape depends on the step type. Only `workflow_def` is JSON-serializable; `workflow.on_complete` is a closure and is not part of the wire format.

## See also

- [Overview](overview.md) -- SDK architecture overview
- [Agent API](agent.md) -- Agent configuration and runtime management
- [examples/sequential_workflow.json](../../examples/sequential_workflow.json) -- Workflow JSON example
