<!-- language: en -->

**English** · [简体中文](../zh/sdk/invoke_context.md)

# invoke_context — Per-Call Isolation

## Overview

When multiple `Runtime.invoke` calls run concurrently on the same runtime, each call needs its own isolated state: session id, metrics, tool-call hooks, skill snapshots, and steering queues. Without isolation, one call's hooks would leak into another's, metrics would mix across sessions, and the system prompt appendix from one invocation would bleed into the next.

The `Invoke_context` module solves this with per-call isolation via Eio's fiber-local binding. Every `Runtime.invoke` gets a fresh `invoke_context` record, bound to the calling fiber using `Eio.Fiber.with_binding`. This binding propagates automatically into child fibers spawned by Engine's parallel tool dispatch, so tools running concurrently within a single invocation share the same context while remaining isolated from other invocations.

The module is part of the concurrency architecture shipped in v0.7.1. It follows the hybrid carrier model: per-call state lives in a record delivered via fiber-local storage, not threaded through function parameters.

## The invoke_context Type

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

The type is `private`, meaning you can read its fields but cannot construct a record directly. Use `Invoke_context.create` to build one.

| Field | Description |
|-------|-------------|
| `session_id` | Identifies the conversation session. Memory tools use this for scope isolation. |
| `metrics_accumulator` | Per-call counters (LLM calls, tool invocations, task completions). |
| `user_activated_skills_snapshot` | Skill ids active for this invocation, captured at entry. |
| `tool_call_hooks_snapshot` | Tool-call hooks active for this invocation, captured at entry. |
| `steering_queue` | Queue for mid-invocation steering instructions. |
| `followup_queue` | Queue for follow-up messages appended after the current turn. |
| `system_prompt_appendix` | Optional text appended to the system prompt for this invocation. |

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

Builds a fresh `invoke_context`. All optional parameters default to empty values: `session_id` becomes `"unknown"`, lists become `[]`, queues become fresh empty queues, and `system_prompt_appendix` becomes `None`.

You rarely call `create` directly. `Runtime.invoke` constructs the context internally from the runtime's current state. The function is exposed for advanced use cases such as testing or building custom dispatch loops.

## Per-Call Isolation

### How it works

When `Runtime.invoke` is called, it:

1. Snapshots the runtime's current state (session id, hooks, skills) into a fresh `invoke_context`.
2. Binds that context to the calling fiber using `Invoke_context.with_context`, which wraps `Eio.Fiber.with_binding`.
3. Runs the ReAct loop inside that binding scope.

The binding propagates automatically. When Engine's parallel tool dispatch forks child fibers via `Eio.Fiber.fork_promise`, those fibers inherit the same `invoke_context`. This means all tools within one invocation see the same session id, the same hooks, and the same metrics accumulator.

### Reentrancy safety

Because each `Runtime.invoke` creates its own context, two concurrent invokes on the same runtime do not interfere. Call A's metrics stay in call A's accumulator. Call B's steering queue is separate from call A's. The session id for call A does not leak into call B.

This is the core guarantee that makes `Runtime.invoke` safe for reentrancy: calling invoke from within a tool handler, from a fiber, or from multiple threads simultaneously.

### Accessing the current context

From inside a tool handler, middleware, or any code running within an `invoke` call, use `get_current` or `get_current_exn` to read the bound context:

```ocaml
val get_current : unit -> invoke_context option
val get_current_exn : unit -> invoke_context
```

`get_current` returns `None` when no context is bound (for example, code running outside `Runtime.invoke`). Use this for graceful degradation in code paths that pre-date the carrier migration.

`get_current_exn` raises `Failure` when no context exists. Use it on hot paths where a binding must exist, because its absence indicates a programming error (calling invoke-only code without going through `Runtime.invoke`).

### with_context

```ocaml
val with_context : invoke_context -> (unit -> 'a) -> 'a
```

Binds `ctx` for the duration of `f`. The binding propagates into any fibers forked within `f`. This is the low-level primitive that `Runtime.invoke` uses internally. You can also use it directly when building custom execution contexts, for example in tests where you want to simulate a specific session id:

```ocaml
let ctx = Invoke_context.create ~session_id:"test-session-42" () in
Invoke_context.with_context ctx (fun () ->
  let current = Invoke_context.get_current_exn () in
  assert (current.session_id = "test-session-42")
)
```

## invoke_async — Background Execution

`Runtime.invoke_async` runs an invocation in a background fiber and returns immediately with a handle you can use to await, cancel, or poll the result.

### Signature

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

The signature mirrors `Runtime.invoke` except the return type: instead of blocking until completion, it returns an `invoke_handle` immediately.

### The invoke_handle type

```ocaml
type invoke_handle  (* opaque *)

val invoke_handle_await :
  invoke_handle ->
  (invoke_result, error_category * conversation) result

val invoke_handle_cancel : invoke_handle -> unit

val invoke_handle_status : invoke_handle -> invoke_status

val invoke_handle_token : invoke_handle -> cancellation_token
```

| Function | Description |
|----------|-------------|
| `invoke_handle_await` | Block until the invoke reaches a terminal state and return the result. |
| `invoke_handle_cancel` | Request cancellation. Idempotent. The fiber observes cancellation at its next check and terminates. |
| `invoke_handle_status` | Poll the current status without blocking. |
| `invoke_handle_token` | Return the cancellation token backing this handle. Useful for composing with a parent switch. |

The `invoke_status` type tracks the background fiber's lifecycle:

```ocaml
type invoke_status = Running | Completed | Cancelled | Failed
```

### Example: dispatching two agents concurrently

```ocaml
open Par

let parallel_agents rt =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun switch ->
      let h1 = Runtime.invoke_async rt
        ~agent_id:"researcher"
        ~message:"Find recent papers on OCaml effects" () in
      let h2 = Runtime.invoke_async rt
        ~agent_id:"summarizer"
        ~message:"Summarize the Eio library documentation" () in
      (* Both run concurrently; await each *)
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

### Cancellation from outside

```ocaml
let h = Runtime.invoke_async rt ~agent_id:"slow-agent"
  ~message:"Do something time-consuming" () in
(* Maybe the user changed their mind *)
Invoke_context.invoke_handle_cancel h;
match Invoke_context.invoke_handle_status h with
| Invoke_context.Cancelled -> Printf.printf "Cancelled\n"
| _ -> Printf.printf "Still running or finished\n"
```

## Custom Context

Both `Runtime.invoke` and `Runtime.invoke_async` accept an optional `?context` parameter:

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

When provided, the runtime uses this context instead of creating a fresh one. This gives you explicit control over the session id, the system prompt appendix, and other per-call state.

### When to use a custom context

- **Session pinning**: Force multiple invokes to share the same session id for conversation continuity.
- **Testing**: Create a context with a known session id to test memory scoping or metrics isolation.
- **System prompt injection**: Attach a `system_prompt_appendix` to the context to inject per-turn dynamic content.

### Default behavior

When `?context` is omitted (the common case), `Runtime.invoke` constructs a fresh `invoke_context` internally. The session id defaults to `"unknown"` unless `Runtime.set_session_id` was called earlier, hooks and skills are snapshotted from the runtime's current state, and `system_prompt_appendix` is `None`.

## Dynamic System Prompt

The `?system_prompt_appendix` parameter lets you inject text into the system prompt for a single invocation without modifying the agent's configuration.

```ocaml
val Runtime.invoke :
  runtime ->
  agent_id:string ->
  message:string ->
  ...
  ?system_prompt_appendix:string ->
  ...
```

### Where it appears in the prompt

The appendix is appended **after** the base system prompt, skill overlay, and tool suffix. The final system prompt assembly order is:

1. Base system prompt (from `agent_config.system_prompt` or rendered `system_prompt_template`)
2. Skill overlay (from active skills' `system_prompt_override`)
3. Tool suffix (the formatted list of available tools)
4. **System prompt appendix** (from `?system_prompt_appendix` or `invoke_context.system_prompt_appendix`)

### Example: injecting time-sensitive context

```ocaml
let now = Unix.gettimeofday () in
let time_str = Unix.(gmtime now) |> fun tm ->
  Printf.sprintf "%04d-%02d-%02d %02d:%02d UTC"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min in
let appendix = Printf.sprintf "Current time: %s. Use this for time-sensitive decisions." time_str in
Runtime.invoke rt ~agent_id:"analyst"
  ~message:"What happened today?" ~system_prompt_appendix:appendix ()
```

The same parameter works with `invoke_async` and `invoke_generate`. When a `?context` is also provided and that context has its own `system_prompt_appendix`, the explicit `?system_prompt_appendix` parameter takes precedence.

## Appendix text helper

```ocaml
val Invoke_context.appendix_text : unit -> string
```

Returns the `system_prompt_appendix` from the current invoke context, prefixed with `"\n\n"` when present, or `""` when no context exists or no appendix is set. Used internally by the prompt builder to append the appendix text cleanly.

## See also

- [Agent API](agent.md) -- `Runtime.invoke`, agent configuration, tool registration
- [Memory API](memory.md) -- Memory tools use `Invoke_context.get_current_exn().session_id` for scope isolation
- [Concurrency Model](../explanation/concurrency-model.md) -- How Eio structured concurrency works in PAR
- [How-to: Concurrency](../howto/concurrency.md) -- Practical concurrency patterns
