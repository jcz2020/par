(** HITL approval types.

    This module defines the type-level vocabulary for Human-in-the-Loop
    approval flows.  [approval_outcome] is the decision returned by an
    approver; [approval_handler] is a parameterized handler type —
    the ['ctx] parameter is instantiated by the caller (typically
    [Types.approval_context] in the engine layer) and decouples
    this module from concrete context representations, breaking what
    would otherwise be a cyclic [.cmi] dependency between
    {!Types} and [Approval].

    Phantom type [('sync, 'async) handler] is deferred to v0.8.1 per
    ROADMAP §4. *)

(** {1 Approval outcome} *)

(** The decision returned by an approver. *)
type approval_outcome =
  | Approved
      (** The action is allowed to proceed. *)
  | Rejected of { reason : string }
      (** The action is denied. [reason] explains why. *)
  | Modified of { new_input : Yojson.Safe.t }
      (** The action is allowed but with modified input. [new_input]
          replaces the original [tool_input] when re-executing. *)
  | Escalated of { target : string }
      (** The decision is escalated to [target] (e.g. a senior approver
          or another agent). Semantics mirror [Handoff] in
          [Types.handler_result]. *)
  | Timeout
      (** No decision was received within the allowed time window.
          Treated as a hard rejection by default. *)

(** Serialize an outcome to JSON. *)
val outcome_to_json : approval_outcome -> Yojson.Safe.t

(** Deserialize an outcome from JSON. Returns [Error msg] on invalid
    shape rather than raising. *)
val outcome_of_json : Yojson.Safe.t -> (approval_outcome, string) result

(** {1 Approval handler (parameterized over context type)} *)

(** How approval requests are dispatched.  The ['ctx] type parameter
    represents the context record passed to the handler at runtime;
    it is instantiated by the engine (typically to
    [Types.approval_context]).  Parameterizing here keeps this module
    free of any [{!Types}] reference, which is required to avoid a
    dependency cycle at the [.cmi] level.

    - [Sync_local]: in-process synchronous callback.  Suitable for
      development/testing and simple deployments.
    - [Async_callback]: in-process asynchronous callback returning an
      {!type:Eio.Promise.t}.  The engine suspends until the promise
      resolves.  Uses [Eio.Promise.t] (not [Lwt.t]) per codebase
      convention.
    - [Webhook]: cross-process HTTP webhook.  The engine POSTs the
      approval context to [url] with HMAC-SHA256 signature in
      [secret], and waits up to [timeout_sec] seconds for a response. *)
type 'ctx approval_handler =
  | Sync_local of ('ctx -> approval_outcome)
  | Async_callback of ('ctx -> approval_outcome Eio.Promise.t)
  | Webhook of { url : string; secret : string; timeout_sec : float }

(** {1 Constants} *)

(** Default approval timeout in seconds (300.0 = 5 minutes).
    Conservative default — production deployments should override
    via [Webhook.timeout_sec] or agent config. *)
val default_timeout : float
