open Types

module Provider_registry = Provider_registry

let string_of_error_category (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input msg -> Printf.sprintf "Invalid_input: %s" msg
  | Types.External_failure msg -> Printf.sprintf "External_failure: %s" msg
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied msg -> Printf.sprintf "Permission_denied: %s" msg
  | Types.Internal msg -> Printf.sprintf "Internal: %s" msg
  | Types.Embedding_unsupported -> "Embedding_unsupported"

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
  workflow_defs : (string, workflow) protected_hashtbl;
  tool_registry : Tool_registry.t;
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
  workspace : Workspace.workspace;
  mcp_servers : (Mcp_types.server_id, Mcp_server.t) Types.protected_hashtbl;
  event_bus_instance : Event_bus.t option;
  persistence_writer : Persistence_writer.t option;
  mutable default_provider_id : string option;
  cancel_stream_requested : bool ref;
  session_id : string option ref;
  mutable current_conversation : Types.conversation option;
  mutable fallback_policy : Types.fallback_policy;
} [@@warning "-69"]

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
    ?(context_strategy = Some (Types.Summarize { max_tokens = 8000; summary_model = None }))
    ?(resource_quota = None)
    ?(max_execution_time = None) ?(early_stopping_method = Force)
    ?(on_max_tokens = None) ?(max_continuation_chunks = None)
    ?(tool_timeout = None)
    ?(context_compression_threshold = Some 0.8)
    ?(compression_cooldown_messages = Some 6)
    ?(context_window_override = None)
    ?(cache_strategy = Types.No_caching) () =
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
    ?output_schema ?(permission = Allow) ?timeout ?concurrency_limit ?(on_update = None) ?(cache_control = None) () =
  let descriptor = { Types.name; description; input_schema; output_schema; permission; timeout; concurrency_limit; on_update; cache_control } in
  match Tool_registry.register rt.tool_registry descriptor handler with
  | Error (`Duplicate_tool n) ->
    Result.Error (Types.Invalid_input (Printf.sprintf "Tool already registered: %s" n))
  | Ok () ->
    Ok { descriptor; handler }

let register_tool_typed rt ~name ~description ~input_schema ~handler
    ?output_schema ?(permission = Allow) ?timeout ?concurrency_limit ?(on_update = None) () =
  match input_schema with
  | `Assoc _ ->
    let wrapped = Jsonschema.to_strict_object_schema input_schema in
    register_tool rt ~name ~description ~input_schema:wrapped ~handler
      ?output_schema ~permission ?timeout ?concurrency_limit ~on_update ()
  | _ ->
    Result.Error
      (Types.Internal "schema must be a JSON object")

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

let compute_active_skill_effects (rt : runtime) (message : string) : skill_effect list =
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
        match Skill_registry.resolve rt.skills desc.id with
        | Some activate -> Some (activate ())
        | None -> None
      else None)
      descriptors
  in
  let user_set = rt.user_activated_skills in
  let user_effects =
    List.filter_map (fun id ->
      if List.mem id user_set then
        match Skill_registry.resolve rt.skills id with
        | Some activate -> Some (activate ())
        | None -> None
      else None)
      (List.map (fun (d : skill_descriptor) -> d.id) descriptors)
  in
  auto_effects @ user_effects

let get_active_skill_ids (rt : runtime) (message : string) : string list =
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
  let user_set = rt.user_activated_skills in
  let user_ids =
    List.filter_map (fun id ->
      if List.mem id user_set then
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
  Metrics.incr_llm rt.metrics

let record_llm_error rt err =
  rt.last_llm_call_at <- Some (Unix.gettimeofday ());
  rt.last_llm_call_status <- `Error err;
  Metrics.incr_llm rt.metrics

let record_tool_invocation rt =
  Metrics.incr_tool_invocations rt.metrics

let record_task_completed rt =
  Metrics.incr_task_completed rt.metrics

let record_task_failed rt =
  Metrics.incr_task_failed rt.metrics

let publish_event rt evt =
  rt.publish_event_fn evt

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
    match t with Some x when x > 0.0 -> x | _ -> 30.0
  in
  (match Bash_safe_command.validate_argv argv with
   | Error e ->
     Error { category = e; message = "argv validation failed";
             retryable = false; metadata = [] }
   | Ok () ->
   (match Workspace.admit rt.workspace cwd_str with
      | Error e ->
        Error { category = e;
                message = Printf.sprintf "invalid cwd: %s" cwd_str;
                retryable = false; metadata = [] }
      | Ok cwd ->
        let cmd : Bash_safe_command.command =
          Bash_safe_command.Exec { argv; cwd; env = []; timeout }
        in
        (match P.filter cmd with
         | Error e ->
           Error { category = e; message = "policy rejected";
                   retryable = false; metadata = [] }
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
             Eio.Fiber.first
               (fun () ->
                 let stdout_buf = Buffer.create 1024 in
                 let stderr_buf = Buffer.create 1024 in
                  let proc_argv =
                    Bash_safe_command.argv_of_command filtered
                  in
                  let cwd_eio = Eio.Path.(fs / Workspace.to_string cwd) in
                  let proc =
                    Eio.Process.spawn ~sw:tok.switch mgr
                      ~cwd:cwd_eio
                      ~stdin:(Eio.Flow.string_source "")
                      ~stdout:(Eio.Flow.buffer_sink stdout_buf)
                      ~stderr:(Eio.Flow.buffer_sink stderr_buf)
                      proc_argv
                  in
                 let status = Eio.Process.await proc in
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
                  | None -> ());
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
  fresh

let register_file_tools_rebuild rt rebuild =
  rt.file_tools_rebuild <- Some rebuild

let save_conversation rt =
  match !(rt.session_id), rt.current_conversation with
  | Some sid, Some conv -> rt.services.persistence.save_conversation_fn sid conv
  | _ -> Ok ()

let load_conversation rt sid =
  match rt.services.persistence.load_conversation_fn sid with
  | Ok (Some conv) ->
    rt.session_id := Some sid;
    rt.current_conversation <- Some conv;
    (match rt.event_bus_instance with
     | Some bus -> Event_bus.set_session_id bus sid
     | None -> rt.services.event_bus.set_session_id_fn sid);
    Logs.debug (fun m -> m "Session resumed: sid=%s (%d messages)"
                   sid (List.length conv.Types.messages));
    Ok (Some conv)
  | Ok None -> Ok None
  | Error _ as e -> e

let load_most_recent_conversation rt =
  match rt.services.persistence.load_most_recent_conversation_fn () with
  | Ok (Some (sid, conv)) ->
    rt.session_id := Some sid;
    rt.current_conversation <- Some conv;
    (match rt.event_bus_instance with
     | Some bus -> Event_bus.set_session_id bus sid
     | None -> rt.services.event_bus.set_session_id_fn sid);
    Ok (Some (sid, conv))
  | Ok None -> Ok None
  | Error _ as e -> e

let invoke rt ~agent_id ~message ?workspace ?cancellation_token ?conversation
    ?on_tool_event ?on_chunk ?enable_handoff () =
  let effective_workspace = Option.value workspace ~default:rt.workspace in
  let session_id = match !(rt.session_id) with
    | Some sid -> sid
    | None ->
      let new_sid = Session_id.to_string (Session_id.create ()) in
      rt.session_id := Some new_sid;
      new_sid
  in
  (match rt.event_bus_instance with
   | Some bus -> Event_bus.set_session_id bus session_id
   | None -> rt.services.event_bus.set_session_id_fn session_id);
  let agent = htbl_get rt.agents agent_id in
  match agent with
  | None -> Result.Error (Invalid_input (Printf.sprintf "Agent not found: %s" agent_id),
                           { Types.messages = []; metadata = [] })
  | Some config ->
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
    let try_with_provider llm_svc =
      let result = Engine.run_agent ~steering:(Some rt.steering_queue)
        ~followup:(Some rt.followup_queue)
        ~runtime_id:rt.runtime_id
        ~tool_call_hooks:(Some rt.tool_call_hooks)
        ~quota:(Some rt.task_semaphore)
        ~parallel:rt.parallel_tool_execution
        ~on_progress:(Some on_tool_progress)
        ~on_tool_event:(Some combined_tool_event)
        ?on_chunk
        ?conversation
        ~agent_resolver:(fun aid -> htbl_get rt.agents aid)
        ~enable_handoff:(Option.value enable_handoff ~default:false)
        token config message llm_svc (per_call_registry ~rt ~workspace:effective_workspace) in
      result
    in
    let should_fallback (err : Types.error_category) = match err with
      | Types.Rate_limited | Types.External_failure _ | Types.Timeout -> true
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
             | Ok (resp, conv) ->
               record_llm_success rt;
               rt.current_conversation <- Some conv;
               Result.Ok { Types.response = resp; conversation = conv }
             | Error (err, _conv) when should_fallback err && rest <> [] ->
               record_llm_error rt err;
               let evt = Types.Provider_fallback_attempted {
                 from_provider = id;
                 to_provider = List.hd rest;
               } in
               (match rt.event_bus_instance with
                | Some bus -> Event_bus.publish bus evt
                | None -> rt.services.event_bus.publish_fn evt);
               try_providers rest
             | Error (err, conv) ->
               record_llm_error rt err;
               rt.current_conversation <- Some conv;
               Result.Error (err, conv)))
    in
    try_providers all_ids

let invoke_generate rt ~agent_id ~message ?max_output_tokens ?total_timeout
    ?on_tool_event ?on_chunk () =
  let session_id = match !(rt.session_id) with
    | Some sid -> sid
    | None ->
      let new_sid = Session_id.to_string (Session_id.create ()) in
      rt.session_id := Some new_sid;
      new_sid
  in
  (match rt.event_bus_instance with
   | Some bus -> Event_bus.set_session_id bus session_id
   | None -> rt.services.event_bus.set_session_id_fn session_id);
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
    match Provider_registry.get_default rt.llm_providers with
    | Error `No_default ->
      let err = Invalid_input "No default LLM provider configured." in
      record_llm_error rt err;
      Result.Error (err, { Types.messages = []; metadata = [] })
    | Ok llm_svc ->
      let result = Generate.run
        ~session_id:(Option.value !(rt.session_id) ~default:"unknown")
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
         rt.current_conversation <- Some conv;
         ignore (save_conversation rt : (unit, error_category) result);
         Result.Ok gen_result
       | Error (err, conv) ->
         record_llm_error rt err;
         rt.current_conversation <- Some conv;
         Result.Error (err, conv))

let invoke_structured rt ~agent_id ~message ~response_schema
    ?(max_repair_attempts = 3) ?cancellation_token ?conversation
    ?on_tool_event ?on_repair_attempt () =
  let session_id = Session_id.to_string (Session_id.create ()) in
  (match rt.event_bus_instance with
   | Some bus -> Event_bus.set_session_id bus session_id
   | None -> rt.services.event_bus.set_session_id_fn session_id);
  let agent = htbl_get rt.agents agent_id in
  match agent with
  | None -> Result.Error (Invalid_input (Printf.sprintf "Agent not found: %s" agent_id),
                           { Types.messages = []; metadata = [] })
  | Some config ->
    let token = match cancellation_token with
      | Some t -> t
      | None -> Cancellation.create_token rt.cancellation_root
    in
    let _ = on_tool_event in
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
       Result.Error (err, conv))

let embed rt messages =
  match rt.services.embeddings with
  | None -> Result.Error (Internal "Embeddings not initialized")
  | Some svc -> svc.embed_fn messages

let invoke_with_rag rt ~agent_id ~message ?(k = 4) ?vector_store () =
  match vector_store with
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

let find_tool_across_agents rt tool_name =
  let result = ref None in
  htbl_iter rt.agents (fun _id (agent : agent_config) ->
    if result.contents = None then
      result := List.find_opt (fun (td : tool_descriptor) -> td.name = tool_name) agent.tools
  );
  result.contents

let submit_workflow rt ?workspace ?(inputs = []) wf =
  let effective_workspace = Option.value workspace ~default:rt.workspace in
  let call_registry = per_call_registry ~rt ~workspace:effective_workspace in
  let effective_vars = wf.def.variables @ inputs in
  let id = Workflow_run_id.create () in
  htbl_set rt.workflows id Wf_running;
  publish_event rt (Workflow_started { workflow_run_id = id });
  let token = Cancellation.create_token rt.cancellation_root in
  let checkpoint_cb step_path result =
    let step_id = String.concat "." (List.map string_of_int step_path) in
    publish_event rt (Workflow_step_completed { step_id });
    let cp = Workflow_engine.make_checkpoint ~step_path
               ~step_results:[result]
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
  let checkpoint_cb step_path result =
    let step_id = String.concat "." (List.map string_of_int step_path) in
    publish_event rt (Workflow_step_completed { step_id });
    let cp = Workflow_engine.make_checkpoint ~step_path
               ~step_results:[result]
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

let get_workflow_status rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some status -> Ok status

let cancel_workflow rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some _ ->
    let err = Internal "Cancelled" in
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

let resume_workflow rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some (Wf_suspended checkpoint) ->
    (match htbl_get rt.workflow_defs checkpoint.workflow_id with
     | None ->
       Result.Error (Invalid_input
         (Printf.sprintf "Workflow definition '%s' not found (needed for resume)"
            checkpoint.workflow_id))
     | Some wf ->
       let token = Cancellation.create_token rt.cancellation_root in
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
         on_step_complete = None;
          workflow_run_id = Some wf_id;
          workflow_id_resolver = (fun () -> Some wf.def.id);
          workspace = rt.workspace;
        } in
       htbl_set rt.workflows wf_id Wf_running;
       (match rt.services.persistence.save_workflow_state_fn wf_id Wf_running None with
        | Ok () -> ()
        | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
       let start_time = Unix.gettimeofday () in
       (try
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
            Error err))
  | Some _ -> Result.Error (Invalid_input "Workflow is not suspended")

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
  save_events_fn = (fun _events -> Ok ());
  load_events_fn = (fun _task_id -> Ok []);
  load_events_by_session_fn = (fun _session_id -> Ok []);
  load_sessions_fn = (fun _limit -> Ok []);
  save_task_state_fn = (fun _ts -> Ok ());
  load_task_state_fn = (fun _task_id -> Ok None);
  save_workflow_state_fn = (fun _id _status _checkpoint -> Ok ());
  load_workflow_state_fn = (fun _id -> Ok None);
  load_all_suspended_workflows_fn = (fun _ -> Ok []);
  save_workflow_def_fn = (fun _ _ -> Ok ());
  load_all_workflow_defs_fn = (fun _ -> Ok []);
  save_conversation_fn = (fun _sid _conv -> Ok ());
  load_conversation_fn = (fun _sid -> Ok None);
  load_most_recent_conversation_fn = (fun () -> Ok None);
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
           ?(bash_policy = (module Bash_policy.Coder : Bash_policy.POLICY))
           ?workspace
           ?(mcp_servers = [])
           ?mcp_process_mgr
           ?mcp_net
           ?mcp_clock
           ?(mcp_startup_policy = Mcp_types.Log_and_continue)
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
    let (event_bus_service, event_bus_instance, persistence_writer) =
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
        (Event_bus.to_service bus, Some bus, Some writer)
      end else
        (event_bus, None, None)
    in
    let publish_event_fn = event_bus_service.publish_fn in
    let llm_providers_registry = Provider_registry.create () in
    let _ = Provider_registry.register llm_providers_registry ~id:"default" llm in
    let rt = {
      agents = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
      services = {
        persistence;
        llm;
        embeddings;
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
      workflow_defs = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
      tool_registry = Tool_registry.create ();
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
      workspace;
      mcp_servers = { data = Hashtbl.create 4; mutex = Eio.Mutex.create () };
      event_bus_instance;
      persistence_writer;
      default_provider_id = None;
      cancel_stream_requested = ref false;
      session_id = ref None;
      current_conversation = None;
      fallback_policy = Types.No_fallback;
    } in
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
    (match rt.services.persistence.load_all_suspended_workflows_fn () with
     | Ok suspended_runs ->
       List.iter (fun (run_id, status) ->
         Types.htbl_set rt.workflows run_id status
       ) suspended_runs
     | Error e ->
       Logs.err (fun m -> m "Runtime.create: rehydration failed: %s"
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
        let rec loop = function
          | [] ->
            if !mcp_errors <> [] && mcp_startup_policy = Mcp_types.Fail_fast then begin
              stop_all_spawned ();
              List.hd !mcp_errors
            end else
              Ok rt
          | cfg :: rest ->
            match Mcp_server.spawn ~sw:switch ?process_mgr:mcp_process_mgr ?net:mcp_net ~clock:clk cfg with
            | Ok server ->
              let sid = Mcp_server.id server in
              Types.htbl_set rt.mcp_servers sid server;
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
  0

let tool_registry rt = rt.tool_registry

let bash_policy rt = rt.bash_policy

let workspace rt = rt.workspace

let cancellation_root rt = rt.cancellation_root

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

let metrics_snapshot rt = Metrics.snapshot rt.metrics

let cancel_stream_requested rt = rt.cancel_stream_requested

let set_session_id rt sid =
  rt.session_id := Some sid;
  (match rt.event_bus_instance with
   | Some bus -> Event_bus.set_session_id bus sid
   | None -> rt.services.event_bus.set_session_id_fn sid)

let get_session_id rt =
  match !(rt.session_id) with
  | Some sid -> sid
  | None ->
    let sid = Session_id.to_string (Session_id.create ()) in
    rt.session_id := Some sid;
    (match rt.event_bus_instance with
     | Some bus -> Event_bus.set_session_id bus sid
     | None -> rt.services.event_bus.set_session_id_fn sid);
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

