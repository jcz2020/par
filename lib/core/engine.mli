open Types

val apply_before_llm :
  middleware_hook list ->
  conversation ->
  (conversation -> llm_response) ->
  llm_response

val apply_after_llm :
  middleware_hook list ->
  llm_response ->
  (llm_response -> llm_response) ->
  llm_response

val apply_before_tool :
  middleware_hook list ->
  tool_call ->
  (tool_call -> handler_result) ->
  handler_result

val apply_after_tool :
  middleware_hook list ->
  tool_call * handler_result ->
  (tool_call * handler_result -> handler_result) ->
  handler_result

val apply_on_error :
  middleware_hook list ->
  conversation ->
  error_category ->
  (error_category -> handler_result) ->
  handler_result

val execute_tool :
  cancellation_token ->
  tool_descriptor ->
  Tool_registry.handler_fn ->
  Yojson.Safe.t ->
  middleware_hook list ->
  (string -> unit) option ->
  handler_result

val run_agent :
  ?runtime_id:string ->
  ?steering:Steering_queue.t option ->
  ?followup:Steering_queue.t option ->
  ?tool_call_hooks:Hook.tool_call_hook list option ->
  ?quota:Eio.Semaphore.t option ->
  ?parallel:bool ->
  ?on_progress:(string -> unit) option ->
  ?on_tool_event:(event -> unit) option ->
  ?on_chunk:(llm_response_chunk -> unit) option ->
  ?conversation:conversation ->
  cancellation_token ->
  agent_config ->
  string ->
  llm_service ->
  Tool_registry.t ->
  (llm_response * conversation, error_category * conversation) result
