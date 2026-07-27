<!-- language: en -->

**English** · [简体中文](../zh/sdk/hitl.md)

> Source-of-truth: `lib/core/approval.ml`, `lib/core/types.ml`, `lib/core/engine.ml`, `lib/core/runtime.ml`.

# Human-in-the-Loop (HITL) API Reference

This document covers PAR's suspend-resume approval framework. An agent can pause mid-execution when a tool requires human approval, persist its state to SQLite, and resume later once a human (or automated system) responds. Approvals survive process restarts.

## When to use HITL

Use HITL when an agent takes actions that need oversight before proceeding:

- Sending emails, making API calls, or modifying external systems
- Accessing sensitive data or performing financial transactions
- Any action where a wrong tool invocation could cause irreversible damage

Without HITL, a tool either runs or it doesn't. With HITL, a tool can ask "should I proceed?" and wait for a response.

## Core types

### `approval_outcome`

The result of a human (or automated) approval decision:

```ocaml
type approval_outcome =
  | Approved                                    (* Proceed with the tool call *)
  | Rejected of { reason : string }             (* Deny the action, explain why *)
  | Modified of { new_input : Yojson.Safe.t }   (* Proceed, but with different parameters *)
  | Escalated of { target : string }            (* Forward to a different agent or handler *)
  | Timeout                                     (* No response within the allowed window *)
```

Each variant carries specific semantics:

| Variant | What happens next |
|---------|-------------------|
| `Approved` | The original tool executes with its original input. |
| `Rejected` | The tool result is marked as rejected. The agent loop continues; the agent sees the rejection and adjusts. |
| `Modified` | The tool re-runs with `new_input` instead of the original parameters. |
| `Escalated` | Control transfers to the named `target` agent, similar to a handoff. |
| `Timeout` | The tool result is marked as rejected, and an `Approval_timeout` event is emitted. |

### `approval_context`

Information passed to the approval handler when a tool triggers approval:

```ocaml
type approval_context = {
  agent_id      : string;
  tool_name     : string;
  tool_input    : Yojson.Safe.t;
  conversation  : Conversation.t;
  pending_action: Yojson.Safe.t;
  metadata      : (string * Yojson.Safe.t) list;
}
```

The handler receives everything it needs to make an informed decision: which tool is being called, what input it would receive, the full conversation so far, and any metadata attached to the invocation.

### `approval_handler`

The handler ADT supports three deployment modes:

```ocaml
type 'a approval_handler =
  | Sync_local of (approval_context -> approval_outcome)
  | Async_callback of (approval_context -> approval_outcome Eio.Promise.t)
  | Webhook of {
      url         : string;
      secret      : string;
      timeout_sec : float;
    }
```

#### `Sync_local`

A synchronous OCaml function. The engine calls it directly and blocks on the result. Best for development, testing, and single-process deployments where approval logic is simple.

```ocaml
let my_handler (ctx : Types.approval_context) =
  (* Simple policy: approve non-destructive tools, reject the rest *)
  match ctx.tool_name with
  | "read_file" | "search" -> Approval.Approved
  | _ -> Approval.Rejected { reason = "Manual approval required" }
```

#### `Async_callback`

Returns an `Eio.Promise.t` that resolves later. The engine suspends execution and persists the pending approval to SQLite. The approval can be resolved from outside the agent's execution context. This is the standard choice for production OCaml deployments.

```ocaml
let async_handler (ctx : Types.approval_context) promise =
  (* In production: push to a UI queue, email a reviewer, etc.
     When resolved, the promise carries the outcome. *)
  ignore (ctx, promise)
```

#### `Webhook`

An HTTP endpoint that receives a POST request with the approval context as JSON. The engine suspends and waits for the external system to call `Runtime.resume_approval`. This is the standard choice for cross-process deployments, Python FFI usage, and remote approval UIs.

```ocaml
let webhook_handler =
  Approval.Webhook {
    url         = "https://approval.example.com/hooks/par";
    secret      = "my-hmac-secret";
    timeout_sec = 600.0;  (* 10 minutes *)
  }
```

### `handler_result.Approval_required`

When a tool wants to request approval, it returns an `Approval_required` variant from its handler:

```ocaml
type handler_result =
  | Success of { output : Yojson.Safe.t; ... }
  | Error of { message : string; ... }
  | Handoff of { target_agent_id : string; ... }
  | Approval_required of {
      tool_name     : string;
      tool_input    : Yojson.Safe.t;
      prompt        : string;           (* Human-readable message for the approver *)
      timeout       : float option;     (* Override per-handler default *)
      allowed_roles : string list;      (* Who can approve *)
    }
```

The `prompt` field gives the approver context about what the tool is about to do. The agent's `approval_handler` (set on `agent_config`) determines how this request is dispatched.

## Setting up the approval handler

### `agent_config.approval_handler`

Every agent has an optional `approval_handler` field. When set, tools returning `Approval_required` route through this handler. When `None`, a tool returning `Approval_required` causes a hard error (the tool does not execute).

Set it via `make_agent`:

```ocaml
let agent =
  Par.Runtime.make_agent
    ~id:"assistant"
    ~model:"openai/gpt-4o-mini"
    ~approval_handler:(Approval.Sync_local my_handler)
    ()
```

In the Python bindings:

```python
from par_runtime import Runtime

with Runtime(config) as rt:
    agent = rt.make_agent(
        id="assistant",
        model="openai/gpt-4o-mini",
    )
    # Register approval handler (Callable → sync, str → webhook URL)
    rt.register_approval_handler(my_handler_fn)
```

## Suspend-resume flow

The full lifecycle of an approval request:

```
1. Agent invokes a tool
2. Tool returns Approval_required { prompt = "Approve email send?"; ... }
3. Engine reads agent.approval_handler
4. Handler dispatches (Sync_local → direct call, Async/Webhook → suspend)
5. If async/webhook:
   a. Pending approval written to SQLite approvals table
   b. Approval_requested event emitted
   c. Agent state persisted with conversation snapshot
   d. invoke_result returned with status = Awaiting_approval
6. External resolver calls Runtime.resume_approval ~run_id ~outcome ~approver
7. Pending approval loaded from SQLite, validated, deleted
8. Outcome injected into the ReAct loop at the suspension point
9. Agent continues execution with the approval outcome
```

### `Runtime.resume_approval`

Resume a suspended agent by delivering the approval outcome:

```ocaml
val Runtime.resume_approval :
  rt:runtime ->
  run_id:string ->
  outcome:Approval.approval_outcome ->
  approver:string ->
  (unit, error_category) result
```

Parameters:

| Parameter | Description |
|-----------|-------------|
| `run_id` | The run ID returned when the agent suspended. |
| `outcome` | The `approval_outcome` to inject (Approved, Rejected, Modified, Escalated, Timeout). |
| `approver` | Identifier for who provided the decision (for audit trail). |

Possible errors:

- `Invalid_input` if `run_id` is unknown or the pending approval has expired.
- `Internal` if the conversation snapshot hash does not match (state drifted).

### Cross-process persistence

Pending approvals are stored in the SQLite `approvals` table:

| Column | Type | Description |
|--------|------|-------------|
| `run_id` | TEXT (PK) | Unique identifier for this suspended run. |
| `agent_id` | TEXT | Which agent is suspended. |
| `payload` | TEXT | Serialized approval context + conversation snapshot. |
| `created_at` | REAL | Unix timestamp when the approval was created. |
| `expires_at` | REAL | Unix timestamp when the approval expires. |

If the process crashes and restarts, `resume_approval` loads the pending state from SQLite and re-dispatches. This is how approvals survive restarts.

## Wave 3 simplification: re-dispatch

When `resume_approval` resumes a suspended agent, it re-dispatches the work item to the agent's ReAct loop. For `Sync_local` handlers that need to return a stored outcome (for example, replaying a previously granted approval), the handler can simply return the stored `approval_outcome` directly:

```ocaml
(* Handler that replays a stored outcome *)
let replay_handler (stored : Approval.approval_outcome) =
  Approval.Sync_local (fun _ctx -> stored)
```

This pattern is used internally by the engine when re-dispatching after resume. It replaces the original handler with a `Sync_local` that returns the stored outcome, avoiding a second approval prompt.

## Events

The HITL framework emits seven event variants for observability:

| Event | When |
|-------|------|
| `Approval_requested` | Agent suspended, awaiting external resolution. |
| `Approval_granted` | Outcome is `Approved`. |
| `Approval_rejected` | Outcome is `Rejected`. |
| `Approval_modified` | Outcome is `Modified`. |
| `Approval_escalated` | Outcome is `Escalated`. |
| `Approval_timeout` | Outcome is `Timeout`. |
| `Approval_handler_missing` | Tool returned `Approval_required` but no handler is configured. |

## Complete example: sync handler with resume

```ocaml
open Par

let approval_policy (ctx : Types.approval_context) =
  match ctx.tool_name with
  | "send_email" ->
   Printf.printf "Approve sending email? (y/n): %!";
    let response = read_line () in
    if String.lowercase_ascii response = "y"
    then Approval.Approved
    else Approval.Rejected { reason = "User denied" }
  | _ -> Approval.Approved  (* Approve everything else *)

let () = Eio_main.run (fun env ->
  Eio.Switch.run (fun switch ->
    let config = Runtime.default_config ~persistence:(`Sqlite ":memory:") () in
    match Runtime.create ~config switch with
    | Error e -> prerr_endline (Runtime.string_of_error_category e)
    | Ok rt ->
      let agent =
        Runtime.make_agent
          ~id:"mailer"
          ~model:"openai/gpt-4o-mini"
          ~approval_handler:(Approval.Sync_local approval_policy)
          ()
      in
      let result = Runtime.invoke ~rt ~agent "Send a hello email to alice@example.com" in
      print_endline result.Types.response.text;
      ignore (Runtime.close rt)))
```

## Complete example: webhook handler

```ocaml
let webhook_config =
  Approval.Webhook {
    url         = "https://approval.example.com/hooks/par";
    secret      = "hmac-secret-key";
    timeout_sec = 600.0;
  }

let agent =
  Runtime.make_agent
    ~id:"production-agent"
    ~model:"openai/gpt-4o"
    ~approval_handler:webhook_config
    ()
```

When the agent triggers approval:

1. The engine suspends and writes the pending approval to SQLite.
2. A POST request goes to `https://approval.example.com/hooks/par` with the approval context JSON.
3. Your external service processes the request and calls `Runtime.resume_approval` when ready.
4. The agent resumes with the outcome.

## Python cross-reference

The Python bindings expose the same HITL capabilities through ctypes. See the [Python FFI documentation](../bindings/python/) for:

- `Runtime.register_approval_handler(handler)` where `handler` is a `Callable` (sync) or a `str` (webhook URL).
- `Runtime.resume_approval(run_id, outcome_dict)` to deliver approval outcomes.
- `Runtime.invoke_parallel(specs)` with per-agent approval overrides.

## Migration

If you have existing code that pattern-matches on `handler_result`, you need to add an arm for `Approval_required`:

```ocaml
(* Before v0.8.0 *)
match result with
| Success _ -> ...
| Error _ -> ...
| Handoff _ -> ...

(* After v0.8.0 *)
match result with
| Success _ -> ...
| Error _ -> ...
| Handoff _ -> ...
| Approval_required _ -> (* handle approval request *)
```

The OCaml compiler warns (not errors) on missing arms, so existing code compiles but you should add the arm to handle approval requests properly.
