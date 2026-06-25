open Types

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
  cancellation_root : Eio.Switch.t;
  task_semaphore : Eio.Semaphore.t;
  shutdown_requested : bool ref;
  shutdown_mutex : Eio.Mutex.t;
  tasks : (Task_id.t, task_state) protected_hashtbl;
  workflows : (Workflow_run_id.t, workflow_status) protected_hashtbl;
  workflow_defs : (string, workflow) protected_hashtbl;
  tool_registry : Tool_registry.t;
  skills : Skill_registry.t;
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
  mcp_servers : (Mcp_types.server_id, Mcp_server.t) Types.protected_hashtbl;
  event_bus_instance : Event_bus.t option;
  persistence_writer : Persistence_writer.t option;
  mutable default_provider_id : string option;
  cancel_stream_requested : bool ref;
  session_id : string option ref;
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

let make_agent ~id ?(system_prompt = "") ?(system_prompt_template = None)
    ~model ?(tools = []) ?(max_iterations = 1_000_000)
    ?(middleware = []) ?(retry_policy = None)
    ?(context_strategy = Some (Types.Sliding_window { max_messages = 100; max_tokens = 200000 })) ?(resource_quota = None)
    ?(max_execution_time = None) ?(early_stopping_method = Force) () =
  let errors = ref [] in
  if String.length id = 0 then
    errors := "id must not be empty" :: !errors;
  if String.length system_prompt = 0 && system_prompt_template = None then
    errors := "system_prompt must be non-empty or system_prompt_template must be provided" :: !errors;
  if max_iterations <= 0 then
    errors := (Printf.sprintf "max_iterations must be > 0 (got %d)" max_iterations) :: !errors;
  let tool_names = Hashtbl.create (List.length tools) in
  List.iter (fun (td : Types.tool_descriptor) ->
    if String.length td.Types.name = 0 then
      errors := "tool name must not be empty" :: !errors
    else if Hashtbl.mem tool_names td.name then
      errors := (Printf.sprintf "duplicate tool name: %s" td.name) :: !errors
    else
      Hashtbl.add tool_names td.name ()
  ) tools;
  match !errors with
  | [] -> Ok {
      id; system_prompt; system_prompt_template; model; tools;
      max_iterations; middleware; retry_policy; context_strategy; resource_quota;
      max_execution_time; early_stopping_method;
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
    ?output_schema ?(permission = Allow) ?timeout ?concurrency_limit ?(on_update = None) () =
  let descriptor = { Types.name; description; input_schema; output_schema; permission; timeout; concurrency_limit; on_update } in
  match Tool_registry.register rt.tool_registry descriptor handler with
  | Error (`Duplicate_tool n) ->
    Result.Error (Types.Invalid_input (Printf.sprintf "Tool already registered: %s" n))
  | Ok () ->
    Ok { descriptor; handler }


let register_skill rt (descriptor : Types.skill_descriptor) =
  let activate : Skill_registry.activate_fn =
    fun _rt ->
      { Types.system_prompt_override = descriptor.Types.system_prompt_override;
        tool_filter_overlay = descriptor.Types.tool_filter }
  in
  let binding = { Types.descriptor; activate } in
  match Skill_registry.register rt.skills binding with
  | Error (`Duplicate_skill id) ->
    Result.Error (Types.Invalid_input (Printf.sprintf "Skill already registered: %s" id))
  | Ok () -> Ok binding

let list_skills rt = Skill_registry.list_descriptors rt.skills

let make_skill ~id ~description ?system_prompt_override ?(tool_filter = Types.All_tools)
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
  system_prompt_override : string option;
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
  List.filter_map (fun (desc : skill_descriptor) ->
    let eligible = match desc.trigger with
      | Auto -> true
      | Manual -> false
      | Keyword { keywords; _ } ->
        List.exists (fun kw -> contains_substring message kw) keywords
    in
    if eligible then
      match Skill_registry.resolve rt.skills desc.id with
      | Some activate -> Some (activate (Obj.magic rt))
      | None -> None
    else None)
    descriptors

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
  | Some prompt -> { config with system_prompt = prompt }
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

let install_bash_tool ?process_mgr ?clock rt =
  if !(rt.bash_installed) then
    Result.Error (Types.Invalid_input "bash tool already installed")
  else
    match process_mgr with
    | None ->
      Result.Error (Types.Invalid_input
        "install_bash_tool requires ?process_mgr:\
         pass (Eio.Stdenv.process_mgr env) from the Eio environment")
    | Some mgr ->
      let module P = (val rt.bash_policy : Bash_policy.POLICY) in
      let make_handler (rt : runtime) input tok : Types.handler_result =
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
           (match Bash_safe_command.sandboxed_path_of_string cwd_str with
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
                 let cwd_for_event = Bash_safe_command.sandboxed_path_to_string cwd in
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
                       let proc =
                         Eio.Process.spawn ~sw:tok.switch mgr
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
      in
      let descriptor : Types.tool_descriptor = {
        Types.name = "bash";
        description = "Execute a shell command. Input: {\"argv\": [\"ls\", \"-la\"], \
                      \"timeout\": 30, \"cwd\": \"src\"}. \
                      Subject to Bash_policy and Bash_blacklist. \
                      Output: {\"stdout\": \"...\", \"stderr\": \"...\", \"exit_code\": 0, \
                      \"duration\": 0.12, \"truncated\": false}.";
        input_schema = `Assoc [
          ("type", `String "object");
          ("properties", `Assoc [
            ("argv", `Assoc [
              ("type", `String "array");
              ("items", `Assoc [("type", `String "string")]);
              ("description", `String "argv to execute (NOT a shell string)")]);
            ("cwd", `Assoc [
              ("type", `String "string");
              ("description", `String "CWD-relative working dir; default = .")]);
            ("timeout", `Assoc [
              ("type", `String "number");
              ("description", `String "Max seconds; default = 30");
              ("minimum", `Float 0.0)])]);
          ("required", `List [`String "argv"])];
        output_schema = None;
        permission = Types.Allow;
        timeout = Some 60.0;
        concurrency_limit = Some 4;
        on_update = None;
      }
      in
      Tool_registry.replace rt.tool_registry descriptor.name (make_handler rt);
      rt.bash_installed := true;
      Ok ()

let invoke rt ~agent_id ~message ?cancellation_token ?conversation
    ?on_tool_event ?on_chunk ?enable_handoff () =
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
    let config = apply_skill_effect_to_config composed_effect config in
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
      token config message rt.services.llm rt.tool_registry in
    match result with
    | Ok (resp, conv) ->
      record_llm_success rt;
      Result.Ok { Types.response = resp; conversation = conv }
    | Error (err, conv) ->
      record_llm_error rt err;
      Result.Error (err, conv)

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
    let result = Engine.run_structured
      ~max_repair_attempts
      ~on_before_llm:(Some on_before_llm_hook)
      ~on_after_llm:(Some on_after_llm_hook)
      ~response_schema
      ?conversation
      ?on_repair_attempt
      rt.services.llm token config message in
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

let submit_workflow rt wf =
  let id = Workflow_run_id.create () in
  htbl_set rt.workflows id Wf_running;
  let token = Cancellation.create_token rt.cancellation_root in
  let checkpoint_cb _step_id result =
    let cp = Workflow_engine.make_checkpoint ~step_path:[]
               ~step_results:[result]
               {
                 Workflow_engine.variables = wf.variables;
                 token;
                 agent_resolver = (fun aid -> htbl_get rt.agents aid);
                 tool_resolver = find_tool_across_agents rt;
                 llm = rt.services.llm;
                 registry = rt.tool_registry;
                 parallel_limit = wf.parallel_limit;
                 failure_policy = wf.failure_policy;
                 workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
                 on_step_complete = None;
                 workflow_run_id = Some id;
               }
    in
    (match rt.services.persistence.save_workflow_state_fn id Wf_running (Some cp) with
     | Ok () -> ()
     | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)))
  in
  let ctx = {
    Workflow_engine.variables = wf.variables;
    token;
    agent_resolver = (fun aid -> htbl_get rt.agents aid);
    tool_resolver = find_tool_across_agents rt;
    llm = rt.services.llm;
    registry = rt.tool_registry;
    parallel_limit = wf.parallel_limit;
    failure_policy = wf.failure_policy;
    workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
    on_step_complete = Some checkpoint_cb;
    workflow_run_id = Some id;
  } in
  (match Workflow_engine.execute_workflow ctx wf with
   | Ok result ->
     htbl_set rt.workflows id (Wf_completed result);
      (match rt.services.persistence.save_workflow_state_fn id (Wf_completed result) None with
       | Ok () -> ()
       | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
     Ok id
    | exception Workflow_engine.Workflow_suspended { checkpoint; _ } ->
      htbl_set rt.workflows id (Wf_suspended checkpoint);
      (match rt.services.persistence.save_workflow_state_fn id (Wf_suspended checkpoint) (Some checkpoint) with
        | Ok () -> ()
        | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
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
                htbl_set rt.workflows id (Wf_failed (Timeout));
                 (match rt.services.persistence.save_workflow_state_fn id (Wf_failed Timeout) None with
                  | Ok () -> ()
                  | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)))
              | _ -> ())))
       | None -> ());
      Ok id
   | Error err ->
     htbl_set rt.workflows id (Wf_failed err);
      (match rt.services.persistence.save_workflow_state_fn id (Wf_failed err) None with
       | Ok () -> ()
       | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
     Ok id)

let get_workflow_status rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some status -> Ok status

let cancel_workflow rt wf_id =
  htbl_set rt.workflows wf_id (Wf_failed (Internal "Cancelled"));
  Ok ()

let register_workflow rt (wf : workflow) =
  htbl_set rt.workflow_defs wf.id wf;
  Ok ()

let approve_workflow rt wf_id ~approver:_ =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some (Wf_suspended _) -> Ok ()
  | Some _ -> Result.Error (Invalid_input "Workflow is not suspended")

let resume_workflow rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some (Wf_suspended _) ->
     (match rt.services.persistence.load_workflow_state_fn wf_id with
      | Ok (Some loaded_cp) ->
        let token = Cancellation.create_token rt.cancellation_root in
        let vars = loaded_cp.variables in
        let ctx = {
          Workflow_engine.variables = vars;
          token;
          agent_resolver = (fun aid -> htbl_get rt.agents aid);
          tool_resolver = find_tool_across_agents rt;
          llm = rt.services.llm;
          registry = rt.tool_registry;
          parallel_limit = 10;
          failure_policy = Fail_fast;
          workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
          on_step_complete = None;
          workflow_run_id = Some wf_id;
        } in
        (match Workflow_engine.execute_workflow ctx
          { id = "resumed"; name = "resumed"; version = 1;
            steps = Tool_call { tool_name = "echo"; input = `Assoc [] };
            variables = vars; failure_policy = Fail_fast;
            parallel_limit = 10; timeout = 300.0; on_complete = None }
        with
         | Ok result ->
           htbl_set rt.workflows wf_id (Wf_completed result);
           Ok (Some result)
         | exception Workflow_engine.Workflow_suspended { checkpoint = cp; _ } ->
           htbl_set rt.workflows wf_id (Wf_suspended cp);
           Ok None
         | Error err ->
           htbl_set rt.workflows wf_id (Wf_failed err);
           Error err)
      | Ok None -> Error (Internal "No checkpoint found for suspended workflow")
      | Error e -> Error e)
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
                     complete_structured_fn = None })
           ?embeddings
           ?(bash_policy = (module Bash_policy.Coder : Bash_policy.POLICY))
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
    let rt = {
      agents = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
      services = {
        persistence;
        llm;
        embeddings;
        event_bus = event_bus_service;
        config;
      };
      cancellation_root = switch;
      task_semaphore = semaphore;
      shutdown_requested = ref false;
      shutdown_mutex = Eio.Mutex.create ();
      tasks = { data = Hashtbl.create 256; mutex = Eio.Mutex.create () };
      workflows = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
      workflow_defs = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
      tool_registry = Tool_registry.create ();
      skills = Skill_registry.create ();
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
      mcp_servers = { data = Hashtbl.create 4; mutex = Eio.Mutex.create () };
      event_bus_instance;
      persistence_writer;
      default_provider_id = None;
      cancel_stream_requested = ref false;
      session_id = ref None;
    } in
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

let set_session_id rt sid = rt.session_id := Some sid

let get_session_id rt = !(rt.session_id)

let get_default_provider_id rt = rt.default_provider_id

let set_default_provider _rt _provider_id =
  Result.Error (Internal "T0.5 stub — T6a A.1 will implement")

