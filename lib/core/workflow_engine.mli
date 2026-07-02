open Types

(* -------------------------------------------------------------------------- *)
(* Workflow engine — approval deadline tracking                         *)
(* -------------------------------------------------------------------------- *)

module Approval_deadline : sig
  type t
  val record : Workflow_run_id.t -> deadline:float -> switch:Eio.Switch.t -> unit
  val lookup : Workflow_run_id.t -> t option
  val remove : Workflow_run_id.t -> unit
  val deadline_of : t -> float
  val switch_of : t -> Eio.Switch.t
end

(* -------------------------------------------------------------------------- *)
(* Workflow engine — execution context and entry points                 *)
(* -------------------------------------------------------------------------- *)

type exec_context = {
  variables : (string * Yojson.Safe.t) list;
  token : cancellation_token;
  agent_resolver : string -> agent_config option;
  tool_resolver : string -> tool_descriptor option;
  llm : llm_service;
  registry : Tool_registry.t;
  parallel_limit : int;
  failure_policy : failure_policy;
  workflow_resolver : string -> workflow option;
  on_step_complete : (int list -> Yojson.Safe.t -> unit) option;
  workflow_run_id : Workflow_run_id.t option;
  workflow_id_resolver : unit -> string option;
  workspace : Workspace.workspace;
}

exception Workflow_suspended of {
  prompt : string;
  allowed_roles : string list;
  checkpoint : workflow_checkpoint;
}

(** Build a checkpoint from the current execution context. *)
val make_checkpoint :
  step_path:int list ->
  ?step_results:Yojson.Safe.t list ->
  ?allowed_roles:string list option ->
  exec_context -> workflow_checkpoint

(** Execute a single workflow step, returning its result as JSON.
    Recursively dispatches to the appropriate handler based on step variant.
    May raise [Workflow_suspended] for Human_approval steps. *)
val execute_step :
  ?path:int list ->
  exec_context -> workflow_step -> (Yojson.Safe.t, error_category) result

(** Execute a complete workflow, recording timing and invoking on_complete callback.
    Returns [Ok workflow_result] on success or partial completion,
    [Error error_category] on unrecoverable failure.
    May raise [Workflow_suspended] for Human_approval steps. *)
val execute_workflow :
  exec_context -> workflow -> (workflow_result, error_category) result

(** Resume a workflow from a checkpoint. Re-enters execution at the
    suspended step (which must be Human_approval), treats it as approved,
    and continues executing remaining siblings.

    Returns [Ok json] with the final step result, or [Error] for
    unsupported step types (Parallel, Map_reduce) at the step_path.
    May raise [Workflow_suspended] if a subsequent Human_approval is
    encountered. *)
val resume_from_checkpoint :
  exec_context -> workflow_step -> workflow_checkpoint ->
    (Yojson.Safe.t, error_category) result
