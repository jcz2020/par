open Types

(** Per-call isolation context for concurrent [Runtime.invoke].

    Addresses the foundational concurrency architecture: multiple invokes
    running concurrently on one runtime must not share mutable per-call state
    (session_id, metrics accumulator, tool-call hooks, skill snapshots,
    steering/followup queues).

    This module implements the {i hybrid carrier model}: per-call state lives
    in an [invoke_context] record delivered via [Eio.Fiber.with_binding].
    The binding propagates automatically into fibers forked by Engine's
    parallel tool dispatch ([Eio.Fiber.fork_promise]), so Engine.run_agent's
    signature is unchanged — it reads per-call state via [get_current].

    @see "docs/STRATEGY.md" §11 for the architectural-correctness labelling
    of every field migration in this module. *)

(** The status of an asynchronous invoke. *)
type invoke_status = Running | Completed | Cancelled | Failed

(** Per-call state carried through the fiber-local binding.

    Constructed at [Runtime.invoke] entry from a snapshot of the relevant
    runtime fields. Once bound, it is the single source of truth for the
    duration of that invoke (and any fibers it forks).

    Marked [private] so callers can read fields but cannot construct the
    record directly — use [create]. *)
type invoke_context = private {
  session_id : string;
  metrics_accumulator : Metrics.counters;
  user_activated_skills_snapshot : string list;
  tool_call_hooks_snapshot : Hook.tool_call_hook list;
  steering_queue : Steering_queue.t;
  followup_queue : Steering_queue.t;
  system_prompt_appendix : string option;
}

(** The fiber-local key. Exported so callers (e.g. Engine) can read the
    binding directly via [Eio.Fiber.get] on hot paths. *)
val invoke_context_key : invoke_context Eio.Fiber.key

(** Build a fresh invoke_context. All fields default to empty/unknown when
    omitted; the caller ([Runtime.invoke]) supplies the runtime snapshot. *)
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

(** Returns the invoke_context bound to the current fiber, or [None] when
    no binding exists (e.g. calls outside [with_context]). Graceful
    degradation for code paths that pre-date the carrier migration. *)
val get_current : unit -> invoke_context option

val appendix_text : unit -> string

val appendix_metadata_key : string

(** Like [get_current] but raises when no binding exists. Use on hot paths
    where a binding MUST exist — its absence indicates a programming error
    (calling invoke-only code without going through [with_context]). *)
val get_current_exn : unit -> invoke_context

(** Bind [ctx] for the duration of [f]. Propagates into forked fibers. *)
val with_context : invoke_context -> (unit -> 'a) -> 'a

(** Handle returned by [Runtime.invoke_async]. Allows awaiting, cancelling,
    and polling the status of a background invoke. *)
type invoke_handle

(** Block until the invoke reaches a terminal state and yield its result. *)
val invoke_handle_await : invoke_handle -> (invoke_result, error_category * conversation) result

(** Request cancellation of the invoke. Idempotent. The fiber will observe
    the cancellation at its next cancellation check and terminate. *)
val invoke_handle_cancel : invoke_handle -> unit

(** Poll the current status without blocking. *)
val invoke_handle_status : invoke_handle -> invoke_status

(** The cancellation token backing the handle. Exposed for composition
    (e.g. nesting under a parent token's switch). *)
val invoke_handle_token : invoke_handle -> cancellation_token

(** Fork [f] as a background fiber under [sw], tracking its lifecycle in a
    fresh [invoke_handle]. The fiber sets the handle status to [Completed]
    on normal return, [Cancelled] if [Eio.Cancel.Cancelled] is raised, or
    [Failed] on any other exception. Used by [Runtime.invoke_async]. *)
val fork_invoke :
  sw:Eio.Switch.t ->
  token:cancellation_token ->
  (unit -> (invoke_result, error_category * conversation) result) ->
  invoke_handle
