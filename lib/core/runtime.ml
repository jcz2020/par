open Types

module Provider_registry = Provider_registry

type agent_dispatch_spec = {
  agent_id : string;
  input : string option;
  workspace : Workspace.workspace option;
  approval_handler : approval_context Approval.approval_handler option;
  blocking_approval : bool;  (* reserved for v0.8.1: true = block siblings until resolved *)
  conversation : conversation option;
  (* ^ Start this branch from an existing conversation. [None] creates a fresh
       one. The updated conversation is returned in [parallel_success]. *)
}

type parallel_success = {
  spec : agent_dispatch_spec;
  result : Yojson.Safe.t;
  conversation : conversation;
}

type parallel_invoke_result = {
  successes : parallel_success list;
  failures : (agent_dispatch_spec * error_category) list;
  merged : Yojson.Safe.t option;
}

let string_of_error_category (e : Types.error_category) = Types.string_of_error_category e

(* -------------------------------------------------------------------------- *)
(* SDK — Runtime                                                          *)
(* -------------------------------------------------------------------------- *)

type runtime = {
  agents : (string, agent_config) protected_hashtbl;
  services : service_registry;
  llm_providers : Provider_registry.t;
  cancellation_root : Eio.Switch.t;
  task_semaphore : Eio.Semaphore.t;
  shutdown_requested : bool ref;
  shutdown_mutex : Eio.Mutex.t;
  tasks : (Task_id.t, task_state) protected_hashtbl;
  workflows : (Workflow_run_id.t, workflow_status) protected_hashtbl;
  (* Runs found still [running] at startup. Recovery is only allowed for these:
     a [Wf_running] entry that this process created belongs to a live run, and
     recovering it would execute the workflow twice. *)
  orphaned_workflow_runs : (Workflow_run_id.t, unit) protected_hashtbl;
  (* Guards against two concurrent recoveries of the same run. *)
  recovering_workflow_runs : (Workflow_run_id.t, unit) protected_hashtbl;
  (* Durable invokes (PAR-mrr): ids rehydrated at startup as orphans, ids whose
     recovery is running now, and ids currently in flight in this process. The
     last one is what stops [recover_invoke] from double-running a live invoke,
     the same defect v0.14 fixed for workflows. *)
  orphaned_invokes : (string, string) protected_hashtbl;
  recovering_invokes : (string, unit) protected_hashtbl;
  (* Durable invokes this runtime owns, in the shared database. Another
     runtime must not recover a run that is still in flight. *)
  held_leases : (string, unit) protected_hashtbl;
  (* Invoke ids another runtime owns, read at startup: their rows are live,
     not leftovers. *)
  mutable held_by_others : string list;
  active_invokes : (string, unit) protected_hashtbl;
  persistence_is_noop : bool;
  workflow_defs : (string, workflow) protected_hashtbl;
  tool_registry : Tool_registry.t;
  mutable tool_description_overrides : (string * string) list;
  skills : Skill_registry.t;
  (* User-manually-activated skill ids. Composed with auto-triggered skills
     (last-override-wins for system_prompt, intersection for tool_filter).
     Only consulted for skills that exist in [skills]; missing ids are
     silently ignored. Manual-trigger skills are ONLY activatable via this
     list — they bypass the trigger filter in compute_active_skill_effects. *)
  mutable user_activated_skills : string list;
  steering_queue : Steering_queue.t;
  followup_queue : Steering_queue.t;
  runtime_id : string;
  parallel_tool_execution : bool;
  publish_event_fn : event -> unit;
  mutable last_llm_call_at : float option;
  mutable last_llm_call_status : [ `Success | `Error of error_category | `Never_called ];
  mutable metrics : Metrics.counters;
  mutable tool_call_hooks : Hook.tool_call_hook list;
  bash_policy : (module Bash_policy.POLICY);
  bash_installed : bool ref;
  (* v0.6.6: closure that builds a fresh bash handler bound to a given runtime's
     workspace. Set by [install_bash_tool] (captures the Eio process_mgr + clock
     supplied at install time). Read by [per_call_registry] to rebuild the bash
     handler against an effective workspace [rt' = { rt with workspace }] without
     needing access to the original mgr/clock args. [None] when bash is not
     installed. *)
  mutable bash_rebuild : (runtime -> Tool_registry.handler_fn) option;
  (* v0.6.6: rebuilds file tools (read/ls/find/grep/write/edit) bound to a given
     workspace. Set by the caller registering builtins (bin/main.ml) via
     [register_file_tools_rebuild]. [None] on runtimes without builtin file
     tools (e.g. Python FFI individual registration). *)
  mutable file_tools_rebuild : (Workspace.workspace -> (string * Tool_registry.handler_fn) list) option;
  mutable memory_rebuild : ((string * Tool_registry.handler_fn) list) option;
  workspace : Workspace.workspace;
  mcp_servers : (Mcp_types.server_id, Mcp_server.t) Types.protected_hashtbl;
  (* v0.12: tools exposed by the configured MCP servers, paired with the
     handler that calls the server. The descriptors are what an agent
     advertises to the model; the handlers are what the per-call registry
     resolves. Both come from this one list so they cannot disagree. *)
  mutable mcp_tools : (Types.tool_descriptor * Tool_registry.handler_fn) list;
  persistence_writer : Persistence_writer.t option;
  mutable default_provider_id : string option;
  cancel_stream_requested : bool ref;
  session_id : string option ref;
  mutable current_conversation : Types.conversation option;
  cc_mutex : Mutex.t;
  mutable fallback_policy : Types.fallback_policy;
  vector_store : Vector_store.t option;
  net : Obj.t option;
} [@@warning "-69"]

module Current_conversation : sig
  val get : runtime -> Types.conversation option
  val set : runtime -> Types.conversation option -> unit
  val update : runtime -> (Types.conversation option -> Types.conversation option) -> unit
end = struct
  let with_cc_mutex rt f =
    Mutex.lock rt.cc_mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock rt.cc_mutex) (fun () -> f ())
  let get rt = with_cc_mutex rt (fun () -> rt.current_conversation)
  let set rt v = with_cc_mutex rt (fun () -> rt.current_conversation <- v)
  let update rt f = with_cc_mutex rt (fun () -> rt.current_conversation <- f rt.current_conversation)
end [@@warning "-32"]

let default_event_bus_config = {
  buffer_capacity = 10000;
  delivery = {
    max_delivery_attempts = 5;
    initial_retry_delay = 1.0;
    retry_backoff = Exponential { base = 1.0; max_delay = 30.0 };
    delivery_timeout = 30.0;
  };
  dlq_enabled = true;
  dlq_max_size = 10;
  critical_event_types = [ "Shutdown_initiated"; "Shutdown_completed" ];
}

let default_shutdown_config = {
  drain_timeout = 30.0;
  cancel_grace_period = 5.0;
  flush_batch_size = 100;
}

let default_quota = {
  max_concurrent_tasks = 10;
  max_concurrent_tools_per_agent = 5;
  max_tokens_per_turn = None;
  max_total_tokens = None;
}

let default_bash_confirm = Types.default_bash_confirm_config

let make_agent ~id ?(system_prompt = stable_prompt "") ?(system_prompt_template = None)
    ~model ?(tools = []) ?(max_iterations = 1_000_000)
    ?(middleware = []) ?(retry_policy = None)
    ?(context_strategy = None)
    ?(resource_quota = None)
    ?(max_execution_time = None) ?(early_stopping_method = Force)
    ?(on_max_tokens = None) ?(max_continuation_chunks = None)
    ?(tool_timeout = None)
    ?(context_compression_threshold = Some 0.8)
    ?(compression_cooldown_messages = Some 6)
    ?(context_window_override = None)
    ?(cache_strategy = Types.No_caching)
    ?(approval_handler = None) () =
  let errors = ref [] in
  if String.length id = 0 then
    errors := "id must not be empty" :: !errors;
  if prompt_text system_prompt = "" && system_prompt_template = None then
    errors := "system_prompt must be non-empty or system_prompt_template must be provided" :: !errors;
  if max_iterations <= 0 then
    errors := (Printf.sprintf "max_iterations must be > 0 (got %d)" max_iterations) :: !errors;
  (match tool_timeout with
   | Some t when t <= 0.0 ->
     errors := (Printf.sprintf "tool_timeout must be > 0 (got %g)" t) :: !errors
   | _ -> ());
  let tool_names = Hashtbl.create (List.length tools) in
  List.iter (fun (td : Types.tool_descriptor) ->
    if String.length td.Types.name = 0 then
      errors := "tool name must not be empty" :: !errors
    else if Hashtbl.mem tool_names td.name then
      errors := (Printf.sprintf "duplicate tool name: %s" td.name) :: !errors
    else
      Hashtbl.add tool_names td.name ()
  ) tools;
  (* B.4 construction-time check: cache_strategy requires Zone_stable system_prompt.
     v0.6.5: hard fail — return Error. *)
  (match cache_strategy, zone_of system_prompt with
   | Types.With_cache_of _, Zone_volatile ->
     errors := "cache_strategy=With_cache_of requires Zone_stable system_prompt, but got Zone_volatile" :: !errors
   | _ -> ());
  match !errors with
  | [] -> Ok {
      id; system_prompt; system_prompt_template; model; tools;
      max_iterations; middleware; retry_policy; context_strategy; resource_quota;
      max_execution_time; early_stopping_method;
      on_max_tokens; max_continuation_chunks;
      tool_timeout;
      context_compression_threshold;
      compression_cooldown_messages;
      context_window_override; cache_strategy;
      approval_handler;
    }
  | errs -> Result.Error (Types.Invalid_input (String.concat "; " errs))

let register_agent rt (agent : agent_config) =
  let validated = make_agent
    ~id:agent.id
    ?system_prompt:(Some agent.system_prompt)
    ?system_prompt_template:(Some agent.system_prompt_template)
    ~model:agent.model
    ?tools:(Some agent.tools)
    ?max_iterations:(Some agent.max_iterations)
    ?middleware:(Some agent.middleware)
    ?retry_policy:(Some agent.retry_policy)
    ?context_strategy:(Some agent.context_strategy)
    ?resource_quota:(Some agent.resource_quota)
    ?max_execution_time:(Some agent.max_execution_time)
    ?early_stopping_method:(Some agent.early_stopping_method)
    ?on_max_tokens:(Some agent.on_max_tokens)
    ?max_continuation_chunks:(Some agent.max_continuation_chunks)
    ?tool_timeout:(Some agent.tool_timeout)
    ?context_compression_threshold:(Some agent.context_compression_threshold)
    ?compression_cooldown_messages:(Some agent.compression_cooldown_messages)
    ?context_window_override:(Some agent.context_window_override)
    ?cache_strategy:(Some agent.cache_strategy)
    ?approval_handler:(Some agent.approval_handler)
    () in
  match validated with
  | Ok valid_agent ->
    htbl_set rt.agents valid_agent.id valid_agent;
    Ok ()
  | Result.Error e -> Result.Error e

let list_agents rt =
  let acc = ref [] in
  htbl_iter rt.agents (fun _ agent -> acc := agent :: !acc);
  List.rev !acc

let register_tool rt ~name ~description ~input_schema ~handler
    ?output_schema ?(permission = Allow) ?timeout ?concurrency_limit
    ?(on_update = None) ?(cache_control = None)
    ?(layer = Tool_registry.Always) () =
  let descriptor = { Types.name; description; input_schema; output_schema; permission; timeout; concurrency_limit; on_update; cache_control } in
  let result = match layer with
    | Tool_registry.Searchable -> Tool_registry.register_searchable rt.tool_registry descriptor handler
    | Tool_registry.Always -> Tool_registry.register rt.tool_registry descriptor handler
  in
  match result with
  | Error (`Duplicate_tool n) ->
    Result.Error (Types.Invalid_input (Printf.sprintf "Tool already registered: %s" n))
  | Ok () ->
    Ok { descriptor; handler }

let register_tool_typed rt ~name ~description ~input_schema ~handler
    ?output_schema ?(permission = Allow) ?timeout ?concurrency_limit
    ?(on_update = None) ?layer () =
  match input_schema with
  | `Assoc _ ->
    let wrapped = Jsonschema.to_strict_object_schema input_schema in
    register_tool rt ~name ~description ~input_schema:wrapped ~handler
      ?output_schema ~permission ?timeout ?concurrency_limit ~on_update ?layer ()
  | _ ->
    Result.Error
      (Types.Internal "schema must be a JSON object")

let set_tool_layer rt ~name ~layer =
  match Tool_registry.resolve rt.tool_registry name with
  | None -> Result.Error (Types.Invalid_input (Printf.sprintf "Tool not registered: %s" name))
  | Some _ ->
    Tool_registry.set_layer rt.tool_registry name layer;
    Ok ()

(* ─── Dynamic toolset API ──────────────────────────────────────────────
   These three functions enable runtime mutation of agent toolsets
   without re-registering the whole agent_config. Backed by the same
   protected_hashtbl + tool_registry the register_* APIs use, so changes
   propagate to in-flight invoke calls on their next hashtbl lookup. *)

let register_or_replace_tool_handler rt (descriptor : Types.tool_descriptor) handler =
  if Tool_registry.resolve rt.tool_registry descriptor.name |> Option.is_some then
    Tool_registry.replace rt.tool_registry descriptor.name handler
  else
    (match Tool_registry.register rt.tool_registry descriptor handler with
     | Ok () -> ()
     | Error _ -> ())

let update_agent_tools rt ~agent_id ~add:(additions : Types.tool_binding list) ~remove =
  match htbl_get rt.agents agent_id with
  | None ->
    Result.Error (Types.Invalid_input (Printf.sprintf "Agent not found: %s" agent_id))
  | Some agent ->
    let kept =
      List.filter (fun (d : Types.tool_descriptor) ->
        not (List.mem d.name remove)) agent.tools
    in
    let new_descriptors = List.map (fun (b : Types.tool_binding) -> b.descriptor) additions in
    let final_tools = kept @ new_descriptors in
    List.iter (fun (b : Types.tool_binding) ->
      register_or_replace_tool_handler rt b.descriptor b.handler) additions;
    htbl_set rt.agents agent_id { agent with tools = final_tools };
    Ok ()

let unregister_tool rt ~name =
   match Tool_registry.unregister rt.tool_registry name with
  | Ok () -> Ok ()
  | Error (`Tool_not_found n) ->
    Result.Error (Types.Invalid_input (Printf.sprintf "Tool not registered: %s" n))

let set_tool_description_overrides rt (overrides : (string * string) list) =
  rt.tool_description_overrides <- overrides

let replace_tool rt ~name ~(descriptor : Types.tool_descriptor) ~handler =
  (* name and descriptor.name must match — disallow implicit rename
     (registry stays keyed by `name`; agent.walk depends on descriptor.name
     matching). Caller must use unregister_tool + register_tool to rename. *)
  if name <> descriptor.name then
    Result.Error (Types.Invalid_input
      (Printf.sprintf "name (%s) and descriptor.name (%s) must match" name descriptor.name))
  else if Tool_registry.resolve rt.tool_registry name |> Option.is_none then
    Result.Error (Types.Invalid_input
      (Printf.sprintf "Tool not registered: %s (call register_tool first)" name))
  else begin
    Tool_registry.replace rt.tool_registry name handler;
    (* Walk all agents; collect those needing descriptor update, apply
       outside the iter to avoid holding the read lock while taking
       the write lock (would deadlock on Eio.Mutex.use_ro/use_rw). *)
    let to_update = ref [] in
    htbl_iter rt.agents (fun id agent ->
      if List.exists (fun (d : Types.tool_descriptor) -> d.name = name) agent.tools then
        to_update := (id, agent) :: !to_update);
    List.iter (fun (id, agent) ->
      let new_tools = List.map (fun (d : Types.tool_descriptor) ->
        if d.name = name then descriptor else d) agent.tools in
      htbl_set rt.agents id { agent with tools = new_tools })
      !to_update;
    Ok ()
  end


let register_skill rt (descriptor : Types.skill_descriptor) =
  let activate : Skill_registry.activate_fn =
    fun () ->
      { Types.system_prompt_override = descriptor.Types.system_prompt_override;
        tool_filter_overlay = descriptor.Types.tool_filter }
  in
  let binding = { Types.descriptor; activate } in
  match Skill_registry.register rt.skills binding with
  | Error (`Duplicate_skill id) ->
    Result.Error (Types.Invalid_input (Printf.sprintf "Skill already registered: %s" id))
  | Ok () -> Ok binding

let list_skills rt = Skill_registry.list_descriptors rt.skills

let make_skill ~id ~description ?(system_prompt_override : Types.skill_prompt_zone option) ?(tool_filter = Types.All_tools)
    ?(trigger = Types.Auto) ?expected_output () =
  if id = "" then Result.Error (Types.Invalid_input "skill id cannot be empty")
  else if String.length description > 1024 then
    Result.Error (Types.Invalid_input
      (Printf.sprintf "description exceeds 1024 chars (%d)" (String.length description)))
  else
    Result.Ok {
      Types.schema_version = 1;
      id;
      name = id;
      description;
      system_prompt_override;
      tool_filter;
      trigger;
      expected_output;
      body_path = "";
    }

type skill_effect_alias = skill_effect = {
  system_prompt_override : skill_prompt_zone option;
  tool_filter_overlay : tool_filter;
}

let contains_substring (s : string) (needle : string) : bool =
  let s_len = String.length s in
  let n_len = String.length needle in
  if n_len = 0 then true
  else if n_len > s_len then false
  else
    let rec search i =
      if i + n_len > s_len then false
      else if String.sub s i n_len = needle then true
      else search (i + 1)
    in search 0

let compute_active_skill_effects ?user_skills (rt : runtime) (message : string) : skill_effect list =
  let user_skills = Option.value user_skills ~default:rt.user_activated_skills in
  let descriptors = Skill_registry.list_descriptors rt.skills in
  let auto_effects =
    List.filter_map (fun (desc : skill_descriptor) ->
      let eligible = match desc.trigger with
        | Auto -> true
        | Manual -> false
        | Keyword { keywords; _ } ->
        List.exists (fun kw -> contains_substring message kw) keywords
      in
      if eligible then
        match Skill_registry.resolve rt.skills desc.id, desc.trigger with
        | Some activate, Auto ->
          let e = activate () in
          Some ({ system_prompt_override = None;
                  tool_filter_overlay = e.tool_filter_overlay } : skill_effect)
        | Some activate, _ -> Some (activate ())
        | None, _ -> None
      else None)
      descriptors
  in
  let user_effects =
    List.filter_map (fun id ->
      if List.mem id user_skills then
        match Skill_registry.resolve rt.skills id with
        | Some activate -> Some (activate ())
        | None -> None
      else None)
      (List.map (fun (d : skill_descriptor) -> d.id) descriptors)
  in
  auto_effects @ user_effects

let get_active_skill_ids ?user_skills (rt : runtime) (message : string) : string list =
  let user_skills = Option.value user_skills ~default:rt.user_activated_skills in
  let descriptors = Skill_registry.list_descriptors rt.skills in
  let auto_ids =
    List.filter_map (fun (desc : skill_descriptor) ->
      let eligible = match desc.trigger with
        | Auto -> true
        | Manual -> false
        | Keyword { keywords; _ } ->
          List.exists (fun kw -> contains_substring message kw) keywords
      in
      if eligible then
        match Skill_registry.resolve rt.skills desc.id with
        | Some _ -> Some desc.id
        | None -> None
      else None)
      descriptors
  in
  let user_ids =
    List.filter_map (fun id ->
      if List.mem id user_skills then
        match Skill_registry.resolve rt.skills id with
        | Some _ -> Some id
        | None -> None
      else None)
      (List.map (fun (d : skill_descriptor) -> d.id) descriptors)
  in
  auto_ids @ user_ids

let compose_skill_effects (effects : skill_effect list) : skill_effect =
  match effects with
  | [] -> { system_prompt_override = None; tool_filter_overlay = All_tools }
  | [single] -> single
  | _ ->
    let spo =
      List.fold_left (fun _ e ->
        let (se : skill_effect_alias) = e in
        se.system_prompt_override)
        None effects
    in
    let tfo =
      List.fold_left (fun acc e ->
        match acc, e.tool_filter_overlay with
        | All_tools, x -> x
        | x, All_tools -> x
        | Only a, Only b ->
          Only (List.filter (fun x -> List.mem x b) a)
        | Only a, Except b ->
          Only (List.filter (fun x -> not (List.mem x b)) a)
        | Except a, Only b ->
          Only (List.filter (fun x -> not (List.mem x a)) b)
        | Except a, Except b ->
          Except (a @ b))
        All_tools effects
    in
    { system_prompt_override = spo; tool_filter_overlay = tfo }

let apply_skill_effect_to_config (eff : skill_effect) config =
  let config = match eff.system_prompt_override with
  | Some (Stable_prompt s) -> { config with system_prompt = stable_prompt s }
  | Some (Volatile_prompt s) -> { config with system_prompt = volatile_prompt s }
  | Some (Both_prompts { stable; volatile }) ->
    { config with system_prompt = volatile_prompt (stable ^ "\n" ^ volatile) }
  | None -> config
  in
  match eff.tool_filter_overlay with
  | All_tools -> config
  | Only allowed ->
    { config with tools = List.filter
        (fun (t : tool_descriptor) -> List.mem t.name allowed)
        config.tools }
  | Except blocked ->
    { config with tools = List.filter
        (fun (t : tool_descriptor) -> not (List.mem t.name blocked))
        config.tools }


let record_llm_success rt =
  rt.last_llm_call_at <- Some (Unix.gettimeofday ());
  rt.last_llm_call_status <- `Success;
  match Invoke_context.get_current () with
  | Some ctx -> Metrics.incr_llm ctx.metrics_accumulator
  | None -> Metrics.incr_llm rt.metrics

let record_llm_error rt err =
  rt.last_llm_call_at <- Some (Unix.gettimeofday ());
  rt.last_llm_call_status <- `Error err;
  match Invoke_context.get_current () with
  | Some ctx -> Metrics.incr_llm ctx.metrics_accumulator
  | None -> Metrics.incr_llm rt.metrics

let record_tool_invocation rt =
  match Invoke_context.get_current () with
  | Some ctx -> Metrics.incr_tool_invocations ctx.metrics_accumulator
  | None -> Metrics.incr_tool_invocations rt.metrics

let record_task_completed rt =
  Metrics.incr_task_completed rt.metrics

let record_task_failed rt =
  Metrics.incr_task_failed rt.metrics

let publish_event rt evt =
  rt.publish_event_fn evt

(* The policy filters the environment it is given; it cannot read the process
   environment itself. Seeding [Exec.env] with the current environment is what
   makes [Bash_policy.sanitize_env] mean anything — without it the policy sees
   an empty list and the child inherits everything. *)
let current_env_pairs () =
  Array.to_list (Unix.environment ())
  |> List.filter_map (fun entry ->
      match String.index_opt entry '=' with
      | None | Some 0 -> None
      | Some i ->
        Some (String.sub entry 0 i,
              String.sub entry (i + 1) (String.length entry - i - 1)))

let make_bash_handler rt mgr clock fs input tok : Types.handler_result =
  let module P = (val rt.bash_policy : Bash_policy.POLICY) in
  let argv =
    let raw =
      try Yojson.Safe.Util.(input |> member "argv" |> to_list)
      with _ -> []
    in
    List.filter_map
      (fun j -> match j with `String s -> Some s | _ -> None) raw
  in
  let cwd_str =
    match Yojson.Safe.Util.(input |> member "cwd" |> to_string_option) with
    | Some s -> s
    | None -> "."
  in
  let timeout =
    let t = Yojson.Safe.Util.(input |> member "timeout" |> to_float_option) in
    (* Clamped: the tool description promises a hard cap, and a model asking
       for an unbounded run is exactly the case the cap exists for. *)
    match t with
    | Some x when x > 0.0 -> Bash_policy.clamp_timeout x
    | _ -> 30.0
  in
  (match Bash_safe_command.validate_argv argv with
   | Error e ->
     let argv_summary = String.concat " " argv in
     let msg = Tool_error.instructive
       ~marker:Tool_error.bash_policy_marker
       ~why:(Printf.sprintf "Invalid argv: %s."
               (match e with Types.Invalid_input s -> s | _ -> "validation error"))
       ~remedy:(Printf.sprintf "Provide argv as a plain string array \
                  (e.g. [\"ls\"; \"-la\"]) without NUL bytes, ≤4096 entries. \
                  argv was: %s" argv_summary) in
     Error { category = e; message = msg;
             retryable = false;
             metadata = [("code", `String "bash_argv_invalid")] }
   | Ok () ->
   (match Workspace.admit rt.workspace cwd_str with
      | Error e ->
        let num_roots = List.length rt.workspace.Workspace.roots in
        let (msg, code) = Tool_error.workspace_rejection_message
          ~path:cwd_str ~num_roots e in
        Error { category = e; message = msg;
                retryable = false; metadata = [("code", `String code)] }
      | Ok cwd ->
        let cmd : Bash_safe_command.command =
          Bash_safe_command.Exec { argv; cwd; env = current_env_pairs (); timeout }
        in
        (match P.filter cmd with
         | Error e ->
           let cmd_str = String.concat " " argv in
           let msg = Tool_error.instructive
             ~marker:Tool_error.bash_policy_marker
             ~why:(Printf.sprintf "Command rejected by %s policy: %s."
                     P.name cmd_str)
             ~remedy:"This policy forbids that command; check the allowed operations \
                        for this session or use the file tools for writes." in
           Error { category = e; message = msg;
                   retryable = false;
                   metadata = [("code", `String "bash_policy_rejected")] }
         | Ok filtered ->
           let task_id = Task_id.create () in
           let start_t = Unix.gettimeofday () in
           let argv_for_event = Bash_safe_command.argv_of_command filtered in
           let cwd_for_event = Workspace.to_string cwd in
           let risk_str =
             Bash_safe_command.risk_to_string
               (Bash_safe_command.assess_risk filtered)
           in
           publish_event rt
             (Bash_invoked {
               task_id; tool_name = "bash";
               argv = argv_for_event;
               cwd = cwd_for_event;
               timeout;
               risk = risk_str;
               started_at = start_t;
             });
            let proc_result =
            match Capability.detect () `Process_spawning with
            | `Unavailable reason ->
              Result.Error (`Capability_unavailable reason)
            | `Available ->
              Eio.Fiber.first
                (fun () ->
                  let stdout_buf = Buffer.create 1024 in
                  let stderr_buf = Buffer.create 1024 in
                   let proc_argv =
                     Bash_safe_command.argv_of_command filtered
                   in
                  let cwd_eio = Eio.Path.(fs / Workspace.to_string cwd) in
                  Eio.Switch.check tok.switch;
                  (* await waits only for child exit. The local switch also
                     waits for stdout/stderr copy fibers before we read them. *)
                  (* The policy has already removed secret variables; handing
                     the result to the spawn is what keeps them out of the
                     child. Inheriting the parent environment here exposed every
                     API key to a plain [printenv]. *)
                  let child_env =
                    Array.of_list
                      (List.map (fun (k, v) -> k ^ "=" ^ v)
                         (Bash_safe_command.env_of_command filtered))
                  in
                  let status = Eio.Switch.run (fun sw ->
                    let proc = Eio.Process.spawn ~sw mgr
                      ~cwd:cwd_eio
                      ~env:child_env
                      ~stdin:(Eio.Flow.string_source "")
                      ~stdout:(Eio.Flow.buffer_sink stdout_buf)
                      ~stderr:(Eio.Flow.buffer_sink stderr_buf)
                      proc_argv in
                    Eio.Process.await proc)
                  in
                 let code = match status with
                   | `Exited n -> n
                   | `Signaled _ -> 128
                 in
                 Ok (Buffer.contents stdout_buf,
                     Buffer.contents stderr_buf,
                     code))
               (fun () ->
                 (match clock with
                  | Some c -> Eio.Time.sleep c timeout
                  | (* Without a clock there is nothing to wait on. Returning
                       immediately reported every command as a timeout. *)
                    None -> Eio.Fiber.await_cancel ());
                 Result.Error `Timeout)
           in
           (match proc_result with
            | Ok (stdout, stderr, exit_code) ->
              let duration = Unix.gettimeofday () -. start_t in
              let clean_stdout = Bash_policy.strip_ansi stdout in
              let clean_stderr = Bash_policy.strip_ansi stderr in
              let trunc_stdout, was_trunc1 =
                Bash_policy.truncate_output ~max_bytes:51200
                  ~max_lines:2000 clean_stdout
              in
              let trunc_stderr, was_trunc2 =
                Bash_policy.truncate_output ~max_bytes:51200
                  ~max_lines:2000 clean_stderr
              in
              let truncated = was_trunc1 || was_trunc2 in
              publish_event rt
                (Bash_completed {
                  task_id; tool_name = "bash";
                  argv = argv_for_event;
                  exit_code;
                  duration;
                  stdout_truncated = was_trunc1;
                  stderr_truncated = was_trunc2;
                });
              let output =
                `Assoc [
                  ("stdout", `String trunc_stdout);
                  ("stderr", `String trunc_stderr);
                  ("exit_code", `Int exit_code);
                  ("duration", `Float duration);
                  ("truncated", `Bool truncated);
                ]
              in
              Success output
            | Result.Error `Timeout ->
              let duration = Unix.gettimeofday () -. start_t in
              publish_event rt
                (Bash_completed {
                  task_id; tool_name = "bash";
                  argv = argv_for_event;
                  exit_code = 124;
                  duration;
                  stdout_truncated = false;
                  stderr_truncated = false;
                });
              Error { category = Timeout;
                      message = Printf.sprintf
                        "bash timed out after %.1fs" timeout;
                      retryable = false; metadata = [] }
            | Result.Error (`Capability_unavailable reason) ->
              Error { category = Internal reason;
                      message = Printf.sprintf
                        "bash tool unavailable: %s" reason;
                      retryable = false; metadata = [] }
            | exception exn ->
              let msg = Printexc.to_string exn in
              Error { category = Internal msg;
                      message = "bash execution failed";
                      retryable = false; metadata = [] }))))

let install_bash_tool ?process_mgr ?clock ?fs rt =
  if !(rt.bash_installed) then
    Result.Error (Types.Invalid_input "bash tool already installed")
  else
    match process_mgr with
    | None ->
      Result.Error (Types.Invalid_input
        "install_bash_tool requires ?process_mgr:\
         pass (Eio.Stdenv.process_mgr env) from the Eio environment")
    | Some mgr ->
      (match fs with
       | None ->
         Result.Error (Types.Invalid_input
           "install_bash_tool requires ?fs:\
            pass (Eio.Stdenv.fs env) from the Eio environment")
       | Some fs_dir ->
         let builder rt_inner = make_bash_handler rt_inner mgr clock fs_dir in
         rt.bash_rebuild <- Some builder;
         let descriptor = Builtin_tools.bash_tool_descriptor in
         Tool_registry.replace rt.tool_registry descriptor.name (builder rt);
         rt.bash_installed := true;
         Ok ())

let per_call_registry ~(rt : runtime) ~(workspace : Workspace.workspace) : Tool_registry.t =
  let fresh = Tool_registry.create () in
  Tool_registry.copy_all ~src:rt.tool_registry ~dst:fresh;
  (match rt.file_tools_rebuild with
   | Some rebuild ->
     List.iter (fun (name, handler) -> Tool_registry.replace fresh name handler)
       (rebuild workspace)
   | None -> ());
  let rt' = { rt with workspace } in
  (match rt.bash_rebuild with
   | Some rebuild -> Tool_registry.replace fresh "bash" (rebuild rt')
   | None -> ());
  (match rt.memory_rebuild with
   | Some tools ->
     List.iter (fun (name, handler) -> Tool_registry.replace fresh name handler) tools
   | None -> ());
  (match rt.services.config.max_tool_schema_tokens with
   | Some _ ->
     let handler = Tool_search.make_handler fresh in
     ignore (Tool_registry.register_searchable fresh Tool_search.descriptor handler)
   | None -> ());
  (* MCP server tools are additive: they fill names that no explicitly
     registered tool claims. An explicitly registered tool always wins, so a
     server that happens to use a common name cannot displace it. *)
  List.iter
    (fun ((mcp_descriptor : Types.tool_descriptor), handler) ->
      if not (List.mem mcp_descriptor.Types.name (Tool_registry.names fresh)) then
        ignore (Tool_registry.register fresh mcp_descriptor handler))
    rt.mcp_tools;
  fresh

(** The tools exposed by the MCP servers configured on this runtime.
    Pass the ones an agent should advertise to {!make_agent}; the handlers are
    already in every per-call registry. Names are the server's own, so a name
    an explicitly registered tool already uses is skipped by the registry. *)
let mcp_tool_descriptors rt = List.map fst rt.mcp_tools

let register_file_tools_rebuild rt rebuild =
  rt.file_tools_rebuild <- Some rebuild

let register_agent_as_tool rt ~agent_id ?(tool_name = "agent_" ^ agent_id) ?description
    ?(max_depth = 3) ?(inherit_cancellation = true) () =
  match htbl_get rt.agents agent_id with
  | None ->
    Result.Error (Invalid_input
      (Printf.sprintf "Agent not found: %s" agent_id))
  | Some child_agent ->
    let desc = match description with
      | Some d -> d
      | None -> Printf.sprintf "Invoke agent '%s' as a tool" agent_id
    in
    let handler (input : Yojson.Safe.t) (token : cancellation_token) =
      let message =
        match Yojson.Safe.Util.member "message" input with
        | `String s -> s
        | `Null ->
          (match input with
           | `String s -> s
           | _ -> Yojson.Safe.to_string input)
        | other -> Yojson.Safe.to_string other
      in
      let parent_depth = match Invoke_context.get_current () with
        | Some ctx -> ctx.depth
        | None -> 0
      in
      if parent_depth >= max_depth then begin
        let msg = Tool_error.instructive
          ~marker:Tool_error.agent_tool_marker
          ~why:(Printf.sprintf "Maximum agent nesting depth (%d) reached." max_depth)
          ~remedy:(Printf.sprintf
            "The agent '%s' cannot be invoked at depth %d. \
             Increase max_depth or restructure to reduce nesting."
            agent_id parent_depth) in
        Error { category = Invalid_input msg;
                message = msg; retryable = false; metadata = [] }
      end else if inherit_cancellation && Cancellation.is_cancelled token then
        Error { category = Cancelled User_cancelled;
                message = "Parent invocation cancelled"; retryable = false;
                metadata = [] }
      else begin
        let start_t = Unix.gettimeofday () in
        let child_session_id =
          Printf.sprintf "agent-tool-%s-%s" agent_id
            (Session_id.to_string (Session_id.create ()))
        in
        let child_metrics = Metrics.empty () in
        let parent_hooks = match Invoke_context.get_current () with
          | Some ctx -> ctx.tool_call_hooks_snapshot
          | None -> []
        in
        let child_ctx = Invoke_context.create
          ~session_id:child_session_id
          ~metrics:child_metrics
          ~hooks:parent_hooks
          ~skills:[]
          ~depth:(parent_depth + 1)
          () in
        let child_token = Cancellation.create_token token.switch in
        let child_registry = per_call_registry ~rt ~workspace:rt.workspace in
        let usage_ref = ref {
          prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
          cached_tokens = 0; cache_creation_input_tokens = 0;
          cache_read_input_tokens = 0;
        } in
        let child_llm = rt.services.llm in
        let wrapped_complete_fn model_config tools conv =
          match child_llm.complete_fn model_config tools conv with
          | Ok resp ->
            let u = resp.usage in
            usage_ref := {
              prompt_tokens = !usage_ref.prompt_tokens + u.prompt_tokens;
              completion_tokens = !usage_ref.completion_tokens + u.completion_tokens;
              total_tokens = !usage_ref.total_tokens + u.total_tokens;
              cached_tokens = !usage_ref.cached_tokens + u.cached_tokens;
              cache_creation_input_tokens = !usage_ref.cache_creation_input_tokens + u.cache_creation_input_tokens;
              cache_read_input_tokens = !usage_ref.cache_read_input_tokens + u.cache_read_input_tokens;
            };
            Ok resp
          | Error e -> Error e
        in
        let child_llm_service : llm_service = {
          complete_fn = wrapped_complete_fn;
          stream_fn = child_llm.stream_fn;
          close_fn = child_llm.close_fn;
          complete_structured_fn = child_llm.complete_structured_fn;
          list_models_fn = child_llm.list_models_fn;
          supports_native_tools_fn = child_llm.supports_native_tools_fn;
          context_window_fn = child_llm.context_window_fn;
          cache_control_fn = child_llm.cache_control_fn;
        } in
        let child_system_prompt =
          prompt_text child_agent.system_prompt
        in
        let child_conv : conversation = {
          messages = [
            { role = System;
              content_blocks = [Text_block { text = child_system_prompt; cache_control = None }];
              tool_calls = None; tool_call_id = None; name = None;
              };
            { role = User;
              content_blocks = [Text_block { text = message; cache_control = None }];
              tool_calls = None; tool_call_id = None; name = None;
              };
          ];
          metadata = [];
        } in
        let iterations_ref = ref 0 in
        let on_progress_counter _msg = incr iterations_ref in
        let run_child () =
          Invoke_context.with_context child_ctx (fun () ->
            Engine.run_agent
              ~quota:None
              ~parallel:rt.parallel_tool_execution
              ~on_progress:(Some on_progress_counter)
              ~on_tool_event:None
              ~conversation:child_conv
              ~enable_handoff:false
              ?net:(Option.map (fun n -> (Obj.obj n : _ Eio.Net.t)) rt.net)
              ?budget_threshold:rt.services.config.max_tool_schema_tokens
              child_token child_agent message child_llm_service child_registry)
        in
        let child_result =
          try Ok (run_child ())
          with Engine.Approval_pending _ ->
            Error `Approval_pending
        in
        match child_result with
        | Error `Approval_pending ->
          let msg = Tool_error.instructive
            ~marker:Tool_error.agent_tool_marker
            ~why:(Printf.sprintf
              "Agent '%s' requires approval, but nested agents \
               cannot suspend for approval." agent_id)
            ~remedy:"Nested agent tools run synchronously and cannot \
                     pause for HITL approval. Remove approval-requiring \
                     tools from the child agent or handle approval \
                     at the parent level." in
          Error { category = Invalid_input msg;
                  message = msg; retryable = false; metadata = [] }
        | Ok (Ok (resp, _conv)) ->
          let duration = Unix.gettimeofday () -. start_t in
          let iterations = !iterations_ref in
          let evt = Agent_tool_completed {
            tool_name; child_agent_id = agent_id;
            iterations; duration_s = duration; usage = !usage_ref;
          } in
          publish_event rt evt;
          let parent_on_tool_event = match Invoke_context.get_current () with
            | Some ctx -> ctx.on_tool_event
            | None -> None
          in
          (match parent_on_tool_event with
           | Some cb -> cb evt
           | None -> ());
          let result_json = `Assoc [
            ("result", `String (Option.value resp.text ~default:""));
            ("usage", usage_stats_to_yojson !usage_ref);
          ] in
          Success result_json
        | Ok (Error (Cancelled r, _conv)) ->
          Error { category = Cancelled r;
                  message = "Child agent cancelled"; retryable = false;
                  metadata = [] }
        | Ok (Error (err, _conv)) ->
          Error { category = err;
                  message = Printf.sprintf "Child agent '%s' failed" agent_id;
                  retryable = false; metadata = [] }
      end
    in
    let input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("message", `Assoc [("type", `String "string"); ("description", `String "The message to send to the agent")]);
      ]);
      ("required", `List [`String "message"]);
    ] in
    match register_tool rt ~name:tool_name ~description:desc
      ~input_schema ~handler () with
    | Ok _ -> Ok ()
    | Error e -> Error e

let save_conversation rt ?(conversation : Types.conversation option) ?session_id ?scope () =
  let conv = match conversation with
    | Some c -> Some c
    | None -> Current_conversation.get rt
  in
  (* A caller-supplied [Invoke_context] is the session boundary for a branch
     or background run. Saving under [rt.session_id] would overwrite the
     parent's conversation even when the branch was explicitly isolated. *)
  let session_id =
    match session_id with
    | Some _ as s -> s
    | None ->
      (match Invoke_context.get_current () with
       | Some ctx -> Some ctx.Invoke_context.session_id
       | None -> !(rt.session_id))
  in
  match session_id, conv with
  | Some sid, Some c -> rt.services.persistence.save_conversation_fn ?scope sid c
  | _ -> Ok ()

let load_conversation rt sid =
  match rt.services.persistence.load_conversation_fn sid with
  | Ok (Some conv) ->
    rt.session_id := Some sid;
    Current_conversation.set rt (Some conv);
    rt.services.event_bus.set_session_id_fn sid;
    Logs.debug (fun m -> m "Session resumed: sid=%s (%d messages)"
                   sid (List.length conv.Types.messages));
    Ok (Some conv)
  | Ok None -> Ok None
  | Error _ as e -> e

let load_most_recent_conversation rt ?scope () =
  match rt.services.persistence.load_most_recent_conversation_fn ?scope () with
  | Ok (Some (sid, conv)) ->
    rt.session_id := Some sid;
    Current_conversation.set rt (Some conv);
    rt.services.event_bus.set_session_id_fn sid;
    Ok (Some (sid, conv))
  | Ok None -> Ok None
  | Error _ as e -> e

let list_conversations rt ?scope ?(limit = 50) () =
  rt.services.persistence.load_conversations_fn ?scope limit

(* The user turn a checkpointed conversation started from, used when recovery
   re-enters [invoke_content]: skills and the appendix are recomputed from it,
   so the resumed run sees the same activation the crashed one did. *)
let last_user_content (conv : Types.conversation) =
  List.fold_left (fun acc (m : Types.message) ->
    if m.role = Types.User then m.content_blocks else acc
  ) [] conv.messages

(* -------------------------------------------------------------------------- *)
(* Durable invoke ownership (PAR-53d)                                        *)
(* -------------------------------------------------------------------------- *)

(* How long a lease stays valid without a refresh. The holder refreshes it as
   the run works, so this only decides what happens when the holder stops:
   a crashed run, or a platform without a process probe. *)
let invoke_lease_ttl = 300.0

(* Take ownership of an in-flight invoke. Another runtime that holds the lease
   keeps it: recovering a live run would execute it twice. *)
let acquire_invoke_lease rt invoke_id =
  match rt.services.persistence.claim_invoke_lease_fn
          ~invoke_id ~owner:rt.runtime_id ~pid:(Unix.getpid ())
          ~ttl:invoke_lease_ttl with
  | Ok true ->
    Types.htbl_set rt.held_leases invoke_id ();
    Ok true
  | Ok false ->
    Result.Error (Invalid_input
      (Printf.sprintf
         "Invoke '%s' is owned by another runtime; it cannot be started or recovered here"
         invoke_id))
  | Error e -> Result.Error e

let release_invoke_lease rt invoke_id =
  Types.htbl_remove rt.held_leases invoke_id;
  ignore (rt.services.persistence.release_invoke_lease_fn
            ~invoke_id ~owner:rt.runtime_id)

(* Refresh the lease of a run that is still working. *)
let refresh_invoke_lease rt invoke_id =
  ignore (rt.services.persistence.claim_invoke_lease_fn
            ~invoke_id ~owner:rt.runtime_id ~pid:(Unix.getpid ())
            ~ttl:invoke_lease_ttl)

(* Tag events with the run's session while [f] runs, then put the caller's
   session back: leaving the run's session behind would tag events published
   after it finished with a run that no longer exists. [previous_session] must
   be captured before the run mints its session - reading [rt.session_id] here
   would restore the run's own session instead of the caller's state. An unset
   prior session is restored to the bus's explicit empty state. *)
let with_bus_session rt ~previous_session ~session_id f =
  rt.services.event_bus.set_session_id_fn session_id;
  Fun.protect
    ~finally:(fun () ->
      match previous_session with
      | Some sid -> rt.services.event_bus.set_session_id_fn sid
      | None -> rt.services.event_bus.set_session_id_fn "")
    f

let invoke_content_internal rt ~agent_id ~content ?workspace ?cancellation_token ?conversation
    ?on_tool_event ?on_chunk ?enable_handoff ?system_prompt_appendix
    ?(skills : string list option)
    ?(context : Invoke_context.invoke_context option)
    ?(update_current = true) ?(save = false)
    ?(durable = false) ?invoke_id
    ?(resume : invoke_checkpoint option)
    () =
  (* A named or durable run is checkpointed after every completed tool batch,
     so a crashed process can resume it. Naming a run with [~invoke_id] implies
     durability: a run the caller cannot name is a run it cannot recover. *)
  let durable = durable || invoke_id <> None || resume <> None in
  let invoke_id = match resume with
    | Some cp -> Some cp.invoke_id
    | None ->
      if durable then
        Some (match invoke_id with
              | Some id -> id
              | None -> Session_id.to_string (Session_id.create ()))
      else None
  in
  let content = match resume with
    | Some cp -> last_user_content cp.conversation
    | None -> content
  in
  let conversation = match resume with
    | Some cp -> Some cp.conversation
    | None -> conversation
  in
  (* A checkpoint taken with handoff enabled must resume with it: the flag
     changes which tools the loop will accept, so it is part of the state. *)
  let enable_handoff = match resume with
    | Some cp -> Some cp.enable_handoff
    | None -> enable_handoff
  in
  let empty_conv = { Types.messages = []; metadata = [] } in
  let error_conv = Option.value conversation ~default:empty_conv in
  (* A row that outlives its writer is a recovery input, not scratch space.
     Starting a fresh run under the same id would overwrite it silently. *)
  let is_startup_orphan = match resume with
    | Some _ -> false
    | None ->
      (match invoke_id with
       | Some id -> htbl_get rt.orphaned_invokes id <> None
       | None -> false)
  in
  let release_active () =
    match invoke_id with
    | Some id -> htbl_remove rt.active_invokes id
    | None -> ()
  in
  let delete_checkpoint () =
    match invoke_id with
    | Some id ->
      (match rt.services.persistence.delete_invoke_checkpoint_fn id with
       | Ok () -> ()
       | Error e ->
         Logs.err (fun m -> m "[invoke] delete_invoke_checkpoint failed (id=%s): %s"
                     id (string_of_error_category e)))
    | None -> ()
  in
  if durable && rt.persistence_is_noop then
    Result.Error (Invalid_input
      "durable invoke requires a persistence backend (the noop service cannot checkpoint)",
      error_conv)
  else if List.exists (function Tool_use_block _ | Tool_result_block _ -> true | _ -> false) content then
    Result.Error (Invalid_input "user content accepts only text and image blocks",
      Option.value conversation ~default:empty_conv)
  else if is_startup_orphan then
    Result.Error (Invalid_input
      (Printf.sprintf
         "Invoke id '%s' was left unfinished by a previous process; call \
          Runtime.recover_invoke ~invoke_id:%S to resume it, or start with a new id"
         (Option.value invoke_id ~default:"") (Option.value invoke_id ~default:"")),
      error_conv)
  else if not (match invoke_id with
               | Some id -> htbl_claim rt.active_invokes id
               | None -> true) then
    Result.Error (Invalid_input
      (Printf.sprintf "Invoke id '%s' is already in flight in this process"
         (Option.value invoke_id ~default:"")), error_conv)
  else
  (* A named run is owned for its lifetime: another runtime over the same
     database must not treat it as a leftover row. *)
  let lease_result =
    match invoke_id with
    | None -> Ok true
    | Some id -> acquire_invoke_lease rt id
  in
  match lease_result with
  | Error e -> Result.Error (e, error_conv)
  | Ok _ ->
  Fun.protect
    ~finally:(fun () ->
      (match invoke_id with
       | Some id -> release_invoke_lease rt id
       | None -> ());
      release_active ())
    (fun () ->
  let text_part = Message.string_of_content content in
  let effective_workspace = Option.value workspace ~default:rt.workspace in
  (* Capture this before building the context: minting a session below writes
     [rt.session_id] when [update_current] is true, and reading it afterwards
     would restore the invoke's own session instead of the caller's prior
     state. *)
  let previous_bus_session = !(rt.session_id) in
  let ctx = match context with
    | Some c -> c
    | None ->
      let session_id = match resume with
        | Some cp when cp.session_id <> "" -> cp.session_id
        | _ ->
          (match !(rt.session_id) with
           | Some sid -> sid
           | None ->
             let new_sid = Session_id.to_string (Session_id.create ()) in
             if update_current then rt.session_id := Some new_sid;
             new_sid)
      in
      (match resume with
       | Some cp when cp.session_id <> "" ->
         if update_current then rt.session_id := Some cp.session_id
       | _ -> ());
      Invoke_context.create
        ~session_id
        ~metrics:(Metrics.empty ())
        ~hooks:rt.tool_call_hooks
        ~skills:(Option.value skills ~default:rt.user_activated_skills)
        ?system_prompt_appendix
        ?on_tool_event
        ()
  in
  with_bus_session rt ~previous_session:previous_bus_session
    ~session_id:ctx.session_id
    (fun () -> Invoke_context.with_context ctx (fun () ->
  let result =
  let agent = htbl_get rt.agents agent_id in
  match agent with
  | None -> Result.Error (Invalid_input (Printf.sprintf "Agent not found: %s" agent_id),
                           { Types.messages = []; metadata = [] })
  | Some config ->
    let invoke_start = Unix.gettimeofday () in
    let base_elapsed = match resume with
      | Some cp -> cp.elapsed
      | None -> 0.0
    in
    let token = match cancellation_token with
      | Some t -> t
      | None -> Cancellation.create_token rt.cancellation_root
    in
    let on_tool_progress msg =
      let evt = Tool_progress {
        task_id = Task_id.create ();
        tool_name = "<engine>";
        message = msg;
      } in
      publish_event rt evt
    in
    let combined_tool_event evt =
      publish_event rt evt;
      (match on_tool_event with
       | Some cb -> cb evt
       | None -> ())
    in
    let active_effects =
      compute_active_skill_effects ~user_skills:ctx.user_activated_skills_snapshot rt text_part
    in
    let active_skill_ids =
      get_active_skill_ids ~user_skills:ctx.user_activated_skills_snapshot rt text_part
    in
    List.iter (fun sid ->
      publish_event rt (Skill_activated { skill_id = sid })
    ) active_skill_ids;
    let composed_effect = compose_skill_effects active_effects in
    let base_tools = config.tools in
    let before_tool_count = List.length config.tools in
    let config = apply_skill_effect_to_config composed_effect config in
    let apply_overrides tools =
      if rt.tool_description_overrides = [] then tools
      else
        List.map (fun (td : Types.tool_descriptor) ->
          match List.assoc_opt td.name rt.tool_description_overrides with
          | Some desc -> { td with Types.description = desc }
          | None -> td
        ) tools
    in
    let config = { config with tools = apply_overrides config.tools } in
    (* Recovery replays the tool set the crashed run actually saw. Recomputing
       skill effects from the checkpointed conversation can pick a different
       filter (the last user turn may be steering, and the activated-skill list
       is the current runtime's), which would silently change the model's
       available tools mid-run.  Filter the agent's unfiltered tool set, not the
       current skill-filtered one. *)
    let config =
      match resume with
      | Some cp when cp.tool_names <> [] ->
        let missing = List.filter (fun name ->
          not (List.exists (fun (td : Types.tool_descriptor) -> td.name = name) base_tools)
        ) cp.tool_names in
        if missing <> [] then
          Logs.warn (fun m -> m
            "[invoke] recovery checkpoint names tools that are no longer registered: %s"
            (String.concat ", " missing));
        let replay = List.filter (fun (td : Types.tool_descriptor) ->
          List.mem td.name cp.tool_names) base_tools in
        { config with tools = apply_overrides replay }
      | _ -> config
    in
    let after_tool_count = List.length config.tools in
    (match active_effects with
     | [] -> ()
     | _ when after_tool_count <> before_tool_count
           || composed_effect.system_prompt_override <> None ->
       let skill_ids =
         get_active_skill_ids ~user_skills:ctx.user_activated_skills_snapshot rt text_part
       in
       let skill_id = match skill_ids with
         | [] -> "unknown"
         | [id] -> id
         | _ -> Printf.sprintf "composite:%d" (List.length skill_ids)
       in
       let estimated_wasted_tokens =
         max 0 ((before_tool_count - after_tool_count) * 100)
       in
       publish_event rt (Cache_invalidated_by_skill {
         skill_id;
         before_tool_count;
         after_tool_count;
         estimated_wasted_tokens;
       })
     | _ -> ());
    let try_with_provider llm_svc =
      (* Approval_pending catch (v0.8.0 C3.1, ROADMAP A5). Engine raises
         when an [Async_callback] / [Webhook] approval handler needs
         external resolution. Catch at the invoke boundary (option b in
         the C3.1 plan): runtime has [rt.services.persistence] in scope,
         engine does not. On catch: (1) persist payload to SQLite for
         [resume_approval], (2) emit [Approval_requested] event so
         subscribers can route to an approver UI, (3) return [Ok] with
         the conversation snapshot + [approval_pending] metadata so the
         caller knows the invoke suspended (not failed).

         [approval_info_ref] threads the suspension metadata out of the
         exception handler: kept [None] on normal completion, [Some _]
         on suspension. The returned tuple is unified to
         (resp, conv, approval_info) at the boundary. *)
      let approval_info_ref = ref None in
      (* The last completed batch: what a suspension checkpoint records. *)
      let last_iteration = ref 0 in
      (* One writer for the checkpoint: the normal path (a batch completed)
         and the approval suspension (the batch never completed). *)
      let write_checkpoint ~(agent : agent_config) ~conversation ~iteration
          ~pending_approval () =
        match invoke_id with
        | None -> ()
        | Some id ->
          let now = Unix.gettimeofday () in
          let cp : Types.invoke_checkpoint = {
            invoke_id = id;
            agent_id = agent.id;
            session_id = ctx.session_id;
            schema_version = Types.invoke_checkpoint_schema_version;
            iteration;
            elapsed = base_elapsed +. (now -. invoke_start);
            enable_handoff = Option.value enable_handoff ~default:false;
            tool_names = List.map (fun (td : Types.tool_descriptor) -> td.name) agent.tools;
            workspace_roots = Some effective_workspace.Workspace.roots;
            workspace_sensitive_prefixes =
              Some effective_workspace.Workspace.policy.Workspace.sensitive_prefixes;
            system_prompt_appendix = ctx.system_prompt_appendix;
            skills = Some ctx.user_activated_skills_snapshot;
            pending_approval;
            conversation;
            updated_at = now;
          } in
          refresh_invoke_lease rt id;
          (match rt.services.persistence.save_invoke_checkpoint_fn cp with
           | Ok () -> ()
           | Error e ->
             Logs.err (fun m ->
               m "[invoke] save_invoke_checkpoint failed (id=%s iter=%d): %s"
               id iteration (string_of_error_category e));
             (* The run continues, but that step is not recoverable. Say so on
                the bus instead of leaving it in a log file. *)
             publish_event rt (Invoke_checkpoint_failed { invoke_id = id; error = e }))
      in
      let result =
        (try Engine.run_agent ~steering:(Some ctx.steering_queue)
            ~followup:(Some ctx.followup_queue)
            ~runtime_id:rt.runtime_id
            ~tool_call_hooks:(Some ctx.tool_call_hooks_snapshot)
            ~quota:(Some rt.task_semaphore)
            ~parallel:rt.parallel_tool_execution
            ~on_progress:(Some on_tool_progress)
            ~on_tool_event:(Some combined_tool_event)
            ?on_chunk
            ?conversation
            ~agent_resolver:(fun aid -> htbl_get rt.agents aid)
            ~enable_handoff:(Option.value enable_handoff ~default:false)
            ?net:(Option.map (fun n -> (Obj.obj n : _ Eio.Net.t)) rt.net)
            ?budget_threshold:rt.services.config.max_tool_schema_tokens
            ~user_content:content
            ~on_step_complete:(Some (fun conv step_agent iteration ->
              last_iteration := iteration;
              write_checkpoint ~agent:step_agent ~conversation:conv
                ~iteration ~pending_approval:None ()))
            ~resume:(resume <> None)
            ~resume_iteration:(match resume with Some cp -> cp.iteration | None -> 0)
            ~resume_elapsed:base_elapsed
            token config text_part llm_svc (per_call_registry ~rt ~workspace:effective_workspace)
          with
          | Engine.Approval_pending payload ->
            (* Unique persistence key. [payload.run_id] is the runtime's
               session id, which is shared by all invokes on this runtime;
               mint a fresh id here so concurrent pending approvals do not
               collide in the [approvals] table. *)
            let persist_id = Session_id.to_string (Session_id.create ()) in
            let stored_payload = `Assoc [
              ("persist_id", `String persist_id);
              ("runtime_run_id", `String payload.run_id);
              ("invoke_id", `String (Option.value invoke_id ~default:""));
              ("agent_id", `String payload.agent_id);
              ("tool_name", `String payload.tool_name);
              ("tool_input", payload.tool_input);
              ("conv_snapshot", Types.conversation_to_yojson payload.conv_snapshot);
              ("engine_pending_payload", payload.pending_payload);
              ("expires_at", `Float payload.expires_at);
              ("created_at", `Float (Unix.gettimeofday ()));
            ] in
            (match rt.services.persistence.save_pending_approval_fn
               ~run_id:persist_id ~agent_id:payload.agent_id
               ~payload:stored_payload ~expires_at:payload.expires_at with
             | Ok () -> ()
             | Error e ->
               Logs.err (fun m -> m
                 "[invoke] save_pending_approval failed (run_id=%s agent=%s tool=%s): %s"
                 persist_id payload.agent_id payload.tool_name
                 (string_of_error_category e)));
            publish_event rt (Approval_requested {
              prompt = Printf.sprintf "Approval required for tool %s on agent %s"
                         payload.tool_name payload.agent_id;
              allowed_roles = [];
            });
            let suspended_resp : Types.llm_response = {
              text = Some (Printf.sprintf
                "Approval required for tool %s — awaiting decision (run_id=%s, expires_at=%.0f)"
                payload.tool_name persist_id payload.expires_at);
              reasoning = [];
              tool_calls = None;
              finish_reason = Stop;
              usage = {
                prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
                cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0;
              };
              model = config.model.model_name;
            } in
            approval_info_ref := Some {
              run_id = persist_id;
              agent_id = payload.agent_id;
              tool_name = payload.tool_name;
              expires_at = payload.expires_at;
            };
            (* The run is waiting for a decision, not finished: keep its
               checkpoint, so a crash while it waits does not lose the run.
               The approvals row owns the decision; the checkpoint says which
               decision the run is waiting for. *)
            (match invoke_id with
             | None -> ()
             | Some _ ->
               write_checkpoint ~agent:config ~conversation:payload.conv_snapshot
                 ~iteration:!last_iteration
                 ~pending_approval:(Some {
                     approval_id = persist_id;
                     agent_id = payload.agent_id;
                     tool_name = payload.tool_name;
                     expires_at = payload.expires_at;
                   }) ());
            if update_current then Current_conversation.set rt (Some payload.conv_snapshot);
            Ok (suspended_resp, payload.conv_snapshot))
      in
      match result with
      | Ok (resp, conv) -> Ok (resp, conv, !approval_info_ref)
      | Error e -> Error e
    in
    let should_fallback (err : Types.error_category) = match err with
      | Types.Rate_limited | Types.External_failure _ | Types.Timeout -> true
      | Types.Cancelled _ -> false
      | _ -> false
    in
    let chain = match rt.fallback_policy with
      | No_fallback -> []
      | Ordered ids -> ids
      | Tagged { primary; backup } -> [primary; backup]
    in
    let default_id = Provider_registry.default_id rt.llm_providers in
    let all_ids = match default_id with
      | Some d -> d :: List.filter (fun id -> id <> d) chain
      | None -> chain
    in
    let rec try_providers ids =
      match ids with
      | [] ->
        let err = Invalid_input "No default LLM provider configured." in
        record_llm_error rt err;
        Result.Error (err, { Types.messages = []; metadata = [] })
      | id :: rest ->
        (match Provider_registry.get rt.llm_providers ~id with
         | Error `Unknown _ -> try_providers rest
         | Ok llm_svc ->
(match try_with_provider llm_svc with
              | Ok (resp, conv, approval_pending) ->
                record_llm_success rt;
                if update_current then Current_conversation.set rt (Some conv);
                if save then ignore (save_conversation rt ~conversation:conv
                                       ~session_id:ctx.session_id () : (unit, error_category) result);
                Result.Ok { Types.response = resp; conversation = conv; approval_pending; invoke_id }
              | Error (err, _conv) when should_fallback err && rest <> [] ->
                record_llm_error rt err;
                let evt = Types.Provider_fallback_attempted {
                  from_provider = id;
                  to_provider = List.hd rest;
                } in
                rt.services.event_bus.publish_fn evt;
                try_providers rest
              | Error (err, conv) ->
                record_llm_error rt err;
                if update_current then Current_conversation.set rt (Some conv);
                Result.Error (err, conv)))
    in
    (* A cancellation that unwinds by exception is an intentional stop, not a
       crash: drop the checkpoint before re-raising so the next startup does not
       announce a cancelled run as an orphan. Unexpected exceptions keep it -
       that is the crash path recovery is for. *)
    (try try_providers all_ids
     with (Eio.Cancel.Cancelled _ as ex) ->
       delete_checkpoint ();
       raise ex)
  in
  (* A checkpoint row means "in flight", so every terminal outcome removes it.
     A run suspended for approval also removes it: the approvals row owns that
     state and [resume_approval] is its recovery path.  A recovery attempt that
     fails for a transient reason keeps the row so the caller can retry; a
     deliberate cancellation is terminal and removes it. *)
  (match result, resume with
   | Result.Error (Cancelled _, _), _ -> delete_checkpoint ()
   | Result.Error _, Some _ -> ()
   (* A run suspended for approval is not finished: its checkpoint stays, so
      the run survives a crash while it waits for a decision. *)
   | Result.Ok { approval_pending = Some _; _ }, _ -> ()
   | _ -> delete_checkpoint ());
  Metrics.merge_into ~target:rt.metrics ~source:ctx.metrics_accumulator;
  result)))

(* The public entry point hides [~resume]: resuming from an arbitrary
   checkpoint would bypass the orphan and in-flight guards in [recover_invoke]. *)
let invoke_content rt ~agent_id ~content ?workspace ?cancellation_token ?conversation
    ?on_tool_event ?on_chunk ?enable_handoff ?system_prompt_appendix
    ?(skills : string list option)
    ?(context : Invoke_context.invoke_context option)
    ?(update_current = true) ?(save = false)
    ?(durable = false) ?invoke_id () =
  invoke_content_internal rt ~agent_id ~content ?workspace ?cancellation_token ?conversation
    ?on_tool_event ?on_chunk ?enable_handoff ?system_prompt_appendix
    ?skills ?context ~update_current ~save ~durable ?invoke_id ()

let invoke rt ~agent_id ~message ?workspace ?cancellation_token ?conversation
    ?on_tool_event ?on_chunk ?enable_handoff ?system_prompt_appendix
    ?(skills : string list option)
    ?(context : Invoke_context.invoke_context option)
    ?(update_current = true) ?(save = false) ?(durable = false) ?invoke_id () =
  invoke_content rt ~agent_id ~content:(Message.content_of_string message)
    ?workspace ?cancellation_token ?conversation
    ?on_tool_event ?on_chunk ?enable_handoff ?system_prompt_appendix
    ?skills ?context ~update_current ~save ~durable ?invoke_id ()

let invoke_async rt ~agent_id ~message ?workspace ?cancellation_token ?conversation
    ?on_tool_event ?on_chunk ?enable_handoff ?system_prompt_appendix ?skills ?context
    ?(update_current = true) ?(save = false)
    ?(durable = false) ?invoke_id () =
  let token = match cancellation_token with
    | Some t -> t
    | None -> Cancellation.create_token rt.cancellation_root
  in
  Invoke_context.fork_invoke ~sw:rt.cancellation_root ~token (fun () ->
    invoke rt ~agent_id ~message ?workspace
      ~cancellation_token:token ?conversation ?on_tool_event ?on_chunk
      ?enable_handoff ?system_prompt_appendix ?skills ?context
      ~update_current ~save ~durable ?invoke_id ())

let invoke_generate rt ~agent_id ~message ?max_output_tokens ?total_timeout
    ?(save = true) ?(update_current = true) ?on_tool_event ?on_chunk ?system_prompt_appendix () =
  (* Capture the caller's session before minting one below: [update_current]
     would otherwise make us restore this run's own session. *)
  let previous_bus_session = !(rt.session_id) in
  let session_id = match !(rt.session_id) with
    | Some sid -> sid
    | None ->
      let new_sid = Session_id.to_string (Session_id.create ()) in
      (* [update_current] controls the runtime's current session, not the
         session this run uses: a background generate must still report the id
         it ran under. *)
      if update_current then rt.session_id := Some new_sid;
      new_sid
  in
  with_bus_session rt ~previous_session:previous_bus_session ~session_id (fun () ->
  match htbl_get rt.agents agent_id with
  | None -> Result.Error (Invalid_input (Printf.sprintf "Unknown agent: %s" agent_id),
                           { Types.messages = []; metadata = [] })
  | Some config when config.tools <> [] ->
    Result.Error (Invalid_input (Printf.sprintf
      "Agent '%s' has tools but generate mode requires tools=[]" agent_id),
      { Types.messages = []; metadata = [] })
  | Some config ->
    let token = Cancellation.create_token rt.cancellation_root in
    let combined_tool_event evt =
      publish_event rt evt;
      (match on_tool_event with
       | Some cb -> cb evt
       | None -> ())
    in
    let active_effects = compute_active_skill_effects rt message in
    let composed_effect = compose_skill_effects active_effects in
    let before_tool_count = List.length config.tools in
    let config = apply_skill_effect_to_config composed_effect config in
    let after_tool_count = List.length config.tools in
    (* v0.6.4 B.5.2: emit cache invalidation event when skill overlay mutates state *)
    (match active_effects with
     | [] -> ()
     | _ when after_tool_count <> before_tool_count
           || composed_effect.system_prompt_override <> None ->
       let skill_ids = get_active_skill_ids rt message in
       let skill_id = match skill_ids with
         | [] -> "unknown"
         | [id] -> id
         | _ -> Printf.sprintf "composite:%d" (List.length skill_ids)
       in
       let estimated_wasted_tokens =
         max 0 ((before_tool_count - after_tool_count) * 100)
       in
       publish_event rt (Cache_invalidated_by_skill {
         skill_id;
         before_tool_count;
         after_tool_count;
         estimated_wasted_tokens;
       })
     | _ -> ());
    let ctx = Invoke_context.create
      ~session_id
      ~metrics:(Metrics.empty ())
      ?system_prompt_appendix
      () in
    Invoke_context.with_context ctx (fun () ->
    match Provider_registry.get_default rt.llm_providers with
    | Error `No_default ->
      let err = Invalid_input "No default LLM provider configured." in
      record_llm_error rt err;
      Result.Error (err, { Types.messages = []; metadata = [] })
    | Ok llm_svc ->
      let result = Generate.run
        ~session_id
        ~agent:config
        ~message
        ?max_output_tokens
        ?total_timeout
        ?on_tool_event:(Some combined_tool_event)
        ?on_chunk
        ~cancellation_token:token
        ~llm:llm_svc
        () in
       (match result with
        | Ok (gen_result, conv) ->
          record_llm_success rt;
          if update_current then Current_conversation.set rt (Some conv);
          if save then
            ignore (save_conversation rt ~conversation:conv
                      ~session_id:ctx.session_id () : (unit, error_category) result);
          Result.Ok gen_result
        | Error (err, conv) ->
          record_llm_error rt err;
          if update_current then Current_conversation.set rt (Some conv);
          Result.Error (err, conv))))

let invoke_structured rt ~agent_id ~message ~response_schema
    ?(max_repair_attempts = 3) ?cancellation_token ?conversation
    ?system_prompt_appendix
    ?on_tool_event ?on_repair_attempt () =
  let previous_bus_session = !(rt.session_id) in
  let session_id = Session_id.to_string (Session_id.create ()) in
  let ctx = Invoke_context.create
    ~session_id
    ~metrics:(Metrics.empty ())
    ?system_prompt_appendix
    () in
  with_bus_session rt ~previous_session:previous_bus_session ~session_id (fun () ->
  Invoke_context.with_context ctx (fun () ->
  let agent = htbl_get rt.agents agent_id in
  match agent with
  | None -> Result.Error (Invalid_input (Printf.sprintf "Agent not found: %s" agent_id),
                           { Types.messages = []; metadata = [] })
  | Some config ->
    let token = match cancellation_token with
      | Some t -> t
      | None -> Cancellation.create_token rt.cancellation_root
    in
    let combined_tool_event evt =
      publish_event rt evt;
      (match on_tool_event with
       | Some cb -> cb evt
       | None -> ())
    in
    let on_before_llm_hook conv =
      Some (Engine.apply_before_llm config.middleware conv (fun c -> c))
    in
    let on_after_llm_hook resp =
      Some (Engine.apply_after_llm config.middleware resp (fun r -> r))
    in
    let result =
      match Provider_registry.get_default rt.llm_providers with
      | Error `No_default ->
        let err = Invalid_input
          "No default LLM provider configured. Register one via Runtime.register_llm_provider or configure llm_providers." in
        record_llm_error rt err;
        Result.Error (err, { Types.messages = []; metadata = [] })
      | Ok llm_svc ->
        if config.tools <> [] then
          let call_registry = per_call_registry ~rt ~workspace:rt.workspace in
          Engine.run_agent_structured
            ~max_repair_attempts
            ~on_before_llm:(Some on_before_llm_hook)
            ~on_after_llm:(Some on_after_llm_hook)
            ~on_tool_event:(Some combined_tool_event)
            ~quota:(Some rt.task_semaphore)
            ~parallel:rt.parallel_tool_execution
            ?on_repair_attempt
            ?conversation
            ?net:(Option.map (fun n -> (Obj.obj n : _ Eio.Net.t)) rt.net)
            ?budget_threshold:rt.services.config.max_tool_schema_tokens
            ~response_schema
            llm_svc token config message
            call_registry
        else
          Engine.run_structured
            ~max_repair_attempts
            ~on_before_llm:(Some on_before_llm_hook)
            ~on_after_llm:(Some on_after_llm_hook)
            ~response_schema
            ?conversation
            ?on_repair_attempt
            llm_svc token config message
    in
    (match result with
     | Ok struct_result ->
       record_llm_success rt;
       let evt = Types.Structured_output_completed {
         attempts = struct_result.attempts;
         schema_valid = true;
         task_id = Task_id.create ();
       } in
       publish_event rt evt;
       Result.Ok struct_result
     | Error (err, conv) ->
       record_llm_error rt err;
       let evt = Types.Structured_output_completed {
         attempts = max_repair_attempts;
         schema_valid = false;
         task_id = Task_id.create ();
       } in
       publish_event rt evt;
       Result.Error (err, conv))))

let embed rt messages =
  match rt.services.embeddings with
  | None -> Result.Error (Internal "Embeddings not initialized")
  | Some svc -> svc.embed_fn messages

let invoke_with_rag rt ~agent_id ~message ?(k = 4) ?vector_store () =
  let vs = match vector_store with
    | Some v -> Some v
    | None -> rt.vector_store
  in
  match vs with
  | None ->
    (match invoke rt ~agent_id ~message () with
     | Result.Ok answer -> Result.Ok (answer, [])
     | Result.Error (e, _) -> Result.Error e)
  | Some vs ->
    (match embed rt [message] with
     | Result.Error e -> Result.Error e
     | Result.Ok [] -> Result.Error (Internal "embed returned empty list")
     | Result.Ok (query_vec :: _) ->
       (match Vector_store.search vs ~query:query_vec ~k with
        | Result.Error e -> Result.Error e
         | Result.Ok [] ->
           (match invoke rt ~agent_id ~message () with
            | Result.Ok answer -> Result.Ok (answer, [])
            | Result.Error (e, _) -> Result.Error e)
        | Result.Ok results ->
          let context_buf = Buffer.create 1024 in
          List.iteri
            (fun i r ->
              if i > 0 then Buffer.add_string context_buf "\n\n";
              Buffer.add_string context_buf r.Vector_store.doc.content)
            results;
          let augmented =
            Printf.sprintf "Context:\n%s\n\nQuestion: %s"
              (Buffer.contents context_buf) message
          in
          (match invoke rt ~agent_id ~message:augmented () with
           | Result.Error (e, _) -> Result.Error e
           | Result.Ok answer ->
              Result.Ok (answer, List.map (fun r -> r.Vector_store.doc) results))))

let submit_task rt ?(priority = 5) ?(timeout = 300.0) input =
  let id = Task_id.create () in
  let task = {
    id;
    input;
    status = Pending;
    parent_id = None;
    workflow_run_id = None;
    priority;
    schedule = None;
    timeout;
    retry_policy = None;
    retry_count = 0;
    dependencies = [];
    depend_mode = `All_success;
    created_at = Unix.time ();
    updated_at = Unix.time ();
    output = None;
    error = None;
  } in
  htbl_set rt.tasks id task;
   (match rt.services.persistence.save_task_state_fn task with
    | Ok () -> ()
    | Error e -> Logs.err (fun m -> m "save_task_state failed: %s" (string_of_error_category e)));
  id

let get_task_status rt task_id =
  match htbl_get rt.tasks task_id with
  | Some task -> Ok (Some task.status)
  | None ->
    (match rt.services.persistence.load_task_state_fn task_id with
     | Ok (Some ts) -> Ok (Some ts.status)
     | Ok None -> Ok None
     | Error e ->
       Logs.err (fun m -> m "load_task_state failed: %s" (string_of_error_category e));
       Ok None)

let cancel_task rt task_id =
  let task_opt =
    match htbl_get rt.tasks task_id with
    | Some t -> Some t
    | None ->
      (match rt.services.persistence.load_task_state_fn task_id with
       | Ok (Some t) -> Some t
       | Ok None | Error _ -> None)
  in
  match task_opt with
  | None -> Result.Error (Invalid_input "Task not found")
  | Some task ->
    let updated = { task with status = Cancelled; updated_at = Unix.time () } in
    htbl_set rt.tasks task_id updated;
    (match rt.services.persistence.save_task_state_fn updated with
     | Ok () -> ()
     | Error e -> Logs.err (fun m -> m "save_task_state failed: %s" (string_of_error_category e)));
    Ok ()

let approve_task rt task_id ~approver:_ =
  match htbl_get rt.tasks task_id with
  | None -> Result.Error (Invalid_input "Task not found")
  | Some task ->
    match task.status with
    | Waiting_input ->
      let updated = { task with status = Scheduled; updated_at = Unix.time () } in
      htbl_set rt.tasks task_id updated;
      (match rt.services.persistence.save_task_state_fn updated with
       | Ok () -> ()
       | Error e -> Logs.err (fun m -> m "save_task_state failed: %s" (string_of_error_category e)));
      Ok ()
    | _ -> Result.Error (Invalid_input "Task is not waiting for approval")

(* -------------------------------------------------------------------------- *)
(* HITL resume — v0.8.0 C3.1 (ROADMAP A6)                                    *)
(* -------------------------------------------------------------------------- *)

(* [resume_approval] applies an external approver's decision to a previously
   suspended invoke. Suspend state is loaded from the [approvals] SQLite
   table by [run_id] (the same id returned in [invoke_result.approval_pending]
   when the invoke suspended).

   Wave 3 simplicity: re-dispatch reconstructs a fresh [Engine.run_agent]
   call with the persisted conversation snapshot and an agent whose
   [approval_handler] has been replaced with [Sync_local (fun _ -> outcome)].
   The engine's ReAct loop will then reach the same tool call and resolve
   the approval synchronously (no second suspension) — see
   [lib/core/engine.ml] execute_approval Sync_local branch.

   Known simplifications (tracked for Wave 5 validation):
   - Re-dispatch appends a synthetic user message ("Approval resolved; please
     continue.") to the snapshot. The agent sees the suspended conversation
     plus this nudge. If the agent re-emits a different tool call, the new
     approval_handler (Sync_local returning the stored outcome) is reused,
     which may be incorrect for the new tool. Wave 5 tests will surface
     cases where this matters.
   - Re-dispatch outcome is NOT reflected in the returned [unit]: callers
     observe the result via [current_conversation] or events. A future
     revision may return the resumed invoke_result.
   - No cross-process resumption validation (snapshot hash check): deferred
     to Wave 5 per ROADMAP §5 risk #5 mitigation plan. *)

let resume_approval ~rt ~run_id ~outcome ~approver =
  match rt.services.persistence.load_pending_approval_fn ~run_id with
  | Error e ->
    Logs.err (fun m -> m "resume_approval: load failed (run_id=%s): %s"
                 run_id (string_of_error_category e));
    Result.Error (Internal (Printf.sprintf
                   "resume_approval: load_pending_approval failed: %s"
                   (string_of_error_category e)))
  | Ok None ->
    (* Either the run_id was never suspended, or it auto-expired on read. *)
    Result.Error (Invalid_input
      (Printf.sprintf "resume_approval: pending approval not found or expired (run_id=%s)"
         run_id))
  | Ok (Some stored_payload) ->
    let open Yojson.Safe.Util in
    let agent_id = match member "agent_id" stored_payload with
      | `String s -> s
      | _ -> "unknown"
    in
    let tool_name = match member "tool_name" stored_payload with
      | `String s -> s
      | _ -> "unknown"
    in
    let conv_snapshot = match member "conv_snapshot" stored_payload with
      | json ->
        (match Types.conversation_of_yojson json with
         | Ok c -> c
         | Error msg ->
           Logs.err (fun m -> m "resume_approval: conv_snapshot decode failed: %s" msg);
           { Types.messages = []; metadata = [] })
      | exception Yojson.Safe.Util.Type_error _ ->
        { Types.messages = []; metadata = [] }
    in
    (* Look up the agent. If missing, we still emit events + delete the row
       so the system doesn't leak pending state, but return Error. *)
    (match htbl_get rt.agents agent_id with
     | None ->
       publish_event rt (Approval_handler_missing { agent_id; tool_name });
       (match rt.services.persistence.delete_pending_approval_fn ~run_id with
        | Ok () -> ()
        | Error e -> Logs.err (fun m -> m "resume_approval: delete failed: %s"
                                  (string_of_error_category e)));
       Result.Error (Invalid_input
         (Printf.sprintf "resume_approval: agent '%s' not registered" agent_id))
     | Some agent ->
       (* Emit outcome event before re-dispatch so subscribers see the
          decision even if re-dispatch itself fails. *)
       (match (outcome : Approval.approval_outcome) with
        | Approved ->
          publish_event rt (Approval_granted { approver })
        | Rejected { reason } ->
          publish_event rt (Approval_rejected { reason; approver })
        | Modified { new_input } ->
          publish_event rt (Approval_modified { new_input; approver })
        | Escalated { target } ->
          publish_event rt (Approval_escalated { target; approver })
        | Timeout ->
          publish_event rt Approval_timeout);
       (* Terminal outcomes (Rejected, Timeout) do not re-dispatch: the
          conversation is left in its suspended state and the pending row
          is deleted. The caller can inspect [current_conversation] for
          the suspended snapshot. *)
       let needs_redispatch = match outcome with
         | Approved | Modified _ | Escalated _ -> true
         | Rejected _ | Timeout -> false
       in
       (match rt.services.persistence.delete_pending_approval_fn ~run_id with
        | Ok () -> ()
        | Error e -> Logs.err (fun m -> m "resume_approval: delete failed: %s"
                                  (string_of_error_category e)));
       (* The decision is applied: the durable state of that run is superseded
          by the resumed run, so the checkpoint goes with it. *)
       (match member "invoke_id" stored_payload with
        | `String id when id <> "" ->
          (match rt.services.persistence.delete_invoke_checkpoint_fn id with
           | Ok () -> ()
           | Error e -> Logs.err (fun m ->
               m "resume_approval: checkpoint delete failed (id=%s): %s"
               id (string_of_error_category e)))
        | _ -> ());
       if not needs_redispatch then Ok ()
       else begin
         (* Wave 3 re-dispatch: replace approval_handler with a Sync_local
            that returns the stored outcome. The engine's execute_approval
            will resolve synchronously. *)
         let resumed_handler : Types.approval_context Approval.approval_handler =
           Approval.Sync_local (fun _ctx -> outcome)
         in
         let resumed_agent : Types.agent_config =
           { agent with approval_handler = Some resumed_handler }
         in
          (* The cancellation_token here is a fresh sub-token of the
             runtime's root. The original invoke's token may have been
             cancelled (or not) — we cannot recover it from the persisted
             snapshot without a token id field, so a fresh token is the
             conservative choice. *)
          let token = Cancellation.create_token rt.cancellation_root in
          let registry = per_call_registry ~rt ~workspace:rt.workspace in
          (* Bug 1 fix: preserve conv_snapshot across suspend/resume.
             The snapshot has [system; user(orig_request); assistant(tool_call)]
             but NO tool_result message (the engine raises Approval_pending
             before adding one). We inject a synthetic tool_result whose
             content mirrors what execute_approval would have produced for a
             synchronous outcome. Without this, the LLM loses ALL original
             context (user request, prior tool calls) because Engine.run_agent
             would start a fresh conversation with only the continue message. *)
          let resumed_conv =
            (* The engine raises Approval_pending after appending any normal
               tool results from the same batch, so the snapshot's last message
               may be a Tool message rather than the assistant tool_call.  Read
               the id/name from the persisted pending payload; fall back to
               scanning only for older snapshots. *)
            let engine_pending = member "engine_pending_payload" stored_payload in
            let payload_id = match member "tool_call_id" engine_pending with
              | `String s when s <> "" -> Some s
              | _ -> None
            in
            let payload_name = match member "tool_name" engine_pending with
              | `String s when s <> "" -> Some s
              | _ -> None
            in
            let fallback () =
              match List.rev conv_snapshot.messages with
              | { role = Assistant; tool_calls = Some (tc :: _); _ } :: _ ->
                tc.id, tc.name
              | _ -> "unknown", tool_name
            in
            let tool_call_id, tool_name_from_snapshot =
              match payload_id with
              | Some id -> id, Option.value payload_name ~default:tool_name
              | None -> fallback ()
            in
            let synth_content = match (outcome : Approval.approval_outcome) with
              | Approved ->
                Yojson.Safe.to_string (`Assoc [
                  ("status", `String "approved");
                  ("message", `String (Printf.sprintf
                                       "approval granted for %s" tool_name));
                ])
              | Modified { new_input } ->
                Yojson.Safe.to_string (`Assoc [
                  ("status", `String "approved_with_modifications");
                  ("new_input", new_input);
                ])
              | Escalated { target } ->
                Yojson.Safe.to_string (`Assoc [
                  ("status", `String "escalated");
                  ("target", `String target);
                ])
              (* Rejected / Timeout do not reach re-dispatch, but handle
                 defensively in case the dispatch tree changes later. *)
              | Rejected { reason } -> reason
              | Timeout -> "approval timed out"
            in
            let tool_msg : message = {
              role = Tool;
              content_blocks = Message.content_of_string synth_content;
              tool_calls = None;
              tool_call_id = Some tool_call_id;
              name = Some tool_name_from_snapshot;
            } in
            { conv_snapshot with
              messages = conv_snapshot.messages @ [ tool_msg ] }
          in
          let result =
            try Engine.run_agent
              ~runtime_id:rt.runtime_id
              ~quota:(Some rt.task_semaphore)
              ~parallel:rt.parallel_tool_execution
              ~enable_handoff:false
              ~conversation:resumed_conv
              ?net:(Option.map (fun n -> (Obj.obj n : _ Eio.Net.t)) rt.net)
              ?budget_threshold:rt.services.config.max_tool_schema_tokens
              token resumed_agent
              "Approval resolved; please continue."
              rt.services.llm registry
            with exn ->
              Logs.err (fun m -> m "resume_approval: re-dispatch raised: %s"
                           (Printexc.to_string exn));
              Error (Internal (Printf.sprintf
                       "resume_approval re-dispatch raised: %s"
                       (Printexc.to_string exn)),
                     conv_snapshot)
          in
         match result with
         | Ok (_resp, conv) ->
           Current_conversation.set rt (Some conv);
           Ok ()
         | Error (e, _conv) ->
           Logs.err (fun m -> m "resume_approval: re-dispatch failed: %s"
                        (string_of_error_category e));
           Result.Error e
       end)

let find_tool_across_agents rt tool_name =
  let result = ref None in
  htbl_iter rt.agents (fun _id (agent : agent_config) ->
    if result.contents = None then
      result := List.find_opt (fun (td : tool_descriptor) -> td.name = tool_name) agent.tools
  );
  result.contents

(* C3.3: Callback invoked by Workflow_engine.execute_parallel when a branch
   agent raises [Engine.Approval_pending]. Persists the approval under a
   fresh key (so concurrent suspensions don't collide) and emits an
   [Approval_requested] event. Returns [[`Continue]] — workflow Parallel
   steps are non-blocking by default; sibling branches finish while the
   suspended branch records a marker result for [resume_approval]. *)
let parallel_approval_cb rt (data : Workflow_engine.approval_suspend_payload) =
  let persist_id = Session_id.to_string (Session_id.create ()) in
  let stored_payload = `Assoc [
    ("persist_id", `String persist_id);
    ("runtime_run_id", `String data.run_id);
    ("agent_id", `String data.agent_id);
    ("tool_name", `String data.tool_name);
    ("tool_input", data.tool_input);
    ("conv_snapshot", Types.conversation_to_yojson data.conv_snapshot);
    ("engine_pending_payload", data.pending_payload);
    ("expires_at", `Float data.expires_at);
    ("created_at", `Float (Unix.gettimeofday ()));
  ] in
  (match rt.services.persistence.save_pending_approval_fn
     ~run_id:persist_id ~agent_id:data.agent_id
     ~payload:stored_payload ~expires_at:data.expires_at with
   | Ok () -> ()
   | Error e ->
     Logs.err (fun m -> m
       "[workflow_parallel] save_pending_approval failed (agent=%s tool=%s): %s"
       data.agent_id data.tool_name (string_of_error_category e)));
  publish_event rt (Approval_requested {
    prompt = Printf.sprintf "Approval required for tool %s on agent %s"
               data.tool_name data.agent_id;
    allowed_roles = [];
  });
  `Continue

let submit_workflow rt ?workspace ?(inputs = []) wf =
  let effective_workspace = Option.value workspace ~default:rt.workspace in
  let call_registry = per_call_registry ~rt ~workspace:effective_workspace in
  let effective_vars = wf.def.variables @ inputs in
  let id = Workflow_run_id.create () in
  htbl_set rt.workflows id Wf_running;
  publish_event rt (Workflow_started { workflow_run_id = id });
  let token = Cancellation.create_token rt.cancellation_root in
  let checkpoint_cb (completion : Workflow_engine.step_completion) =
    let step_id =
      String.concat "." (List.map string_of_int completion.Workflow_engine.path) in
    publish_event rt (Workflow_step_completed { step_id });
    let cp = Workflow_engine.make_checkpoint
               ~step_path:completion.Workflow_engine.path
               ~step_results:[completion.Workflow_engine.result]
               ~variables:completion.Workflow_engine.variables
               {
                  Workflow_engine.variables = effective_vars;
                 token;
                 agent_resolver = (fun aid -> htbl_get rt.agents aid);
                 tool_resolver = find_tool_across_agents rt;
                 llm = rt.services.llm;
                 registry = call_registry;
                  parallel_limit = wf.def.parallel_limit;
                  failure_policy = wf.def.failure_policy;
                 workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
                 on_step_complete = None;
    workflow_run_id = Some id;
    workflow_id_resolver = (fun () -> Some wf.def.id);
    workspace = effective_workspace;
    workspace_overrides = [];
    approval_handler_overrides = [];
    per_call_registry_fn = None;
    on_approval_pending = None;
      net = rt.net;
                 }
    in
    (match rt.services.persistence.save_workflow_state_fn id Wf_running (Some cp) with
     | Ok () -> ()
     | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)))
  in
  let ctx = {
    Workflow_engine.variables = effective_vars;
    token;
    agent_resolver = (fun aid -> htbl_get rt.agents aid);
    tool_resolver = find_tool_across_agents rt;
    llm = rt.services.llm;
    registry = call_registry;
    parallel_limit = wf.def.parallel_limit;
    failure_policy = wf.def.failure_policy;
    workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
    on_step_complete = Some checkpoint_cb;
    workflow_run_id = Some id;
    workflow_id_resolver = (fun () -> Some wf.def.id);
    workspace = effective_workspace;
    workspace_overrides = [];
    approval_handler_overrides = [];
    per_call_registry_fn = None;
    on_approval_pending = Some (parallel_approval_cb rt);
      net = rt.net;
  } in
  (match Workflow_engine.execute_workflow ctx wf with
   | Ok result ->
     htbl_set rt.workflows id (Wf_completed result);
      (match rt.services.persistence.save_workflow_state_fn id (Wf_completed result) None with
       | Ok () -> ()
       | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
     publish_event rt (Workflow_completed { workflow_run_id = id });
     Ok id
    | exception Workflow_engine.Workflow_suspended { checkpoint = cp; prompt; allowed_roles } ->
      htbl_set rt.workflows id (Wf_suspended cp);
      (match rt.services.persistence.save_workflow_state_fn id (Wf_suspended cp) (Some cp) with
        | Ok () -> ()
        | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
      publish_event rt (Approval_requested { prompt; allowed_roles });
      (match Workflow_engine.Approval_deadline.lookup id with
       | Some deadline_entry ->
         let remaining = Workflow_engine.Approval_deadline.deadline_of deadline_entry -. Unix.gettimeofday () in
         if remaining > 0.0 then
           ignore (Eio.Fiber.fork ~sw:(Workflow_engine.Approval_deadline.switch_of deadline_entry) (fun () ->
             let deadline = Unix.gettimeofday () +. remaining in
             while Unix.gettimeofday () < deadline do
               Eio.Fiber.yield ()
             done;
             Workflow_engine.Approval_deadline.remove id;
             (match htbl_get rt.workflows id with
              | Some (Wf_suspended _) ->
                publish_event rt Approval_timeout;
                htbl_set rt.workflows id (Wf_failed (Timeout));
                (match rt.services.persistence.save_workflow_state_fn id (Wf_failed Timeout) None with
                 | Ok () -> ()
                 | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
                publish_event rt (Workflow_failed { workflow_run_id = id; error = Timeout })
              | _ -> ())))
       | None -> ());
      Ok id
   | Error err ->
     htbl_set rt.workflows id (Wf_failed err);
      (match rt.services.persistence.save_workflow_state_fn id (Wf_failed err) None with
       | Ok () -> ()
       | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
      publish_event rt (Workflow_failed { workflow_run_id = id; error = err });
      Ok id)

(* §2.2: Async submit — fork execution in background fiber, return run_id
   immediately. Caller tracks progress via get_workflow_status or event bus.
   The sync [submit_workflow] above remains for backwards compat and tests. *)
let submit_workflow_async rt ?workspace ?(inputs = []) wf =
  let effective_workspace = Option.value workspace ~default:rt.workspace in
  let call_registry = per_call_registry ~rt ~workspace:effective_workspace in
  let effective_vars = wf.def.variables @ inputs in
  let id = Workflow_run_id.create () in
  htbl_set rt.workflows id Wf_running;
  publish_event rt (Workflow_started { workflow_run_id = id });
  let token = Cancellation.create_token rt.cancellation_root in
  let checkpoint_cb (completion : Workflow_engine.step_completion) =
    let step_id =
      String.concat "." (List.map string_of_int completion.Workflow_engine.path) in
    publish_event rt (Workflow_step_completed { step_id });
    let cp = Workflow_engine.make_checkpoint
               ~step_path:completion.Workflow_engine.path
               ~step_results:[completion.Workflow_engine.result]
               ~variables:completion.Workflow_engine.variables
               { Workflow_engine.variables = effective_vars;
                 token;
                 agent_resolver = (fun aid -> htbl_get rt.agents aid);
                 tool_resolver = find_tool_across_agents rt;
                 llm = rt.services.llm;
                 registry = call_registry;
                 parallel_limit = wf.def.parallel_limit;
                 failure_policy = wf.def.failure_policy;
                 workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
                 on_step_complete = None;
    workflow_run_id = Some id;
    workflow_id_resolver = (fun () -> Some wf.def.id);
    workspace = effective_workspace;
    workspace_overrides = [];
    approval_handler_overrides = [];
    per_call_registry_fn = None;
    on_approval_pending = None;
      net = rt.net;
  } in
    (match rt.services.persistence.save_workflow_state_fn id Wf_running (Some cp) with
     | Ok () -> ()
     | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)))
  in
  let ctx = {
    Workflow_engine.variables = effective_vars;
    token;
    agent_resolver = (fun aid -> htbl_get rt.agents aid);
    tool_resolver = find_tool_across_agents rt;
    llm = rt.services.llm;
    registry = call_registry;
    parallel_limit = wf.def.parallel_limit;
    failure_policy = wf.def.failure_policy;
    workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
    on_step_complete = Some checkpoint_cb;
    workflow_run_id = Some id;
    workflow_id_resolver = (fun () -> Some wf.def.id);
    workspace = effective_workspace;
    workspace_overrides = [];
    approval_handler_overrides = [];
    per_call_registry_fn = None;
    on_approval_pending = Some (parallel_approval_cb rt);
      net = rt.net;
  } in
  ignore (Eio.Fiber.fork ~sw:rt.cancellation_root (fun () ->
    (try
       (match Workflow_engine.execute_workflow ctx wf with
        | Ok result ->
          htbl_set rt.workflows id (Wf_completed result);
          (match rt.services.persistence.save_workflow_state_fn id (Wf_completed result) None with
           | Ok () -> ()
           | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
          publish_event rt (Workflow_completed { workflow_run_id = id })
        | Error err ->
          htbl_set rt.workflows id (Wf_failed err);
          (match rt.services.persistence.save_workflow_state_fn id (Wf_failed err) None with
           | Ok () -> ()
           | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
          publish_event rt (Workflow_failed { workflow_run_id = id; error = err }))
     with
     | Workflow_engine.Workflow_suspended { checkpoint = cp; prompt; allowed_roles } ->
       htbl_set rt.workflows id (Wf_suspended cp);
       (match rt.services.persistence.save_workflow_state_fn id (Wf_suspended cp) (Some cp) with
        | Ok () -> ()
        | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
       publish_event rt (Approval_requested { prompt; allowed_roles });
       (match Workflow_engine.Approval_deadline.lookup id with
        | Some deadline_entry ->
          let remaining = Workflow_engine.Approval_deadline.deadline_of deadline_entry -. Unix.gettimeofday () in
          if remaining > 0.0 then
            ignore (Eio.Fiber.fork ~sw:(Workflow_engine.Approval_deadline.switch_of deadline_entry) (fun () ->
              let deadline = Unix.gettimeofday () +. remaining in
              while Unix.gettimeofday () < deadline do
                Eio.Fiber.yield ()
              done;
              Workflow_engine.Approval_deadline.remove id;
              (match htbl_get rt.workflows id with
               | Some (Wf_suspended _) ->
                 publish_event rt Approval_timeout;
                 htbl_set rt.workflows id (Wf_failed (Timeout));
                 (match rt.services.persistence.save_workflow_state_fn id (Wf_failed Timeout) None with
                  | Ok () -> ()
                  | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
                 publish_event rt (Workflow_failed { workflow_run_id = id; error = Timeout })
               | _ -> ())))
        | None -> ())
     | exn ->
       let err = Internal (Printexc.to_string exn) in
       htbl_set rt.workflows id (Wf_failed err);
       (match rt.services.persistence.save_workflow_state_fn id (Wf_failed err) None with
        | Ok () -> ()
        | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
       publish_event rt (Workflow_failed { workflow_run_id = id; error = err }))));
  Ok id

(* §2.2: Sync convenience wrapper — calls submit_workflow (which is sync
   and blocks until terminal/suspend) then maps the run id to the
   terminal result. Returns [Some result] on completion, [None] on
   suspension, [Error] on failure. *)
let invoke_workflow_sync rt ?workspace ?inputs wf : (workflow_result option, error_category) result =
  match submit_workflow rt ?workspace ?inputs wf with
  | Error e -> (Error e : (workflow_result option, error_category) result)
  | Ok id ->
    (match htbl_get rt.workflows id with
     | Some (Wf_completed r) -> Ok (Some r)
     | Some (Wf_suspended _) -> Ok None
     | Some (Wf_failed e) -> Error e
     | Some Wf_pending -> Error (Internal "workflow state non-terminal")
     | Some Wf_running -> Error (Internal "workflow state non-terminal")
     | None -> Error (Internal "workflow state missing"))

let invoke_parallel ~rt ~specs ?(parallel_limit = 4)
    ?(failure_policy = Continue_on_failure)
    ?merge_fn ?cancellation_token () =
  if specs = [] then
    Result.Ok { successes = []; failures = []; merged = None }
  else
    let token = match cancellation_token with
      | Some t -> t
      | None -> Cancellation.create_token rt.cancellation_root
    in
    let default_workspace = rt.workspace in
    let base_registry = per_call_registry ~rt ~workspace:default_workspace in
    let base_ctx = {
      Workflow_engine.variables = [];
      token;
      agent_resolver = (fun aid -> htbl_get rt.agents aid);
      tool_resolver = find_tool_across_agents rt;
      llm = rt.services.llm;
      registry = base_registry;
      parallel_limit;
      failure_policy;
      workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
      on_step_complete = None;
      workflow_run_id = None;
      workflow_id_resolver = (fun () -> None);
      workspace = default_workspace;
      workspace_overrides = [];
      approval_handler_overrides = [];
      per_call_registry_fn = Some (fun ws -> per_call_registry ~rt ~workspace:ws);
      on_approval_pending = Some (parallel_approval_cb rt);
      net = rt.net;
    } in
    let sem = Eio.Semaphore.make parallel_limit in
    let promises = List.map (fun (spec : agent_dispatch_spec) ->
      let branch_ctx = match spec.workspace with
        | Some ws ->
          let registry = per_call_registry ~rt ~workspace:ws in
          { base_ctx with workspace = ws; registry }
        | None -> base_ctx
      in
      let branch_ctx = match spec.approval_handler with
        | Some ah ->
          let orig_resolver = branch_ctx.agent_resolver in
          { branch_ctx with
            agent_resolver = (fun aid ->
              match orig_resolver aid with
              | Some agent when agent.id = spec.agent_id ->
                Some { agent with approval_handler = Some ah }
              | other -> other)
          }
        | None -> branch_ctx
      in
      Eio.Fiber.fork_promise ~sw:token.switch (fun () ->
        Eio.Semaphore.acquire sem;
        Fun.protect
          ~finally:(fun () -> Eio.Semaphore.release sem)
          (fun () ->
            try Workflow_engine.run_agent_call ?conversation:spec.conversation
                  branch_ctx ~agent_id:spec.agent_id
                  ~prompt:(Option.value spec.input ~default:"")
            with Engine.Approval_pending pl ->
              let persist_id =
                Session_id.to_string (Session_id.create ()) in
              let stored_payload = `Assoc [
                ("persist_id", `String persist_id);
                ("runtime_run_id", `String pl.run_id);
                ("agent_id", `String pl.agent_id);
                ("tool_name", `String pl.tool_name);
                ("tool_input", pl.tool_input);
                ("conv_snapshot",
                 Types.conversation_to_yojson pl.conv_snapshot);
                ("engine_pending_payload", pl.pending_payload);
                ("expires_at", `Float pl.expires_at);
                ("created_at", `Float (Unix.gettimeofday ()));
              ] in
              (match rt.services.persistence.save_pending_approval_fn
                       ~run_id:persist_id ~agent_id:pl.agent_id
                       ~payload:stored_payload
                       ~expires_at:pl.expires_at with
               | Ok () -> ()
               | Error e ->
                 Logs.err (fun m -> m
                   "[invoke_parallel] save_pending_approval failed \
                    (agent=%s tool=%s): %s"
                   pl.agent_id pl.tool_name
                   (string_of_error_category e)));
              publish_event rt (Approval_requested {
                prompt =
                  Printf.sprintf
                    "Approval required for tool %s on agent %s"
                    pl.tool_name pl.agent_id;
                allowed_roles = [];
              });
              Result.Ok ((`Assoc [
                ("status", `String "suspended");
                ("run_id", `String persist_id);
                ("agent_id", `String pl.agent_id);
                ("tool_name", `String pl.tool_name);
                ("expires_at", `Float pl.expires_at);
              ]), pl.conv_snapshot))
      )
    ) specs in
    let results = List.map2 (fun spec promise ->
      let result : (Yojson.Safe.t * conversation, error_category) result =
        match Eio.Promise.await promise with
        | Result.Ok (Result.Ok v) -> Result.Ok v
        | Result.Ok (Result.Error e) -> Result.Error e
        | Result.Error ex -> Result.Error (Internal (Printexc.to_string ex))
      in
      (spec, result)
    ) specs promises in
    let successes = List.filter_map (fun (spec, r) ->
      match r with
      | Result.Ok (result, conversation) ->
        Some { spec; result; conversation }
      | Result.Error _ -> None
    ) results in
    let failures = List.filter_map (fun (spec, r) ->
      match r with Result.Error e -> Some (spec, e) | Result.Ok _ -> None
    ) results in
    let merged = match merge_fn with
      | Some fn -> Some (fn (List.map (fun (s : parallel_success) -> s.result) successes))
      | None -> None
    in
    match failures with
    | [] -> Result.Ok { successes; failures; merged }
    | _ ->
      (match failure_policy with
       | Fail_fast ->
         let first_err = snd (List.hd failures) in
         Result.Error first_err
       | Continue_on_failure ->
         Result.Ok { successes; failures; merged }
       | Conditional _ ->
         Result.Ok { successes; failures; merged })

let get_workflow_status rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some status -> Ok status

let cancel_workflow rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some _ ->
    let err = (Cancelled User_cancelled : error_category) in
    htbl_set rt.workflows wf_id (Wf_failed err);
    (match rt.services.persistence.save_workflow_state_fn wf_id (Wf_failed err) None with
     | Ok () -> ()
     | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
    publish_event rt (Workflow_failed { workflow_run_id = wf_id; error = err });
    Ok ()

let register_workflow rt (wf : workflow) =
  htbl_set rt.workflow_defs wf.def.id wf;
  let def_json = Types.workflow_def_to_yojson wf.def in
  (match rt.services.persistence.save_workflow_def_fn wf.def.id def_json with
   | Ok () -> ()
   | Error e -> Logs.err (fun m -> m "save_workflow_def failed for %s: %s"
                            wf.def.id (string_of_error_category e)));
  Ok ()

(* Shared by [resume_workflow] (a run that suspended for approval) and
   [recover_workflow] (a run whose writer died): re-enter at the checkpoint and
   persist the outcome. Steps after the resume point keep checkpointing, so a
   second crash is recoverable from where it stopped. *)
let run_from_checkpoint rt ~(wf_id : Workflow_run_id.t) ~(wf : workflow)
    ~(checkpoint : workflow_checkpoint) =
  let token = Cancellation.create_token rt.cancellation_root in
  let checkpoint_cb (completion : Workflow_engine.step_completion) =
    let step_id =
      String.concat "." (List.map string_of_int completion.Workflow_engine.path) in
    publish_event rt (Workflow_step_completed { step_id });
    let cp : workflow_checkpoint = {
      workflow_id = wf.def.id;
      step_path = completion.Workflow_engine.path;
      variables = completion.Workflow_engine.variables;
      step_results = [completion.Workflow_engine.result];
      allowed_roles = None;
      schema_version = 1;
    } in
    (match rt.services.persistence.save_workflow_state_fn wf_id Wf_running (Some cp) with
     | Ok () -> ()
     | Error e ->
       Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)))
  in
  let ctx = {
    Workflow_engine.variables = checkpoint.variables;
    token;
    agent_resolver = (fun aid -> htbl_get rt.agents aid);
    tool_resolver = find_tool_across_agents rt;
    llm = rt.services.llm;
    registry = rt.tool_registry;
    parallel_limit = wf.def.parallel_limit;
    failure_policy = wf.def.failure_policy;
    workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
    on_step_complete = Some checkpoint_cb;
    workflow_run_id = Some wf_id;
    workflow_id_resolver = (fun () -> Some wf.def.id);
    workspace = rt.workspace;
    workspace_overrides = [];
    approval_handler_overrides = [];
    per_call_registry_fn = None;
    on_approval_pending = None;
    net = rt.net;
  } in
  htbl_set rt.workflows wf_id Wf_running;
  (* Keep the checkpoint: if this process dies before the next step finishes,
     recovery must still have the resume point it started from. *)
  (match rt.services.persistence.save_workflow_state_fn wf_id Wf_running (Some checkpoint) with
   | Ok () -> ()
   | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
  let start_time = Unix.gettimeofday () in
  try
    (match Workflow_engine.resume_from_checkpoint ctx wf.def.steps checkpoint with
     | Ok value ->
       let elapsed = Unix.gettimeofday () -. start_time in
       let wf_result = {
         outputs = [("result", value)];
         status = `Success;
         elapsed;
         metadata = [("workflow_id", wf.def.id); ("workflow_name", wf.def.name)];
       } in
       htbl_set rt.workflows wf_id (Wf_completed wf_result);
       (match rt.services.persistence.save_workflow_state_fn wf_id (Wf_completed wf_result) None with
        | Ok () -> ()
        | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
       publish_event rt (Workflow_completed { workflow_run_id = wf_id });
       (match wf.on_complete with Some cb -> cb wf_result | None -> ());
       Ok (Some wf_result)
     | Error err ->
       htbl_set rt.workflows wf_id (Wf_failed err);
       (match rt.services.persistence.save_workflow_state_fn wf_id (Wf_failed err) None with
        | Ok () -> ()
        | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
       publish_event rt (Workflow_failed { workflow_run_id = wf_id; error = err });
       Error err)
  with
  | Workflow_engine.Workflow_suspended { checkpoint = new_cp; prompt; allowed_roles } ->
    htbl_set rt.workflows wf_id (Wf_suspended new_cp);
    (match rt.services.persistence.save_workflow_state_fn wf_id (Wf_suspended new_cp) (Some new_cp) with
     | Ok () -> ()
     | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
    publish_event rt (Approval_requested { prompt; allowed_roles });
    Ok None
  | exn ->
    let err = Internal (Printexc.to_string exn) in
    htbl_set rt.workflows wf_id (Wf_failed err);
    (match rt.services.persistence.save_workflow_state_fn wf_id (Wf_failed err) None with
     | Ok () -> ()
     | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
    publish_event rt (Workflow_failed { workflow_run_id = wf_id; error = err });
    Error err

let resume_workflow rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some (Wf_suspended checkpoint) ->
    (match htbl_get rt.workflow_defs checkpoint.workflow_id with
     | None ->
       Result.Error (Invalid_input
         (Printf.sprintf "Workflow definition '%s' not found (needed for resume)"
            checkpoint.workflow_id))
     | Some wf -> run_from_checkpoint rt ~wf_id ~wf ~checkpoint)
  | Some _ -> Result.Error (Invalid_input "Workflow is not suspended")

(** Recover a run that was interrupted: its row is still [running] because the
    process that owned it died. Nothing is resumed automatically — this is an
    explicit call, because the decision to re-run steps with side effects
    belongs to the caller. Steps after the checkpoint run again; steps before it
    do not. *)
let recover_workflow rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some Wf_running ->
    if htbl_get rt.orphaned_workflow_runs wf_id = None then
      Result.Error (Invalid_input
        ("Workflow is running in this process; recovery is only for runs whose "
         ^ "writer died and were rehydrated at startup"))
    else if htbl_get rt.recovering_workflow_runs wf_id <> None then
      Result.Error (Invalid_input "Recovery for this workflow is already in progress")
    else
    Fun.protect
      ~finally:(fun () -> htbl_remove rt.recovering_workflow_runs wf_id)
      (fun () ->
    htbl_set rt.recovering_workflow_runs wf_id ();
    match rt.services.persistence.load_workflow_state_fn wf_id with
     | Error e -> Result.Error e
     | Ok None ->
       Result.Error (Invalid_input
         (Printf.sprintf
            "Workflow %s is marked running but has no checkpoint to recover from"
            (Workflow_run_id.to_string wf_id)))
     | Ok (Some checkpoint) ->
       if checkpoint.schema_version > 1 then
         Result.Error (Invalid_input
           (Printf.sprintf
              "Checkpoint schema_version %d is newer than this runtime understands (1)"
              checkpoint.schema_version))
       else
         match htbl_get rt.workflow_defs checkpoint.workflow_id with
         | None ->
           Result.Error (Invalid_input
             (Printf.sprintf "Workflow definition '%s' not found (needed for recovery)"
                checkpoint.workflow_id))
         | Some wf -> run_from_checkpoint rt ~wf_id ~wf ~checkpoint)
  | Some (Wf_suspended _) ->
    Result.Error (Invalid_input
      "Workflow is suspended for approval; use resume_workflow")
  | Some _ -> Result.Error (Invalid_input "Workflow is not in a recoverable state")

(* -------------------------------------------------------------------------- *)
(* Durable invoke recovery (PAR-mrr)                                          *)
(* -------------------------------------------------------------------------- *)

(** Ids rehydrated at startup as orphans, paired with their agent. *)
let list_orphaned_invokes rt =
  let acc = ref [] in
  Types.htbl_iter rt.orphaned_invokes (fun id agent_id ->
    acc := (id, agent_id) :: !acc);
  List.rev !acc

(** Rebuild the workspace recorded by a checkpoint. A root that no longer
    exists is an error, not a reason to fall back to a different root: the
    recovered run would admit different paths. *)
let workspace_of_checkpoint (cp : Types.invoke_checkpoint) =
  match cp.workspace_roots with
  | None -> Ok None
  | Some roots ->
    let policy =
      match cp.workspace_sensitive_prefixes with
      | Some sensitive_prefixes -> Workspace.make_policy ~sensitive_prefixes
      | None -> Workspace.default_policy ()
    in
    (match Workspace.of_dirs ~policy roots with
     | Ok ws -> Ok (Some ws)
     | Error e ->
       Result.Error (Invalid_input
         (Printf.sprintf
            "Cannot restore the checkpointed workspace [%s]: %s"
            (String.concat ", " roots) (string_of_error_category e))))

(** Resume a durable invoke whose writer died. Mirrors [recover_workflow]:
    only startup orphans are eligible (a live invoke would run twice), the
    caller must decide, and a checkpoint from a newer schema is refused. *)
let recover_invoke rt ~invoke_id ?workspace ?system_prompt_appendix ?skills
    ?cancellation_token ?on_tool_event ?on_chunk
    ?(update_current = true) ?(save = false) () =
  let empty_conv = { Types.messages = []; metadata = [] } in
  if not (Types.htbl_claim rt.recovering_invokes invoke_id) then
    Result.Error (Invalid_input "Recovery for this invoke is already in progress", empty_conv)
  else
  Fun.protect
    ~finally:(fun () -> htbl_remove rt.recovering_invokes invoke_id)
    (fun () ->
    if htbl_get rt.active_invokes invoke_id <> None then
      Result.Error (Invalid_input
        ("Invoke is running in this process; recovery is only for runs whose writer died"),
        empty_conv)
    else
    (* Load before the orphan gate: a checkpoint written by a newer schema may
       not decode here at all, and the loader can still name that reason. It is
       safe to read a live run's row because [active_invokes] was checked
       above, and a run in another process is refused below for not being a
       startup orphan. *)
    match rt.services.persistence.load_invoke_checkpoint_fn invoke_id with
    | Error e -> Result.Error (e, empty_conv)
    | Ok None ->
      if htbl_get rt.orphaned_invokes invoke_id = None then
        Result.Error (Invalid_input
          ("Invoke was not recorded as an orphan at startup; recovery only accepts runs \
            rehydrated by Runtime.create"), empty_conv)
      else
        Result.Error (Invalid_input
          (Printf.sprintf "Invoke %s is recorded as an orphan but has no checkpoint" invoke_id),
          empty_conv)
    | Ok (Some cp) ->
      if cp.schema_version > Types.invoke_checkpoint_schema_version then
        Result.Error (Invalid_input
          (Printf.sprintf
             "Checkpoint schema_version %d is newer than this runtime understands (%d)"
             cp.schema_version Types.invoke_checkpoint_schema_version), empty_conv)
      else if htbl_get rt.orphaned_invokes invoke_id = None then
        Result.Error (Invalid_input
          ("Invoke was not recorded as an orphan at startup; recovery only accepts runs \
            rehydrated by Runtime.create"), empty_conv)
      else if (match cp.pending_approval with
               | Some pa -> pa.expires_at > Unix.gettimeofday ()
               | None -> false) then
        (* The run is waiting for a decision that is still open: the approvals
           row owns it, and re-running the batch would ask again. *)
        Result.Error (Invalid_input
          (Printf.sprintf
             "Invoke %s is waiting for an approval decision (%s on %s);               apply it with Runtime.resume_approval"
             invoke_id
             (match cp.pending_approval with
              | Some pa -> pa.tool_name
              | None -> "a tool")
             (match cp.pending_approval with
              | Some pa -> pa.agent_id
              | None -> cp.agent_id)),
          empty_conv)
      else if htbl_get rt.agents cp.agent_id = None then
        Result.Error (Invalid_input
          (Printf.sprintf "Agent '%s' is not registered (needed for recovery)" cp.agent_id),
          empty_conv)
      else
        (* An explicit argument wins; otherwise replay what the checkpoint
           recorded. A v1 row has no recorded values, so the runtime defaults
           remain the only honest choice for it. *)
        let workspace_result =
          match workspace with
          | Some _ -> Ok workspace
          | None -> workspace_of_checkpoint cp
        in
        let system_prompt_appendix =
          match system_prompt_appendix with
          | Some _ -> system_prompt_appendix
          | None -> cp.system_prompt_appendix
        in
        let skills = match skills with Some _ -> skills | None -> cp.skills in
        match workspace_result with
        | Error e -> Result.Error (e, empty_conv)
        | Ok workspace ->
          match invoke_content_internal rt ~agent_id:cp.agent_id ~content:[]
                  ?workspace ?system_prompt_appendix ?skills
                  ?cancellation_token ?on_tool_event ?on_chunk
                  ~resume:cp ~update_current ~save () with
          | Ok _ as ok ->
            (* A recovered run is no longer an orphan. Keep the entry on failure
               so a transient cause (agent not registered yet) can be fixed and
               retried. *)
            htbl_remove rt.orphaned_invokes invoke_id;
            ok
          | Error (Cancelled _, _) as e ->
            (* Cancellation is terminal: the checkpoint was removed above, so
               the orphan entry must go too. *)
            htbl_remove rt.orphaned_invokes invoke_id;
            e
          | Error _ as e -> e)

let approve_workflow rt wf_id ~approver =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some (Wf_suspended checkpoint) ->
    (* §1.2: Validate approver against checkpoint.allowed_roles *)
    (match checkpoint.allowed_roles with
     | Some roles when not (List.mem approver roles) ->
       Result.Error (Permission_denied
         (Printf.sprintf "Approver '%s' not in allowed_roles: [%s]"
            approver (String.concat "; " roles)))
     | _ ->
       (* Role check passed (or unrestricted). Publish event + cancel deadline. *)
       publish_event rt (Approval_granted { approver });
       (match Workflow_engine.Approval_deadline.lookup wf_id with
        | Some _ -> Workflow_engine.Approval_deadline.remove wf_id
        | None -> ());
       (* Trigger resume_workflow to continue execution. *)
       (match resume_workflow rt wf_id with
        | Ok _ -> Ok ()
        | Error e -> Error e))
  | Some _ -> Result.Error (Invalid_input "Workflow is not suspended")

let noop_persistence : Types.persistence_service = {
  save_events_fn = (fun ?scope:_ _events -> Ok ());
  load_events_fn = (fun _task_id -> Ok []);
  load_events_by_session_fn = (fun ?scope:_ _session_id -> Ok []);
  load_sessions_fn = (fun ?scope:_ _limit -> Ok []);
  save_task_state_fn = (fun _ts -> Ok ());
  load_task_state_fn = (fun _task_id -> Ok None);
  save_workflow_state_fn = (fun _id _status _checkpoint -> Ok ());
  load_workflow_state_fn = (fun _id -> Ok None);
  load_recoverable_runs_fn = (fun _ -> Ok []);
  save_workflow_def_fn = (fun _ _ -> Ok ());
  load_all_workflow_defs_fn = (fun _ -> Ok []);
  save_conversation_fn = (fun ?scope:_ _sid _conv -> Ok ());
  load_conversation_fn = (fun _sid -> Ok None);
  load_most_recent_conversation_fn = (fun ?scope:_ () -> Ok None);
  load_conversations_fn = (fun ?scope:_ _limit -> Ok []);
  save_pending_approval_fn = (fun ~run_id:_ ~agent_id:_ ~payload:_ ~expires_at:_ -> Ok ());
  load_pending_approval_fn = (fun ~run_id:_ -> Ok None);
  delete_pending_approval_fn = (fun ~run_id:_ -> Ok ());
  save_invoke_checkpoint_fn = (fun _cp -> Ok ());
  load_invoke_checkpoint_fn = (fun _id -> Ok None);
  list_invoke_checkpoints_fn = (fun () -> Ok []);
  delete_invoke_checkpoint_fn = (fun _id -> Ok ());
  claim_invoke_lease_fn = (fun ~invoke_id:_ ~owner:_ ~pid:_ ~ttl:_ -> Ok true);
  release_invoke_lease_fn = (fun ~invoke_id:_ ~owner:_ -> Ok ());
  list_invoke_leases_fn = (fun () -> Ok []);
  close_fn = ignore;
}

let noop_event_bus_service : Types.event_bus_service = {
  publish_fn = (fun _evt -> ());
  subscribe_fn = (fun _handler -> "");
  unsubscribe_fn = (fun _sub -> ());
  set_session_id_fn = (fun _sid -> ());
  start_dispatcher_fn = (fun _sw -> ());
}

let create ?(persistence = noop_persistence)
           ?(event_bus = noop_event_bus_service)
           ?(llm = { complete_fn = (fun _ _tools _ -> Result.Error (Internal "LLM not initialized"));
                     stream_fn = (fun _ _tools _ _ _ -> Result.Error (Internal "LLM not initialized"));
                     close_fn = ignore;
                     complete_structured_fn = None;
                     list_models_fn = None;
                     supports_native_tools_fn = None;
                     context_window_fn = None; cache_control_fn = None })
           ?embeddings
           ?memory
           ?vector_store_backend
           ?(bash_policy = (module Bash_policy.Coder : Bash_policy.POLICY))
           ?workspace
           ?(mcp_servers = [])
           ?mcp_process_mgr
           ?mcp_net
           ?mcp_clock
           ?(mcp_startup_policy = Mcp_types.Log_and_continue)
           ?net
           ~config switch =
  let validation_result = Validation.validate_runtime_config_result config in
  match validation_result with
  | Error _ as e -> e
  | Ok () ->
    let workspace = match workspace with
      | Some w -> w
      | None ->
        (match Workspace.of_cwd () with
         | Ok w -> w
         | Error e -> failwith (Printf.sprintf "Runtime.create: Workspace.of_cwd failed: %s" (string_of_error_category e)))
    in
    let semaphore = Eio.Semaphore.make config.default_quota.max_concurrent_tasks in
    let persistence_is_noop = persistence == noop_persistence in
    (* A caller-supplied bus used to be dropped entirely when persistence was
       on: [create] built an internal bus for the writer and the injected one saw
       no events at all, so orphan notifications never reached an operator. The
       two now compose: events go to both, and the caller keeps ownership of
       subscriptions and session ids. *)
    let caller_has_bus = event_bus != noop_event_bus_service in
    let (event_bus_service, persistence_writer) =
      if not persistence_is_noop then begin
        let bus = Event_bus.create default_event_bus_config in
        Event_bus.start_dispatcher bus switch;
        let overflow_fn envelope =
          Event_bus.push_to_dlq bus envelope "persistence buffer overflow"
            (Internal "persistence buffer overflow")
        in
        let writer =
          Persistence_writer.create
            ~capacity:1000
            ~flush_interval:0.05
            ~overflow_fn
            persistence.save_events_fn
        in
        Persistence_writer.start_drain_fiber writer switch;
        let _sub = Event_bus.subscribe bus (fun envelope ->
          Persistence_writer.push writer envelope
        ) in
        let internal_svc = Event_bus.to_service bus in
        let service =
          if not caller_has_bus then internal_svc
          else {
            (* Internal first: persistence must see the event even if a
               caller handler raises. *)
            publish_fn = (fun evt ->
              internal_svc.publish_fn evt;
              event_bus.publish_fn evt);
            subscribe_fn = event_bus.subscribe_fn;
            unsubscribe_fn = event_bus.unsubscribe_fn;
            set_session_id_fn = (fun sid ->
              internal_svc.set_session_id_fn sid;
              event_bus.set_session_id_fn sid);
            start_dispatcher_fn = event_bus.start_dispatcher_fn;
          }
        in
        (service, Some writer)
      end else
        (event_bus, None)
    in
    let publish_event_fn = event_bus_service.publish_fn in
    let llm_providers_registry = Provider_registry.create () in
    let _ = Provider_registry.register llm_providers_registry ~id:"default" llm in
    let vector_store = match vector_store_backend with
      | None -> None
      | Some backend ->
        (match Vector_store.create_for_backend backend with
         | Ok vs -> Some vs
         | Error e ->
           Logs.err (fun m -> m "Runtime.create: vector_store_backend init failed: %s"
                        (string_of_error_category e));
           None)
    in
    let rt = {
      agents = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
      services = {
        persistence;
        llm;
        embeddings;
        memory;
        event_bus = event_bus_service;
        config;
      };
      llm_providers = llm_providers_registry;
      cancellation_root = switch;
      task_semaphore = semaphore;
      shutdown_requested = ref false;
      shutdown_mutex = Eio.Mutex.create ();
      tasks = { data = Hashtbl.create 256; mutex = Eio.Mutex.create () };
      workflows = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
      orphaned_workflow_runs = { data = Hashtbl.create 8; mutex = Eio.Mutex.create () };
      recovering_workflow_runs = { data = Hashtbl.create 8; mutex = Eio.Mutex.create () };
      orphaned_invokes = { data = Hashtbl.create 8; mutex = Eio.Mutex.create () };
      recovering_invokes = { data = Hashtbl.create 8; mutex = Eio.Mutex.create () };
      held_leases = { data = Hashtbl.create 8; mutex = Eio.Mutex.create () };
      held_by_others = [];
      active_invokes = { data = Hashtbl.create 8; mutex = Eio.Mutex.create () };
      persistence_is_noop = persistence_is_noop;
      workflow_defs = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
      tool_registry = Tool_registry.create ();
      tool_description_overrides = [];
      skills = Skill_registry.create ();
      user_activated_skills = [];
      steering_queue = Steering_queue.create ();
      followup_queue = Steering_queue.create ();
      last_llm_call_at = None;
      last_llm_call_status = `Never_called;
      metrics = Metrics.empty ();
      tool_call_hooks = [];
      runtime_id = Session_id.to_string (Session_id.create ());
      parallel_tool_execution = config.parallel_tool_execution;
      publish_event_fn;
      bash_policy;
      bash_installed = ref false;
      bash_rebuild = None;
      file_tools_rebuild = None;
      memory_rebuild = None;
      workspace;
      mcp_servers = { data = Hashtbl.create 4; mutex = Eio.Mutex.create () };
      mcp_tools = [];
      persistence_writer;
      default_provider_id = None;
      cancel_stream_requested = ref false;
      session_id = ref None;
      current_conversation = None;
      cc_mutex = Mutex.create ();
      fallback_policy = Types.No_fallback;
      vector_store;
      net = Option.map Obj.repr net;
    } in
    (match memory with
     | Some _svc ->
       let tools = Builtin_tools.build_memory_tools memory persistence in
       rt.memory_rebuild <- Some tools;
       List.iter (fun (name, handler) ->
         Tool_registry.replace rt.tool_registry name handler) tools
     | None -> ());
     (* §2.1: Rehydrate suspended workflows AND workflow definitions from
        persistence. Without restoring workflow_defs, resume_workflow would
        fail with "Workflow definition not found" for any rehydrated run. *)
    (match rt.services.persistence.load_all_workflow_defs_fn () with
     | Ok defs ->
       List.iter (fun (_id, def_json) ->
         match Types.workflow_def_of_yojson def_json with
         | Ok def ->
           let wf : workflow = { def; on_complete = None } in
           Types.htbl_set rt.workflow_defs def.id wf
         | Error msg ->
           Logs.err (fun m -> m "Runtime.create: workflow_def decode failed: %s" msg)
       ) defs
     | Error e ->
       Logs.err (fun m -> m "Runtime.create: workflow_defs rehydration failed: %s"
                    (string_of_error_category e)));
    (match rt.services.persistence.load_recoverable_runs_fn () with
     | Ok recoverable_runs ->
       List.iter (fun (run_id, status) ->
         Types.htbl_set rt.workflows run_id status;
         (* A running row means the process that owned it is gone. Say so once;
          * recovery is an explicit call. *)
         match status with
         | Wf_running ->
           Types.htbl_set rt.orphaned_workflow_runs run_id ();
           publish_event rt (Workflow_orphaned { workflow_run_id = run_id })
         | _ -> ()
       ) recoverable_runs
     | Error e ->
       Logs.err (fun m -> m "Runtime.create: rehydration failed: %s"
                    (string_of_error_category e)));
    (* A leftover row is an orphan unless another runtime still owns it: that
       runtime is running the invoke, and recovering it would execute it
       twice. *)
    (match rt.services.persistence.list_invoke_leases_fn () with
     | Ok leases ->
       let now = Unix.gettimeofday () in
       rt.held_by_others <-
         List.fold_left
           (fun acc (l : Types.invoke_lease) ->
             if l.owner = rt.runtime_id || Invoke_lease.is_takeable ~now l then acc
             else l.invoke_id :: acc)
           [] leases
     | Error e ->
       Logs.err (fun m -> m "Runtime.create: invoke leases rehydration failed: %s"
                    (string_of_error_category e)));
    (match rt.services.persistence.list_invoke_checkpoints_fn () with
     | Ok checkpoints ->
       List.iter (fun (cp : Types.invoke_checkpoint) ->
         if List.mem cp.invoke_id rt.held_by_others then
           Logs.info (fun m ->
             m "Runtime.create: invoke %s is owned by another runtime; not an orphan"
             cp.invoke_id)
         else begin
           Types.htbl_set rt.orphaned_invokes cp.invoke_id cp.agent_id;
           publish_event rt (Invoke_orphaned {
             invoke_id = cp.invoke_id; agent_id = cp.agent_id;
           })
         end
       ) checkpoints
     | Error e ->
       Logs.err (fun m -> m "Runtime.create: invoke checkpoints rehydration failed: %s"
                    (string_of_error_category e)));
    let mcp_errors = ref [] in
    if mcp_servers <> [] then begin
      let has_stdio =
        List.exists (function Mcp_types.Stdio_server _ -> true | _ -> false)
          mcp_servers
      in
      let has_http =
        List.exists (function Mcp_types.Http_server _ -> true | _ -> false)
          mcp_servers
      in
      match (mcp_clock, has_stdio && mcp_process_mgr = None, has_http && mcp_net = None) with
      | None, _, _ ->
        Error (Invalid_input "Runtime.create: ?mcp_servers requires ?mcp_clock (pass Eio.Stdenv.clock env)")
      | _, true, _ ->
        Error (Invalid_input "Runtime.create: stdio MCP servers require ?mcp_process_mgr (pass Eio.Stdenv.process_mgr env)")
      | _, _, true ->
        Error (Invalid_input "Runtime.create: HTTP MCP servers require ?mcp_net (pass Eio.Stdenv.net env)")
      | Some clk, false, false ->
        let stop_all_spawned () =
          Types.htbl_iter rt.mcp_servers (fun _id server ->
            ignore (Mcp_server.stop server);
            publish_event rt (Mcp_server_stopped { server_id = Mcp_types.server_id_to_string (Mcp_server.id server) })
          )
        in
        let spawned : (Mcp_types.server_id * Mcp_server.t) list ref = ref [] in
        let rec loop = function
          | [] ->
            if !mcp_errors <> [] && mcp_startup_policy = Mcp_types.Fail_fast then begin
              stop_all_spawned ();
              List.hd !mcp_errors
            end else begin
              (* The servers are up, so their tools can be listed now. This is
                 the only point where every server is reachable, and it keeps
                 the descriptors and their handlers in one list. *)
              rt.mcp_tools <- Mcp_tools.entries (List.rev !spawned);
              Ok rt
            end
          | cfg :: rest ->
            match Mcp_server.spawn ~sw:switch ?process_mgr:mcp_process_mgr ?net:mcp_net ~clock:clk cfg with
            | Ok server ->
              let sid = Mcp_server.id server in
              Types.htbl_set rt.mcp_servers sid server;
              spawned := (sid, server) :: !spawned;
              publish_event rt (Mcp_server_started { server_id = Mcp_types.server_id_to_string sid; server_name = Mcp_server.name server });
              loop rest
            | Error e ->
              publish_event rt (Mcp_server_failed { server_id = Mcp_types.server_name cfg; error = e });
              mcp_errors := Error e :: !mcp_errors;
              if mcp_startup_policy = Mcp_types.Fail_fast then begin
                stop_all_spawned ();
                Error e
              end else
                loop rest
        in
        loop mcp_servers
    end else
      Ok rt

let steer rt message =
  Steering_queue.enqueue rt.steering_queue message

let follow_up rt message =
  Steering_queue.enqueue rt.followup_queue message

let drain_steering rt = Steering_queue.drain_all rt.steering_queue
let drain_followup rt = Steering_queue.drain_all rt.followup_queue
let has_pending_steering rt = Steering_queue.has_items rt.steering_queue
let has_pending_followup rt = Steering_queue.has_items rt.followup_queue

let close rt =
  Types.htbl_iter rt.mcp_servers (fun _id server ->
    match Mcp_server.stop server with
    | Ok () -> publish_event rt (Mcp_server_stopped { server_id = Mcp_types.server_id_to_string (Mcp_server.id server) })
    | Error e -> Logs.err (fun m -> m "Runtime.close: MCP server %s stop failed: %s"
                                      (Mcp_types.server_id_to_string (Mcp_server.id server))
                                      (string_of_error_category e))
  );
  Steering_queue.close rt.steering_queue;
  Steering_queue.close rt.followup_queue;
  (* A clean shutdown hands the runs back: another runtime may recover them
     right away instead of waiting for the lease to expire. *)
  (match rt.services.persistence.list_invoke_leases_fn () with
   | Ok leases ->
     List.iter (fun (l : Types.invoke_lease) ->
       if l.owner = rt.runtime_id then
         ignore (rt.services.persistence.release_invoke_lease_fn
                   ~invoke_id:l.invoke_id ~owner:rt.runtime_id))
       leases
   | Error e ->
     Logs.err (fun m -> m "Runtime.close: invoke lease release failed: %s"
                 (string_of_error_category e)));
  Eio.Mutex.use_rw ~protect:false rt.shutdown_mutex (fun () ->
    rt.shutdown_requested := true
  );
  Eio.Fiber.yield ();
  Eio.Fiber.yield ();
  (match rt.persistence_writer with
   | Some writer -> Persistence_writer.flush_sync writer
   | None -> ());
  rt.services.persistence.close_fn ();
  rt.services.llm.close_fn ();
  (match rt.services.embeddings with
   | Some svc -> svc.close_fn ()
   | None -> ());
  (match rt.services.memory with
   | Some svc -> svc.close_fn ()
   | None -> ());
  (match rt.vector_store with
   | Some vs -> Vector_store.close vs
   | None -> ());
  0

let tool_registry rt = rt.tool_registry

let bash_policy rt = rt.bash_policy

let workspace rt = rt.workspace

let memory_service rt = rt.services.Types.memory

let cancellation_root rt = rt.cancellation_root

let vector_store rt = rt.vector_store

let mcp_servers rt = rt.mcp_servers

let mcp_server rt server_id =
  match Types.htbl_get rt.mcp_servers server_id with
  | Some server -> Ok server
  | None -> Error (Invalid_input (Printf.sprintf "MCP server '%s' not found" (Mcp_types.server_id_to_string server_id)))

let register_tool_call_hook rt hook =
  rt.tool_call_hooks <- rt.tool_call_hooks @ [hook]

let clear_tool_call_hooks rt =
  rt.tool_call_hooks <- []

let run_tool_call_hooks rt ctx =
  Hook.run_chain rt.tool_call_hooks ctx

let health rt = {
  runtime_alive = not !(rt.shutdown_requested);
  last_llm_call_at = rt.last_llm_call_at;
  last_llm_call_status = rt.last_llm_call_status;
  persistence_ok =
    (match rt.services.persistence.load_task_state_fn (Task_id.create ()) with
     | Ok _ | Error _ -> true
     | exception _ -> false);
}

let metrics_snapshot rt =
  let base = Metrics.snapshot rt.metrics in
  let budget_metrics = match rt.services.config.max_tool_schema_tokens with
    | None -> []
    | Some threshold ->
      let all_agents = list_agents rt in
      let all_tools = List.concat_map (fun (a : agent_config) -> a.tools) all_agents in
      let unique_tools = List.fold_left (fun acc (d : Types.tool_descriptor) ->
        if List.exists (fun (u : Types.tool_descriptor) -> u.name = d.name) acc then acc
        else d :: acc
      ) [] all_tools in
      let estimate = Tool_budget.estimate_tokens unique_tools in
      let _registry_searchable = Tool_registry.searchable_descriptors rt.tool_registry in
      let deferred = if estimate > threshold then
        List.length (Tool_registry.searchable_descriptors rt.tool_registry)
      else 0 in
      let visible = List.length unique_tools - deferred in
      [
        ("tool_schema_tokens_estimate", estimate);
        ("tools_visible", visible);
        ("tools_deferred", deferred);
      ]
  in
  base @ budget_metrics

let cancel_stream_requested rt = rt.cancel_stream_requested

let set_session_id rt sid =
  rt.session_id := Some sid;
  rt.services.event_bus.set_session_id_fn sid

let get_session_id rt =
  match !(rt.session_id) with
  | Some sid -> sid
  | None ->
    let sid = Session_id.to_string (Session_id.create ()) in
    rt.session_id := Some sid;
    rt.services.event_bus.set_session_id_fn sid;
    sid

let get_default_provider_id rt = rt.default_provider_id

let set_default_provider rt provider_id =
  match Provider_registry.set_default rt.llm_providers ~id:provider_id with
  | Ok () -> Result.Ok ()
  | Error `Unknown _ -> Result.Error (Invalid_input (Printf.sprintf "Unknown LLM provider id: %s" provider_id))

let register_llm_provider rt id svc =
  match Provider_registry.register rt.llm_providers ~id svc with
  | Ok () -> Result.Ok ()
  | Error `Duplicate _ -> Result.Error (Internal (Printf.sprintf "Duplicate provider id: %s" id))
  | Error `Unknown _ -> Result.Error (Internal (Printf.sprintf "Unknown provider id: %s" id))

let list_llm_providers rt = Provider_registry.list_ids rt.llm_providers

let get_llm_service rt ?id () =
  match id with
  | Some i -> (
    match Provider_registry.get rt.llm_providers ~id:i with
    | Ok svc -> svc
    | Error `Unknown _ -> raise (Failure (Printf.sprintf "Unknown LLM provider id: %s" i)))
  | None -> (
    match Provider_registry.get_default rt.llm_providers with
    | Ok svc -> svc
    | Error `No_default -> raise (Failure "No default LLM provider configured"))

let list_models rt ?id () =
  let svc = get_llm_service rt ?id () in
  match svc.list_models_fn with
  | Some fn -> fn ()
  | None -> Result.Error (Internal "list_models not supported for this provider")

let set_fallback_policy rt policy = rt.fallback_policy <- policy
let get_fallback_policy rt = rt.fallback_policy

let set_user_activated_skills rt ids =
  rt.user_activated_skills <- ids

let clear_user_activated_skills rt =
  rt.user_activated_skills <- []

let get_user_activated_skills rt =
  rt.user_activated_skills
