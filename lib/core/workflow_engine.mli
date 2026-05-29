open Types

(* -------------------------------------------------------------------------- *)
(* §11.2 Workflow engine — execution context and entry points                 *)
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
  on_step_complete : (string -> Yojson.Safe.t -> unit) option;
  workflow_run_id : Workflow_run_id.t option;
}

exception Workflow_suspended of {
  prompt : string;
  allowed_roles : string list;
  checkpoint : workflow_checkpoint;
}

(** Build a checkpoint from the current execution context. *)
val make_checkpoint :
  ?step_path:int list ->
  ?step_results:Yojson.Safe.t list ->
  exec_context -> workflow_checkpoint

(** Execute a single workflow step, returning its result as JSON.
    Recursively dispatches to the appropriate handler based on step variant.
    May raise [Workflow_suspended] for Human_approval steps. *)
val execute_step :
  exec_context -> workflow_step -> (Yojson.Safe.t, error_category) result

(** Execute a complete workflow, recording timing and invoking on_complete callback.
    Returns [Ok workflow_result] on success or partial completion,
    [Error error_category] on unrecoverable failure.
    May raise [Workflow_suspended] for Human_approval steps. *)
val execute_workflow :
  exec_context -> workflow -> (workflow_result, error_category) result
