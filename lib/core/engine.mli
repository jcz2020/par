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

(** [resolve_on_max_tokens ~effective_tools agent] returns the effective
    truncation policy. If [agent.on_max_tokens = None] (Auto), resolves to
    [Continue] for tool-less agents (per [effective_tools]) and
    [Return_partial] otherwise. An explicit [Some p] always wins. *)
val resolve_on_max_tokens :
  effective_tools:tool_descriptor list ->
  agent_config ->
  on_max_tokens_behavior

(** [resolve_max_continuation_chunks ~effective_tools agent] returns the
    effective Continue sub-loop chunk cap. If
    [agent.max_continuation_chunks = None] (Auto), resolves to [max_int]
    (effectively unbounded) for tool-less agents and [3] otherwise.
    An explicit [Some n] always wins. *)
val resolve_max_continuation_chunks :
  effective_tools:tool_descriptor list ->
  agent_config ->
  int

(** [build_breakpoint_candidates ~ttl ~tools ~conv] builds the list of
    breakpoint candidates from the current request state:
    - System message (priority 100)
    - Last tool definition (priority 50)
    - Last user message last block (priority 10)
    - Pre-marked tools with cache_control set (priority 60) *)
val build_breakpoint_candidates :
  ttl:cache_ttl ->
  tools:tool_descriptor list ->
  conv:conversation ->
  Cache_breakpoint.breakpoint list

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

val run_agent_structured :
  ?max_repair_attempts:int ->
  ?on_repair_attempt:(int -> error_category -> conversation -> unit) ->
  ?on_before_llm:(conversation -> conversation option) option ->
  ?on_after_llm:(llm_response -> llm_response option) option ->
  ?tool_call_hooks:Hook.tool_call_hook list option ->
  ?quota:Eio.Semaphore.t option ->
  ?parallel:bool ->
  ?on_progress:(string -> unit) option ->
  ?on_tool_event:(event -> unit) option ->
  ?conversation:conversation ->
  ?agent_resolver:(string -> agent_config option) ->
  ?enable_handoff:bool ->
  response_schema:Yojson.Safe.t ->
  llm_service ->
  cancellation_token ->
  agent_config ->
  string ->
  Tool_registry.t ->
  (structured_invoke_result, error_category * conversation) result
(** Two-phase structured output: runs the full ReAct loop with tools
    (Phase 1), then makes a separate structured LLM call using the
    complete conversation history (Phase 2). Use this when the agent
    has tools AND needs structured JSON output. *)

val run_agent :
  ?tool_mode:Types.tool_mode ->
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
(** Drive a single ReAct loop. The optional [?tool_mode] parameter
    (default [[ `Native]]) selects between the provider's native
    function-calling protocol and the synthesized fallback
    (PAR-k38 T3.1). When [` Synthesized], the engine injects tool
    descriptors into the system prompt via [Tool_prompt] and parses
    synthesised JSON tool calls out of the model's text response —
    the provider itself receives an empty tools list. *)
