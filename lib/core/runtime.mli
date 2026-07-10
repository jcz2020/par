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
  ?memory:memory_service ->
  ?bash_policy:(module Bash_policy.POLICY) ->
  ?workspace:Workspace.workspace ->
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
  ?fs:Eio.Fs.dir_ty Eio.Path.t ->
  runtime -> (unit, error_category) result
(** Idempotent: registers the bash tool with the runtime's configured policy.
    Returns Invalid_input if bash is already installed.
    Must be called after create, before any agent invocation that uses bash.
    A [process_mgr] is required for actual command execution; without it,
    the install registers a handler that will error when invoked.
    A [clock] is required for timeout enforcement; without it, commands
    that exceed [timeout] will run to completion.
    An [fs] (filesystem capability, typically [Eio.Stdenv.fs env]) is required
    so the spawned process can be launched with the cwd validated by
    [Workspace.admit]. Without it, commands would silently run in the parent
    process's cwd, defeating the workspace sandbox. *)

val per_call_registry :
  rt:runtime -> workspace:Workspace.workspace -> Tool_registry.t
(** Build a fresh tool registry for a single invocation where the bash handler
    closes over [workspace] (the effective workspace) rather than [rt.workspace].
    All caller-registered tools are copied as-is; then file tools are rebuilt via
    [rt.file_tools_rebuild] (if set) and the bash handler via [rt.bash_rebuild]
    (set by [install_bash_tool]) against [{ rt with workspace }].

    Used internally by [invoke]/[submit_workflow]/[submit_workflow_async] when
    the caller passes [?workspace]. Exposed for testing and advanced users who
    build their own dispatch path. *)

val register_file_tools_rebuild :
  runtime -> (Workspace.workspace -> (string * Tool_registry.handler_fn) list) -> unit
(** Register a closure that rebuilds the builtin file tools (read/ls/find/grep/
    write/edit) bound to a given workspace. Called by the entity that registers
    builtin tools (e.g. [bin/main.ml]) after [Builtin_tools.builtin_tools] is
    first registered, capturing the Eio switch + net. [per_call_registry] reads
    this so per-call [?workspace] override applies to file tools too. *)

val register_agent : runtime -> agent_config -> (unit, error_category) result

val list_agents : runtime -> agent_config list

val make_agent :
  id:string ->
  ?system_prompt:system_prompt ->
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
  ?on_max_tokens:on_max_tokens_behavior option ->
  ?max_continuation_chunks:int option ->
  ?tool_timeout:float option ->
  ?context_compression_threshold:float option ->
  ?compression_cooldown_messages:int option ->
  ?context_window_override:int option ->
  ?cache_strategy:cache_strategy ->
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
  ?cache_control:cache_control option ->
  unit ->
  (tool_binding, error_category) result

val register_tool_typed :
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
(** Typed-input convenience wrapper around [register_tool].

    [register_tool_typed] is intended for tools whose input schema is
    produced by a derivation (e.g. [ppx_deriving_jsonschema] and the
    [Jsonschema] strict-mode wrapper). It:

    - rejects any [input_schema] that is not a top-level JSON object
      (`` `Assoc _ ``), returning [Error (Internal "schema must be a
      JSON object")] — this satisfies the FFI guard the agent runtime
      applies to every tool input;
    - applies {!Jsonschema.to_strict_object_schema} to make the
      schema OpenAI-strict-compatible before passing it to
      [register_tool].

    The remaining arguments and return type are identical to
    [register_tool]. *)

(** {1 Dynamic Toolset API} *)

(** These three functions enable runtime mutation of agent toolsets
    without re-registering the whole [agent_config]. Changes propagate
    to in-flight [invoke] calls on their next hashtbl lookup. *)

val update_agent_tools :
  runtime ->
  agent_id:string ->
  add:Types.tool_binding list ->
  remove:string list ->
  (unit, error_category) result
(** Atomically add and/or remove tools on a registered agent.

    - [add] tools have their handlers upserted into the global tool
      registry (existing handlers are replaced, new ones registered)
      and their descriptors appended to the agent's [tools] list.
    - [remove] names are filtered out of the agent's [tools] list.
      The handlers stay in the global registry (other agents may
      reference them); call [unregister_tool] to remove a handler
      globally.
    - [remove] is applied before [add] within the same call, so
      passing the same name in both lets you replace a tool on a
      specific agent.

    Returns [Error (Invalid_input "Agent not found: ...")] if [agent_id]
    is not registered. *)

val unregister_tool :
  runtime ->
  name:string ->
  (unit, error_category) result
(** Remove a tool handler from the global registry.

    Agents that reference this tool keep their descriptor (now stale);
    the engine returns [Internal "Tool handler not registered: ..."]
    at invoke time. To clean up agents, call
    [update_agent_tools ~remove:[name]] per agent.

    Returns [Error (Invalid_input "Tool not registered: ...")] if no
    handler exists under [name]. *)

val replace_tool :
  runtime ->
  name:string ->
  descriptor:Types.tool_descriptor ->
  handler:Tool_registry.handler_fn ->
  (unit, error_category) result
(** Replace an existing tool's handler AND update its descriptor in
    every agent that references it.

    [name] and [descriptor.name] must match (no implicit rename).
    Every agent whose [tools] list contains a descriptor named [name]
    gets that descriptor replaced with the new one — so LLM-visible
    schema/description updates propagate alongside handler changes.

    Returns [Error] if [name <> descriptor.name], or if no handler
    exists under [name] (use [register_tool] for new tools). *)

(** {1 Skills} *)

val register_skill :
  runtime -> Types.skill_descriptor ->
  (Types.skill_binding, error_category) result

val list_skills : runtime -> Types.skill_descriptor list

val make_skill :
  id:string ->
  description:string ->
  ?system_prompt_override:skill_prompt_zone ->
  ?tool_filter:Types.tool_filter ->
  ?trigger:Types.skill_trigger ->
  ?expected_output:Yojson.Safe.t ->
  unit ->
  (Types.skill_descriptor, error_category) result

(** {1 Skill activation (internal)} *)

val compute_active_skill_effects :
  ?user_skills:string list -> runtime -> string -> Types.skill_effect list

val get_active_skill_ids :
  ?user_skills:string list -> runtime -> string -> string list

val compose_skill_effects : Types.skill_effect list -> Types.skill_effect

val apply_skill_effect_to_config :
  Types.skill_effect -> Types.agent_config -> Types.agent_config

(** {1 Agent invocation} *)

val invoke :
  runtime ->
  agent_id:string ->
  message:string ->
  ?workspace:Workspace.workspace ->
  ?cancellation_token:cancellation_token ->
  ?conversation:conversation ->
  ?on_tool_event:(event -> unit) ->
  ?on_chunk:(llm_response_chunk -> unit) option ->
  ?enable_handoff:bool ->
  ?system_prompt_appendix:string ->
  ?context:Invoke_context.invoke_context ->
  unit ->
  (invoke_result, error_category * conversation) result

(** [invoke_async rt ...] runs [invoke] in a background fiber and returns
    immediately with an [Invoke_context.invoke_handle]. Use the handle to
    [await], [cancel], or poll [status]. The fiber is forked under
    [rt.cancellation_root], mirroring [submit_workflow_async]. *)
val invoke_async :
  runtime ->
  agent_id:string ->
  message:string ->
  ?workspace:Workspace.workspace ->
  ?cancellation_token:cancellation_token ->
  ?conversation:conversation ->
  ?on_tool_event:(event -> unit) ->
  ?on_chunk:(llm_response_chunk -> unit) option ->
  ?enable_handoff:bool ->
  ?system_prompt_appendix:string ->
  ?context:Invoke_context.invoke_context ->
  unit ->
  Invoke_context.invoke_handle

(** Long-output pure generation API (plan §3.1.2).

    Use for: long text artifacts (PRDs, HTML mockups, plans, docs) where no
    tool calls are needed. Skips the ReAct loop entirely.

    Reuses: session store, event bus, LLM-service abstraction, skill/prompt
    management. Skips: ReAct iteration budget, per-iteration max_execution_time.

    @param agent_id resolves a registered agent (must have tools = [])
    @param message the prompt / user message
    @param max_output_tokens optional per-call cap; continuations accumulate beyond this
    @param total_timeout optional wall-clock cap on entire generation
    @param on_tool_event observation callback for events (Llm_request_sent,
           Llm_response_received, Llm_response_truncated, Generate_continuation)
    @param on_chunk optional streaming callback
*)
val invoke_generate :
  runtime ->
  agent_id:string ->
  message:string ->
  ?max_output_tokens:int ->
  ?total_timeout:float ->
  ?on_tool_event:(event -> unit) ->
  ?on_chunk:(llm_response_chunk -> unit) ->
  ?system_prompt_appendix:string ->
  unit ->
  (generate_result, error_category * conversation) result

val invoke_structured :
  runtime ->
  agent_id:string ->
  message:string ->
  response_schema:Yojson.Safe.t ->
  ?max_repair_attempts:int ->
  ?cancellation_token:cancellation_token ->
  ?conversation:conversation ->
  ?system_prompt_appendix:string ->
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
  ?workspace:Workspace.workspace ->
  ?inputs:(string * Yojson.Safe.t) list ->
  workflow ->
  (Workflow_run_id.t, error_category) result
(** Submit a workflow for execution, returning its run id immediately.
    [?inputs] are merged into (and override) [wf.def.variables] for this
    run only — the workflow definition itself is not mutated. Lets the
    same workflow definition be parameterized differently per run without
    callers having to copy-and-modify the record.

    SYNCHRONOUS: blocks the caller fiber until the workflow reaches a
    terminal state (Completed/Failed) or suspends at Human_approval.
    For long-running workflows prefer [submit_workflow_async]. *)

val submit_workflow_async :
  runtime ->
  ?workspace:Workspace.workspace ->
  ?inputs:(string * Yojson.Safe.t) list ->
  workflow ->
  (Workflow_run_id.t, error_category) result
(** Fire-and-forget variant of [submit_workflow]. Forks execution in a
    background fiber and returns the run id immediately. Track progress
    via [get_workflow_status] or subscribe to events on the runtime's
    event bus (Workflow_started/step_completed/completed/failed,
    Approval_requested). Suitable for long-running workflows where the
    caller cannot afford to block. *)

val invoke_workflow_sync :
  runtime ->
  ?workspace:Workspace.workspace ->
  ?inputs:(string * Yojson.Safe.t) list ->
  workflow ->
  (workflow_result option, error_category) result
(** Convenience wrapper: calls [submit_workflow] (sync, which blocks the
    caller fiber until terminal state or suspension) then maps the run id
    to the terminal result. Returns [Some result] on completion, [None]
    on suspension (Human_approval awaiting approve), [Error] on failure.
    Useful for tests and short workflows. For long-running workflows
    where blocking the caller is undesirable, use [submit_workflow_async]
    and track progress via events or [get_workflow_status]. *)

val get_workflow_status :
  runtime ->
  Workflow_run_id.t ->
  (workflow_status, error_category) result

val cancel_workflow :
  runtime ->
  Workflow_run_id.t ->
  (unit, error_category) result
(** Cancel a workflow run. Sets status to [Wf_failed (Internal "Cancelled")],
    persists the state change, and emits [Workflow_failed] event.
    Returns [Error (Invalid_input "Workflow not found")] if the run id
    is not registered. *)

val register_workflow : runtime -> workflow -> (unit, error_category) result

val approve_workflow :
  runtime -> Workflow_run_id.t -> approver:string -> (unit, error_category) result

val resume_workflow :
  runtime -> Workflow_run_id.t -> (workflow_result option, error_category) result

val tool_registry : runtime -> Tool_registry.t

val bash_policy : runtime -> (module Bash_policy.POLICY)
(** The bash trust-boundary policy passed to [create], used by
    [install_bash_tool] to filter invocations. *)

val workspace : runtime -> Workspace.workspace
(** The workspace (path-admission authority) created from CWD at
    [create] time. Used to thread path-admission into tools that
    need it (e.g. [Builtin_tools.builtin_tools]). *)

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

val cancel_stream_requested : runtime -> bool ref

val set_session_id : runtime -> string -> unit

val get_session_id : runtime -> string

val get_default_provider_id : runtime -> string option

val set_default_provider : runtime -> string -> (unit, error_category) result

val set_user_activated_skills : runtime -> string list -> unit
(** Manually activate skills by id, regardless of their trigger type.
    Adds the given ids to the active set; effects compose with auto-triggered
    skills (last-override-wins for system_prompt, intersection for tool_filter).
    Ids not present in the registry are silently ignored at activation time. *)

val clear_user_activated_skills : runtime -> unit
(** Clear the manual activation set. *)

val get_user_activated_skills : runtime -> string list
(** Current manually-activated skill ids. *)

val record_llm_success : runtime -> unit

val record_llm_error : runtime -> error_category -> unit

val record_tool_invocation : runtime -> unit

val record_task_completed : runtime -> unit

val record_task_failed : runtime -> unit

val register_tool_call_hook : runtime -> Hook.tool_call_hook -> unit

val clear_tool_call_hooks : runtime -> unit

val run_tool_call_hooks : runtime -> Hook.tool_call_context -> Hook.chain_result

val save_conversation : runtime -> (unit, error_category) result

val load_conversation : runtime -> string -> (Types.conversation option, error_category) result

val load_most_recent_conversation : runtime -> ((string * Types.conversation) option, error_category) result

val register_llm_provider : runtime -> string -> llm_service -> (unit, error_category) result
(** Add a provider under [id] to the runtime's provider registry. If [id]
    already exists, returns [`Duplicate_provider id] and the existing service
    is unchanged. The first registered provider becomes the default. *)

val list_llm_providers : runtime -> string list
(** Registered provider ids, sorted. *)

val get_llm_service : runtime -> ?id:string -> unit -> llm_service
(** Look up an LLM service by id. Defaults to the current default
    provider. Raises [Failure _] if [id] unknown or no default set. *)

val list_models : runtime -> ?id:string -> unit -> (string list, error_category) result
(** List available models from a provider. Defaults to the current default. *)

val set_fallback_policy : runtime -> Types.fallback_policy -> unit
(** Set the cross-provider fallback policy for [invoke]. Default: [No_fallback]. *)

val get_fallback_policy : runtime -> Types.fallback_policy
