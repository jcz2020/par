open Types

val apply_before_llm :
  middleware_hook list ->
  conversation ->
  (conversation -> llm_response Eio.Fiber.t) ->
  llm_response Eio.Fiber.t

val apply_after_llm :
  middleware_hook list ->
  llm_response ->
  (llm_response -> llm_response Eio.Fiber.t) ->
  llm_response Eio.Fiber.t

val apply_before_tool :
  middleware_hook list ->
  tool_call ->
  (tool_call -> handler_result Eio.Fiber.t) ->
  handler_result Eio.Fiber.t

val apply_after_tool :
  middleware_hook list ->
  tool_call * handler_result ->
  (tool_call * handler_result -> handler_result Eio.Fiber.t) ->
  handler_result Eio.Fiber.t

val apply_on_error :
  middleware_hook list ->
  error_category ->
  (error_category -> handler_result Eio.Fiber.t) ->
  handler_result Eio.Fiber.t

val execute_tool :
  cancellation_token ->
  tool_binding ->
  Yojson.Safe.t ->
  middleware_hook list ->
  handler_result Eio.Fiber.t

val run_agent :
  cancellation_token ->
  agent_config ->
  string ->
  (module LLM_SERVICE with type t = 'l) ->
  (llm_response, error_category) result Eio.Fiber.t
