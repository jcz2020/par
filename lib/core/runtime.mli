open Types

type runtime

val default_event_bus_config : event_bus_config
val default_shutdown_config : shutdown_config
val default_quota : resource_quota
val default_bash_confirm : bash_confirm_config

val create :
  ?persistence:persistence_service ->
  ?event_bus:Types.event_bus_service ->
  ?llm:llm_service ->
  ?embeddings:embedding_service ->
  ?bash_policy:(module Bash_policy.POLICY) ->
  ?mcp_servers:Mcp_types.server_config list ->
  ?mcp_process_mgr:_ Eio.Process.mgr ->
  ?mcp_net:_ Eio.Net.t ->
  ?mcp_clock:_ Eio.Time.clock ->
  ?mcp_startup_policy:Mcp_types.startup_policy ->
  config:runtime_config ->
  Eio.Switch.t ->
  (runtime, error_category) result

val close : runtime -> int

val install_bash_tool :
  ?process_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t ->
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  runtime -> (unit, error_category) result
(** Idempotent: registers the bash tool with the runtime's configured policy.
    Returns Invalid_input if bash is already installed.
    Must be called after create, before any agent invocation that uses bash.
    A [process_mgr] is required for actual command execution; without it,
    the install registers a handler that will error when invoked.
    A [clock] is required for timeout enforcement; without it, commands
    that exceed [timeout] will run to completion. *)

val register_agent : runtime -> agent_config -> (unit, error_category) result

val list_agents : runtime -> agent_config list

val make_agent :
  id:string ->
  ?system_prompt:string ->
  ?system_prompt_template:system_prompt_template option ->
  model:model_config ->
  ?tools:tool_descriptor list ->
  ?max_iterations:int ->
  ?middleware:middleware_hook list ->
  ?retry_policy:retry_policy option ->
  ?context_strategy:context_strategy option ->
  ?resource_quota:resource_quota option ->
  ?max_execution_time:float option ->
  ?early_stopping_method:early_stopping_method ->
  unit ->
  (agent_config, error_category) result

val register_tool :
  runtime ->
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  handler:Tool_registry.handler_fn ->
  ?output_schema:Yojson.Safe.t ->
  ?permission:tool_permission ->
  ?timeout:float ->
  ?concurrency_limit:int ->
  ?on_update:(string -> unit) option ->
  unit ->
  (tool_binding, error_category) result

val register_skill :
  runtime -> Types.skill_descriptor ->
  (Types.skill_binding, error_category) result

val list_skills : runtime -> Types.skill_descriptor list

val make_skill :
  id:string ->
  description:string ->
  ?system_prompt_override:string ->
  ?tool_filter:Types.tool_filter ->
  ?trigger:Types.skill_trigger ->
  ?expected_output:Yojson.Safe.t ->
  unit ->
  (Types.skill_descriptor, error_category) result

val invoke :
  runtime ->
  agent_id:string ->
  message:string ->
  ?cancellation_token:cancellation_token ->
  ?conversation:conversation ->
  ?on_tool_event:(event -> unit) ->
  ?on_chunk:(llm_response_chunk -> unit) option ->
  ?enable_handoff:bool ->
  unit ->
  (invoke_result, error_category * conversation) result

val invoke_structured :
  runtime ->
  agent_id:string ->
  message:string ->
  response_schema:Yojson.Safe.t ->
  ?max_repair_attempts:int ->
  ?cancellation_token:cancellation_token ->
  ?conversation:conversation ->
  ?on_tool_event:(event -> unit) ->
  ?on_repair_attempt:(int -> error_category -> conversation -> unit) ->
  unit ->
  (structured_invoke_result, error_category * conversation) result

val embed : runtime -> string list -> (float array list, error_category) result

val invoke_with_rag :
  runtime ->
  agent_id:string ->
  message:string ->
  ?k:int ->
  ?vector_store:Vector_store.t ->
  unit ->
  (invoke_result * Vector_store.document list, error_category) result

val submit_task :
  runtime ->
  ?priority:int ->
  ?timeout:float ->
  task_input ->
  Task_id.t

val get_task_status :
  runtime ->
  Task_id.t ->
  (task_status option, error_category) result

val cancel_task : runtime -> Task_id.t -> (unit, error_category) result

val approve_task : runtime -> Task_id.t -> approver:string -> (unit, error_category) result

val submit_workflow :
  runtime ->
  workflow ->
  (Workflow_run_id.t, error_category) result

val get_workflow_status :
  runtime ->
  Workflow_run_id.t ->
  (workflow_status, error_category) result

val cancel_workflow :
  runtime ->
  Workflow_run_id.t ->
  (unit, error_category) result

val register_workflow : runtime -> workflow -> (unit, error_category) result

val approve_workflow :
  runtime -> Workflow_run_id.t -> approver:string -> (unit, error_category) result

val resume_workflow :
  runtime -> Workflow_run_id.t -> (workflow_result option, error_category) result

val tool_registry : runtime -> Tool_registry.t

val bash_policy : runtime -> (module Bash_policy.POLICY)
(** The bash trust-boundary policy passed to [create], used by
    [install_bash_tool] to filter invocations. *)

val cancellation_root : runtime -> Eio.Switch.t
(** The root switch passed to [create]. Useful for spawning
    cancellation tokens in tests and external tools. *)

val mcp_servers : runtime -> (Mcp_types.server_id, Mcp_server.t) Types.protected_hashtbl

val mcp_server : runtime -> Mcp_types.server_id -> (Mcp_server.t, error_category) result

val publish_event : runtime -> event -> unit

val steer : runtime -> string -> unit

val follow_up : runtime -> string -> unit

val drain_steering : runtime -> string list

val drain_followup : runtime -> string list

val has_pending_steering : runtime -> bool

val has_pending_followup : runtime -> bool

val health : runtime -> Types.health_status

val metrics_snapshot : runtime -> (string * int) list

val record_llm_success : runtime -> unit

val record_llm_error : runtime -> error_category -> unit

val record_tool_invocation : runtime -> unit

val record_task_completed : runtime -> unit

val record_task_failed : runtime -> unit

val register_tool_call_hook : runtime -> Hook.tool_call_hook -> unit

val clear_tool_call_hooks : runtime -> unit

val run_tool_call_hooks : runtime -> Hook.tool_call_context -> Hook.chain_result
