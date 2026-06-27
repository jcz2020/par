open Types

val apply_before_llm :
  middleware_hook list ->
  conversation ->
  (conversation -> 'a) ->
  'a

val apply_after_llm :
  middleware_hook list ->
  llm_response ->
  (llm_response -> 'a) ->
  'a

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
  tool_call_id:string ->
  tool_timeout:float option ->
  handler_result

val add_user_feedback :
  conversation -> string -> conversation

(** [run_structured ~response_schema llm token agent user_message] drives a
    schema-constrained LLM call with a repair-on-failure loop.

    - If [llm.complete_structured_fn = Some _], the native structured endpoint
      is used; otherwise a fallback prepends a JSON-schema directive to the
      system message and dispatches via [llm.complete_fn].
    - Each LLM response is parsed by [Json_extract.extract_json_from_text] and
      validated by [Validation.validate_tool_input_result].
    - On parse or schema failure, an assistant reply + user feedback message
      is appended to the conversation and the loop retries, up to
      [max_repair_attempts] times (default 3). The returned [conversation] on
      both [Ok] and [Error] contains every message produced, including repair
      turns, so callers can resume or audit.
    - BS-1 (ROADMAP Oracle fix): [Cancellation.is_cancelled token] is checked
      at the top of each iteration; if cancelled, returns
      [Error (Timeout, conv)] without making the next LLM call.
    - D2 (ROADMAP Oracle fix): [on_before_llm] and [on_after_llm] fire around
      every LLM call inside the loop, mirroring [run_agent]'s middleware
      contract for observability. They take and return [option] so a caller
      can pass [Some hook] or [None] to disable.
    - LLM/network errors (when [complete_fn] itself returns [Error]) are
      propagated immediately without repair — HTTP-level retry belongs to the
      existing Retry middleware; this loop only owns post-LLM parse/schema
      failures.
    - [on_repair_attempt] is an optional observation callback fired on each
      repair turn with the attempt number (1-based), the [error_category] of
      the failure, and the conversation up to that point. *)
val run_structured :
  ?max_repair_attempts:int ->
  ?on_before_llm:(conversation -> conversation option) option ->
  ?on_after_llm:(llm_response -> llm_response option) option ->
  ?on_repair_attempt:(int -> error_category -> conversation -> unit) ->
  ?conversation:conversation ->
  response_schema:Yojson.Safe.t ->
  llm_service ->
  cancellation_token ->
  agent_config ->
  string ->
  (structured_invoke_result, error_category * conversation) result

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
  ?agent_resolver:(string -> agent_config option) ->
  ?enable_handoff:bool ->
  cancellation_token ->
  agent_config ->
  string ->
  llm_service ->
  Tool_registry.t ->
  (llm_response * conversation, error_category * conversation) result
