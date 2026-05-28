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
}

(** Execute a single workflow step, returning its result as JSON.
    Recursively dispatches to the appropriate handler based on step variant. *)
val execute_step :
  exec_context -> workflow_step -> (Yojson.Safe.t, error_category) result

(** Execute a complete workflow, recording timing and invoking on_complete callback.
    Returns [Ok workflow_result] on success or partial completion,
    [Error error_category] on unrecoverable failure. *)
val execute_workflow :
  exec_context -> workflow -> (workflow_result, error_category) result
