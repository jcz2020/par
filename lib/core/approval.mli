(** HITL approval types.

    This module defines the type-level vocabulary for Human-in-the-Loop
    approval flows.  An [approval_outcome] represents the decision made by
    an approver; an [approval_context] carries the full context needed to
    make that decision; and an [approval_handler] describes how approval
    requests are routed (locally, asynchronously, or via webhook).

    Companion to the [Approval_required] variant in [Types.handler_result].
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

(** {1 Approval context} *)

(** The context passed to an approval handler. Contains everything
    an approver needs to make an informed decision. *)
type approval_context = {
  agent_id : string;
      (** The agent requesting approval. *)
  tool_name : string;
      (** The tool that triggered the approval gate. *)
  tool_input : Yojson.Safe.t;
      (** The arguments the tool would receive. *)
  conversation : Types.conversation;
      (** The conversation state at the time of the request. *)
  pending_action : Yojson.Safe.t;
      (** A structured description of the action about to be taken. *)
  metadata : (string * Yojson.Safe.t) list;
      (** Arbitrary key-value metadata (e.g. risk score, policy tags). *)
}

(** {1 Approval handler} *)

(** How approval requests are dispatched.

    - [Sync_local]: in-process synchronous callback.  Suitable for
      development/testing and simple deployments.
    - [Async_callback]: in-process asynchronous callback returning an
      {!type:Eio.Promise.t}.  The engine suspends until the promise
      resolves.  Uses [Eio.Promise.t] (not [Lwt.t]) per codebase
      convention.
    - [Webhook]: cross-process HTTP webhook.  The engine POSTs the
      approval context to [url] with HMAC-SHA256 signature in
      [secret], and waits up to [timeout_sec] seconds for a response. *)
type approval_handler =
  | Sync_local of (approval_context -> approval_outcome)
  | Async_callback of (approval_context -> approval_outcome Eio.Promise.t)
  | Webhook of { url : string; secret : string; timeout_sec : float }

(** {1 Constants} *)

(** Default approval timeout in seconds (300.0 = 5 minutes).
    Conservative default — production deployments should override
    via [Webhook.timeout_sec] or agent config. *)
val default_timeout : float
