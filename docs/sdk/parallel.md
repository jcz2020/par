<!-- language: en -->

**English** · [简体中文](../zh/sdk/parallel.md)

> Source-of-truth: `lib/core/runtime.ml`, `lib/core/types.ml`, `lib/core/workflow_engine.ml`.

# Parallel Multi-Agent Dispatch API Reference

This document covers `Runtime.invoke_parallel`, the convenience API for dispatching multiple agents concurrently within a single Runtime. Each agent runs in its own Eio fiber with an isolated tool registry, and results are collected and optionally merged.

## Overview

Parallel dispatch solves the "fan-out, fan-in" pattern: run N agents on different inputs (or the same input with different configurations), collect their results, and merge into a single output. This is the OCaml equivalent of LangGraph's `Send` or CrewAI's `and_()`.

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

Per-agent configuration for parallel dispatch:

```ocaml
type agent_dispatch_spec = {
  agent_id          : string;
  input             : string option;
  workspace         : Workspace.workspace option;
  approval_handler  : Approval.approval_handler option;
  blocking_approval : bool;
}
```

| Field | Description |
|-------|-------------|
| `agent_id` | Required. The agent to dispatch (must be registered via `make_agent`). |
| `input` | Optional prompt override. If `None`, the agent uses its default behavior. |
| `workspace` | Optional per-agent workspace. Overrides the runtime-level workspace for this agent's tool handlers. Useful for sandboxing parallel agents to different file-system roots. |
| `approval_handler` | Optional per-agent handler override. Takes precedence over the handler set on `agent_config` when both are present. |
| `blocking_approval` | Default `false`. When `true`, if this agent triggers an approval during execution, the entire parallel node waits for resolution. When `false` (default), only this agent's branch suspends; other branches continue. |

## `parallel_invoke_result`

Returned after all branches complete (or after `Fail_fast` stops them):

```ocaml
type parallel_invoke_result = {
  successes : Types.invoke_result list;
  failures  : (agent_dispatch_spec * error_category) list;
  merged    : Yojson.Safe.t option;
}
```

| Field | Description |
|-------|-------------|
| `successes` | Results from agents that completed successfully. |
| `failures` | Agents that failed, paired with their spec and the error. |
| `merged` | The result of applying `merge_fn` to all success results. `None` if no results or no `merge_fn`. |

## Controlling parallelism

### `parallel_limit`

Controls the maximum number of agents running concurrently (via `Eio.Semaphore`):

```ocaml
(* Run up to 3 agents at a time, even with 10 specs *)
Runtime.invoke_parallel ~rt ~specs ~parallel_limit:3 ()
```

When the limit is lower than the number of specs, agents queue and run as slots become available.

### `failure_policy`

Reuses the existing `failure_policy` from the workflow engine:

```ocaml
type failure_policy =
  | Fail_fast                                     (* Stop on first error *)
  | Continue_on_failure                           (* Skip failed steps, keep running *)
  | Conditional of { on_failure : workflow_step } (* Run a compensation step on failure *)
```

| Policy | Behavior |
|--------|----------|
| `Fail_fast` | First error stops all branches. Remaining branches are cancelled. |
| `Continue_on_failure` | Failed branches are skipped. Only successful results appear in `successes`. |
| `Conditional` | On failure, run the `on_failure` step (e.g., fallback agent, cleanup). |

## Merging results with `merge_fn`

The `merge_fn` parameter lets you combine branch results into a single output, similar to LangGraph's reducer pattern:

```ocaml
(* Default: wrap results in a JSON list *)
let default_merge results = `List results

(* Custom: concatenate text outputs *)
let concat_merge results =
  let texts = List.filter_map (fun r ->
    match r.Types.response.text with t -> Some t | _ -> None
  ) results in
  `String (String.concat "\n---\n" texts)

(* Custom: count successes *)
let count_merge results = `Int (List.length results)
```

If `merge_fn` is not provided, results are wrapped in a JSON list (`\`List [...]`).

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

## Per-agent workspace isolation

Each parallel branch gets its own `per_call_registry` (tool registry). If you provide a `workspace` on the spec, that agent's tools operate in a different file-system root:

```ocaml
let spec_a =
  { agent_id = "reader"; input = Some "Read /project-a/README.md";
    workspace = Some (Workspace.create "/project-a"); ... }
in
let spec_b =
  { agent_id = "reader"; input = Some "Read /project-b/README.md";
    workspace = Some (Workspace.create "/project-b"); ... }
in
(* Each agent sees only its own workspace *)
```

When `workspace` is `None`, the agent uses the runtime-level workspace.

## HITL x Parallel interaction

Parallel dispatch integrates with the [HITL framework](hitl.md):

- **Non-blocking (default)**: If an agent triggers an approval via an async or webhook handler, only that branch suspends. Other branches continue running.
- **Blocking** (`blocking_approval = true`): If set on a spec, the entire parallel node waits for that agent's approval to be resolved before collecting results.
- **Per-agent handler**: Each spec can override the approval handler. This means different agents in the same parallel batch can use different approval strategies.

```ocaml
let specs = [
  { agent_id = "safe_agent";    input = Some "Analyze data";
    approval_handler = None; blocking_approval = false; ... };
  { agent_id = "risky_agent";   input = Some "Send notification";
    approval_handler = Some webhook_handler;
    blocking_approval = false; ... };  (* suspends independently *)
]
```

## Cancellation

Pass an `Eio.Switch.t` as `cancellation_token` to cancel all branches mid-flight:

```ocaml
Eio.Switch.run (fun cancel_switch ->
  (* Start parallel dispatch in a background fiber *)
  let fiber = Eio.Fiber.fork_promise (fun () ->
    Runtime.invoke_parallel ~rt ~specs
      ~cancellation_token:cancel_switch ())
  in
  (* Later: cancel all branches *)
  Eio.Switch.release cancel_switch)
```

When cancelled, branches stop and partial results (if any) are collected.

## Complete example

```ocaml
open Par

let () = Eio_main.run (fun env ->
  Eio.Switch.run (fun switch ->
    let config = Runtime.default_config ~persistence:(`Sqlite ":memory:") () in
    match Runtime.create ~config switch with
    | Error e -> prerr_endline (Runtime.string_of_error_category e)
    | Ok rt ->
      (* Create agents *)
      let summarizer =
        Runtime.make_agent ~id:"summarizer" ~model:"openai/gpt-4o-mini" ()
      in
      let translator =
        Runtime.make_agent ~id:"translator" ~model:"openai/gpt-4o-mini" ()
      in
      ignore (summarizer, translator);

      (* Dispatch 3 parallel summarizations *)
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

## Python cross-reference

The Python bindings expose parallel dispatch through ctypes. See the [Python FFI documentation](../bindings/python/) for:

- `Runtime.invoke_parallel(specs: list[dict]) -> dict` where each spec dict has keys `agent_id`, `input`, `workspace`, `approval_handler`, `blocking_approval`.
- Per-agent workspace and approval handler overrides work identically to the OCaml API.

## Relationship to Workflow API

`Runtime.invoke_parallel` is a convenience wrapper around the existing [Workflow API](workflow.md) `Parallel` step type. Internally, it constructs a workflow with a `Parallel` node containing one `Agent_call` per spec, submits it, and collects results.

If you need more complex orchestration (sequential steps mixed with parallel, conditional branching, checkpoints), use the Workflow API directly. If you just need "run N agents in parallel and merge", `invoke_parallel` is the simpler entry point.
