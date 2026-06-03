open Types

type runtime

val default_event_bus_config : event_bus_config
val default_shutdown_config : shutdown_config
val default_quota : resource_quota

val create :
  ?persistence:persistence_service ->
  ?event_bus:(module EVENT_BUS_SERVICE) ->
  ?llm:llm_service ->
  config:runtime_config ->
  Eio.Switch.t ->
  (runtime, error_category) result

val close : runtime -> int

val register_agent : runtime -> agent_config -> (unit, error_category) result

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
  unit ->
  (agent_config, error_category) result

val register_tool :
  runtime ->
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  handler:(Yojson.Safe.t -> cancellation_token -> handler_result) ->
  ?permission:tool_permission ->
  ?timeout:float ->
  ?concurrency_limit:int ->
  unit ->
  (tool_binding, error_category) result

val invoke :
  runtime ->
  agent_id:string ->
  message:string ->
  ?cancellation_token:cancellation_token ->
  unit ->
  (llm_response, error_category) result

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

val steer : runtime -> string -> unit

val follow_up : runtime -> string -> unit

val drain_steering : runtime -> string list

val drain_followup : runtime -> string list

val has_pending_steering : runtime -> bool

val has_pending_followup : runtime -> bool
