(* test/test_invoke_durability.ml — durable agent invokes (PAR-mrr).
 *
 * A durable invoke writes a checkpoint after every completed tool batch and
 * deletes it on every terminal outcome, so a row that outlives the process
 * belongs to a dead writer. These tests pin the contract:
 *
 *   - a checkpoint exists while the run is in flight and is gone afterwards;
 *   - startup rehydrates leftover rows, announces them once on the caller's
 *     event bus, and nothing resumes automatically;
 *   - recovery continues from the checkpointed conversation without re-running
 *     the tools whose results it already holds;
 *   - a run started in this process is refused (double execution);
 *   - a newer schema is refused, and a corrupt row does not take startup down.
 *
 * No process is killed: the crash is simulated by writing the row a crash
 * would have left, then creating a fresh runtime over the same database.
 *)

open Par
open Par.Types

let error_to_string : error_category -> string = function
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid_input %S" s
  | Types.External_failure s -> Printf.sprintf "External_failure %S" s
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission_denied %S" s
  | Types.Internal s -> Printf.sprintf "Internal %S" s
  | Types.Embedding_unsupported -> "Embedding_unsupported"
  | Cancelled _ -> "cancelled"

let contains haystack needle =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length haystack
    && (String.sub haystack i n = needle || go (i + 1))
  in
  go 0

let runtime_config () : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = false;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
  max_tool_schema_tokens = None;
}

let persistence_of (sqlt : Sqlite_persistence.t) : persistence_service = {
  save_events_fn = (fun ?scope envs -> Sqlite_persistence.save_events ?scope sqlt envs);
  load_events_fn = (fun tid -> Sqlite_persistence.load_events sqlt tid);
  load_events_by_session_fn =
    (fun ?scope sid -> Sqlite_persistence.load_events_by_session ?scope sqlt sid);
  load_sessions_fn = (fun ?scope lim -> Sqlite_persistence.load_sessions ?scope sqlt lim);
  save_task_state_fn = (fun ts -> Sqlite_persistence.save_task_state sqlt ts);
  load_task_state_fn = (fun tid -> Sqlite_persistence.load_task_state sqlt tid);
  save_workflow_state_fn = (fun id st cp -> Sqlite_persistence.save_workflow_state sqlt id st cp);
  load_workflow_state_fn = (fun id -> Sqlite_persistence.load_workflow_state sqlt id);
  load_recoverable_runs_fn = (fun () -> Sqlite_persistence.load_recoverable_runs sqlt);
  save_workflow_def_fn = (fun id def -> Sqlite_persistence.save_workflow_def sqlt id def);
  load_all_workflow_defs_fn = (fun () -> Sqlite_persistence.load_all_workflow_defs sqlt);
  save_conversation_fn =
    (fun ?scope sid conv -> Sqlite_persistence.save_conversation ?scope sqlt sid conv);
  load_conversation_fn = (fun sid -> Sqlite_persistence.load_conversation sqlt sid);
  load_most_recent_conversation_fn =
    (fun ?scope () -> Sqlite_persistence.load_most_recent_conversation ?scope sqlt);
  load_conversations_fn =
    (fun ?scope limit -> Sqlite_persistence.load_conversations ?scope sqlt limit);
  save_pending_approval_fn =
    (fun ~run_id ~agent_id ~payload ~expires_at ->
       Sqlite_persistence.save_pending_approval sqlt ~run_id ~agent_id ~payload ~expires_at);
  load_pending_approval_fn =
    (fun ~run_id -> Sqlite_persistence.load_pending_approval sqlt ~run_id);
  delete_pending_approval_fn =
    (fun ~run_id -> Sqlite_persistence.delete_pending_approval sqlt ~run_id);
  save_invoke_checkpoint_fn = (fun cp -> Sqlite_persistence.save_invoke_checkpoint sqlt cp);
  load_invoke_checkpoint_fn = (fun id -> Sqlite_persistence.load_invoke_checkpoint sqlt id);
  list_invoke_checkpoints_fn = (fun () -> Sqlite_persistence.list_invoke_checkpoints sqlt);
  delete_invoke_checkpoint_fn = (fun id -> Sqlite_persistence.delete_invoke_checkpoint sqlt id);
  close_fn = (fun () -> Sqlite_persistence.close sqlt);
}

(* One database, used by a "dead" writer first and a fresh runtime second. *)
let with_sqlite f =
  let path = Filename.temp_file "par_invoke_recovery" ".db" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match Sqlite_persistence.create path with
       | Error e -> Alcotest.failf "sqlite create: %s" (error_to_string e)
       | Ok sqlt -> f sqlt (persistence_of sqlt))

let with_temp_dir f =
  let dir = Filename.temp_file "par_invoke_ws" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with Unix.Unix_error _ -> ())
    (fun () -> f dir)

(* -------------------------------------------------------------------------- *)
(* Fixtures                                                                   *)
(* -------------------------------------------------------------------------- *)

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None ; context_window = None}

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; reasoning = []; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let tool_call_response calls : llm_response =
  { text = None; reasoning = []; tool_calls = Some calls; finish_reason = Tool_calls;
    usage = dummy_usage; model = "mock" }

let mock_llm f : llm_service =
  { complete_fn = (fun _model _tools conv -> Ok (f conv));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None;
  }

let scripted_llm responses =
  let counter = ref 0 in
  mock_llm (fun _conv ->
    let idx = !counter in
    incr counter;
    match List.nth_opt responses idx with
    | Some resp -> resp
    | None -> text_response "default")

let make_agent ?(max_iterations = 3) ?(tools = []) id : agent_config = {
  id;
  system_prompt = stable_prompt "durability fixture";
  system_prompt_template = None;
  model = dummy_model;
  tools = List.map (fun (tb : tool_binding) -> tb.descriptor) tools;
  max_iterations;
  middleware = [];
  retry_policy = None;
  context_strategy = None;
  resource_quota = None;
  max_execution_time = None;
  early_stopping_method = Force;
  on_max_tokens = None;
  max_continuation_chunks = None;
  tool_timeout = None;
  context_compression_threshold = None;
  compression_cooldown_messages = None;
  context_window_override = None;
  cache_strategy = No_caching;
  approval_handler = None;
}

let system_message text : message =
  { role = System; content_blocks = Message.content_of_string text;
    tool_calls = None; tool_call_id = None; name = None }

let user_message text : message =
  { role = User; content_blocks = Message.content_of_string text;
    tool_calls = None; tool_call_id = None; name = None }

let assistant_tool_call ~id ~name : message =
  { role = Assistant; content_blocks = [];
    tool_calls = Some [{ id; name; arguments = `Assoc [] }];
    tool_call_id = None; name = None }

let tool_result_message ~id ~name text : message =
  { role = Tool; content_blocks = Message.content_of_string text;
    tool_calls = None; tool_call_id = Some id; name = Some name }

let capture_bus () =
  let events = ref [] in
  let service : event_bus_service = {
    publish_fn = (fun evt -> events := evt :: !events);
    subscribe_fn = (fun _ -> "");
    unsubscribe_fn = (fun _ -> ());
    set_session_id_fn = (fun _ -> ());
    start_dispatcher_fn = (fun _ -> ());
  } in
  (service, events)

let create_runtime ?event_bus ~persistence ~llm sw :
  (Runtime.runtime, error_category) result =
  Runtime.create ~persistence ~llm ~config:(runtime_config ())
    ?event_bus sw

(* -------------------------------------------------------------------------- *)
(* In-flight checkpoint lifecycle                                             *)
(* -------------------------------------------------------------------------- *)

(* The row must exist while the tool runs: that is what makes a crash at that
   moment recoverable. It must be gone after success, because a row that
   outlives the process is interpreted as a dead writer. *)
let test_durable_writes_then_clears_the_checkpoint () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  let seen_during_tool = ref None in
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm [
                       tool_call_response [{ id = "tc-1"; name = "echo";
                                             arguments = `Assoc [] }];
                       text_response "done";
                     ]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  let tb = match Runtime.register_tool rt ~name:"echo" ~description:"echoes"
                  ~input_schema:(`Assoc [])
                  ~handler:(fun _ _ ->
                    seen_during_tool :=
                      Sqlite_persistence.load_invoke_checkpoint sqlt "run-1"
                      |> Result.to_option |> Option.join;
                    Success (`String "A")) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt (make_agent ~tools:[tb] "durable-agent"));
  let result = Runtime.invoke rt ~agent_id:"durable-agent" ~message:"hi"
                 ~invoke_id:"run-1" () in
  (match result with
   | Ok r ->
     Alcotest.(check (option string)) "invoke_id is returned"
       (Some "run-1") r.invoke_id
   | Error (e, _) -> Alcotest.failf "invoke: %s" (error_to_string e));
  (match !seen_during_tool with
   | None -> Alcotest.fail "no checkpoint existed while the tool was running"
   | Some cp ->
     Alcotest.(check int) "iteration 0 was the checkpoint" 0 cp.iteration;
     Alcotest.(check string) "names the agent" "durable-agent" cp.agent_id);
  (match Sqlite_persistence.load_invoke_checkpoint sqlt "run-1" with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "the checkpoint survived a successful run"
   | Error e -> Alcotest.failf "load: %s" (error_to_string e))

(* The injected bus must not stay on a finished invoke's session. A runtime
   with no prior session restores the bus's explicit empty state. *)
let test_event_bus_session_is_restored_when_unset () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun _sqlt persist ->
  let sessions = ref [] in
  let bus : event_bus_service = {
    publish_fn = (fun _ -> ());
    subscribe_fn = (fun _ -> "");
    unsubscribe_fn = (fun _ -> ());
    set_session_id_fn = (fun sid -> sessions := sid :: !sessions);
    start_dispatcher_fn = (fun _ -> ());
  } in
  let rt = match create_runtime ~event_bus:bus ~persistence:persist
                   ~llm:(scripted_llm [text_response "ok"]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  ignore (Runtime.register_agent rt (make_agent "bus-agent"));
  (match Runtime.invoke rt ~agent_id:"bus-agent" ~message:"hi" () with
   | Ok _ -> ()
   | Error (e, _) -> Alcotest.failf "invoke: %s" (error_to_string e));
  match !sessions with
  | last :: _ ->
    Alcotest.(check string) "bus session restored to empty" "" last
  | [] -> Alcotest.fail "the bus session was never set"

(* The checkpoint must carry the context the run actually used. Recovery
   replays these values; a row without them silently falls back to runtime
   defaults, which is the drift schema version 2 exists to prevent. *)
let test_checkpoint_records_replay_context () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  with_temp_dir @@ fun dir ->
  let ws = match Workspace.of_dir dir with
    | Ok ws -> ws
    | Error e -> Alcotest.failf "workspace: %s" (error_to_string e)
  in
  let seen = ref None in
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm [
                       tool_call_response [{ id = "tc-1"; name = "probe";
                                             arguments = `Assoc [] }];
                       text_response "done";
                     ]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  let tb = match Runtime.register_tool rt ~name:"probe"
                  ~description:"inspects the in-flight row"
                  ~input_schema:(`Assoc [])
                  ~handler:(fun _ _ ->
                    seen := Sqlite_persistence.load_invoke_checkpoint sqlt "ctx-1"
                            |> Result.to_option |> Option.join;
                    Success (`String "ok")) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt (make_agent ~tools:[tb] "durable-agent"));
  (match Runtime.invoke rt ~agent_id:"durable-agent" ~message:"hi"
           ~invoke_id:"ctx-1" ~workspace:ws
           ~system_prompt_appendix:"APPENDIX-TEXT" ~skills:["skill-a"] () with
   | Ok _ -> ()
   | Error (e, _) -> Alcotest.failf "invoke: %s" (error_to_string e));
  match !seen with
  | None -> Alcotest.fail "no checkpoint existed while the tool was running"
  | Some cp ->
    Alcotest.(check int) "current schema"
      Types.invoke_checkpoint_schema_version cp.schema_version;
    Alcotest.(check (option (list string))) "workspace roots"
      (Some ws.Workspace.roots) cp.workspace_roots;
    Alcotest.(check (option (list string))) "workspace policy"
      (Some ws.Workspace.policy.Workspace.sensitive_prefixes)
      cp.workspace_sensitive_prefixes;
    Alcotest.(check (option string)) "appendix" (Some "APPENDIX-TEXT")
      cp.system_prompt_appendix;
    Alcotest.(check (option (list string))) "skills" (Some ["skill-a"])
      cp.skills

(* -------------------------------------------------------------------------- *)
(* Crash recovery                                                             *)
(* -------------------------------------------------------------------------- *)

let seeded_conversation () : conversation = {
  messages = [
    system_message "durability fixture";
    user_message "please echo";
    assistant_tool_call ~id:"tc-1" ~name:"echo";
    tool_result_message ~id:"tc-1" ~name:"echo" "\"A\"";
  ];
  metadata = [];
}

let seed_checkpoint ?(schema_version = 1) ?workspace_roots
    ?workspace_sensitive_prefixes ?system_prompt_appendix ?skills
    ~invoke_id ~agent_id sqlt =
  let cp : invoke_checkpoint = {
    invoke_id;
    agent_id;
    session_id = "sess-1";
    schema_version;
    iteration = 1;
    elapsed = 0.5;
    enable_handoff = false;
    tool_names = ["echo"];
    workspace_roots;
    workspace_sensitive_prefixes;
    system_prompt_appendix;
    skills;
    conversation = seeded_conversation ();
    updated_at = Unix.gettimeofday ();
  } in
  match Sqlite_persistence.save_invoke_checkpoint sqlt cp with
  | Ok () -> ()
  | Error e -> Alcotest.failf "seed: %s" (error_to_string e)

let test_recovery_resumes_from_the_checkpoint () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  seed_checkpoint ~invoke_id:"orphan-1" ~agent_id:"durable-agent" sqlt;
  let bus, events = capture_bus () in
  let tool_calls = ref [] in
  let seen_conv = ref None in
  let rt = match create_runtime ~event_bus:bus ~persistence:persist
                   ~llm:(mock_llm (fun conv ->
                       seen_conv := Some conv;
                       text_response "resumed")) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  (* The injected bus now sees runtime events, including orphan notifications,
     even though this runtime creates its own internal bus for persistence. *)
  Alcotest.(check bool) "orphan announced on the injected bus" true
    (List.exists (function
       | Invoke_orphaned { invoke_id = "orphan-1"; agent_id = "durable-agent" } -> true
       | _ -> false) !events);
  Alcotest.(check (list (pair string string))) "orphan is listed"
    ["orphan-1", "durable-agent"] (Runtime.list_orphaned_invokes rt);
  let tb = match Runtime.register_tool rt ~name:"echo" ~description:"echoes"
                  ~input_schema:(`Assoc [])
                  ~handler:(fun input _ -> tool_calls := input :: !tool_calls;
                             Success (`String "should not run")) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt (make_agent ~tools:[tb] "durable-agent"));
  (match Runtime.recover_invoke rt ~invoke_id:"orphan-1" () with
   | Ok r ->
     Alcotest.(check (option string)) "text" (Some "resumed") r.response.text;
     Alcotest.(check (option string)) "invoke_id" (Some "orphan-1") r.invoke_id
   | Error (e, _) -> Alcotest.failf "recover: %s" (error_to_string e));
  Alcotest.(check int) "the completed tool did not run again" 0
    (List.length !tool_calls);
  (match !seen_conv with
   | None -> Alcotest.fail "the model was never called"
   | Some conv ->
     let last = List.nth conv.messages (List.length conv.messages - 1) in
     Alcotest.(check bool) "the checkpointed tool result is in context" true
       (last.role = Tool && contains (Message.text_of_message last) "A");
     Alcotest.(check int) "the whole conversation was replayed" 4
       (List.length conv.messages));
  (match Sqlite_persistence.load_invoke_checkpoint sqlt "orphan-1" with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "the checkpoint survived recovery"
   | Error e -> Alcotest.failf "load: %s" (error_to_string e));
  Alcotest.(check (list (pair string string))) "the orphan is cleared after recovery" []
    (Runtime.list_orphaned_invokes rt)

let test_newer_schema_is_refused () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  seed_checkpoint ~schema_version:3 ~invoke_id:"future-1"
    ~agent_id:"durable-agent" sqlt;
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm []) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  ignore (Runtime.register_agent rt (make_agent "durable-agent"));
  match Runtime.recover_invoke rt ~invoke_id:"future-1" () with
  | Ok _ -> Alcotest.fail "a newer checkpoint schema must be refused"
  | Error (Invalid_input msg, _) ->
    Alcotest.(check bool) "explains the version" true (contains msg "schema_version")
  | Error (e, _) -> Alcotest.failf "expected Invalid_input, got %s" (error_to_string e)

(* Recovery must re-enter with the workspace, appendix and skill snapshot the
   checkpoint recorded, not with whatever the fresh runtime happens to hold. *)
let test_recovery_replays_workspace_appendix_and_skills () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  with_temp_dir @@ fun dir ->
  let ws = match Workspace.of_dir dir with
    | Ok ws -> ws
    | Error e -> Alcotest.failf "workspace: %s" (error_to_string e)
  in
  seed_checkpoint ~schema_version:Types.invoke_checkpoint_schema_version
    ~workspace_roots:ws.Workspace.roots
    ~workspace_sensitive_prefixes:ws.Workspace.policy.Workspace.sensitive_prefixes
    ~system_prompt_appendix:"APP" ~skills:["skill-a"]
    ~invoke_id:"ctx-2" ~agent_id:"durable-agent" sqlt;
  let seen_ctx = ref None in
  let llm_called = ref false in
  let rebuilt_ws = ref None in
  let rt = match create_runtime ~persistence:persist
                   ~llm:(mock_llm (fun _conv ->
                       llm_called := true;
                       seen_ctx := Invoke_context.get_current ();
                       text_response "resumed")) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  ignore (Runtime.register_agent rt (make_agent "durable-agent"));
  Runtime.register_file_tools_rebuild rt (fun ws ->
    rebuilt_ws := Some ws.Workspace.roots;
    []);
  (match Runtime.recover_invoke rt ~invoke_id:"ctx-2" () with
   | Ok _ -> ()
   | Error (e, _) -> Alcotest.failf "recover: %s" (error_to_string e));
  Alcotest.(check (option (list string)))
    "the per-call registry received the checkpointed workspace"
    (Some ws.Workspace.roots) !rebuilt_ws;
  (if not !llm_called then Alcotest.fail "the model was not called");
  match !seen_ctx with
  | None -> Alcotest.fail "the model ran outside an invoke context"
  | Some ctx ->
    Alcotest.(check (option string)) "appendix replayed" (Some "APP")
      ctx.Invoke_context.system_prompt_appendix;
    Alcotest.(check (list string)) "skills replayed" ["skill-a"]
      ctx.Invoke_context.user_activated_skills_snapshot

(* A recorded root that no longer exists must fail closed. Falling back to the
   runtime default would admit a different set of paths than the crashed run. *)
let test_recovery_refuses_a_missing_workspace_root () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  let missing = Filename.temp_file "par_missing_ws" "" in
  Sys.remove missing;
  seed_checkpoint ~schema_version:Types.invoke_checkpoint_schema_version
    ~workspace_roots:[missing] ~invoke_id:"ctx-3" ~agent_id:"durable-agent" sqlt;
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm [text_response "unused"]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  ignore (Runtime.register_agent rt (make_agent "durable-agent"));
  match Runtime.recover_invoke rt ~invoke_id:"ctx-3" () with
  | Ok _ -> Alcotest.fail "a missing workspace root must refuse recovery"
  | Error (Invalid_input msg, _) ->
    Alcotest.(check bool) "names the workspace" true
      (contains msg "Cannot restore the checkpointed workspace")
  | Error (e, _) -> Alcotest.failf "expected Invalid_input, got %s" (error_to_string e)

(* A run created by this process is live, not an orphan. Recovering it would
   execute the same tools twice; the in-flight guard is what prevents that. *)
let test_a_live_run_is_not_recoverable () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun _sqlt persist ->
  let started = ref false in
  let release = ref false in
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm [
                       tool_call_response [{ id = "tc-1"; name = "gate";
                                             arguments = `Assoc [] }];
                       text_response "done";
                     ]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  let tb = match Runtime.register_tool rt ~name:"gate" ~description:"waits"
                  ~input_schema:(`Assoc [])
                  ~handler:(fun _ _ ->
                    started := true;
                    while not !release do Eio.Fiber.yield () done;
                    Success (`String "released")) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt (make_agent ~tools:[tb] "durable-agent"));
  let handle = Runtime.invoke_async rt ~agent_id:"durable-agent"
                 ~message:"hi" ~invoke_id:"live-1" () in
  while not !started do Eio.Fiber.yield () done;
  (match Runtime.recover_invoke rt ~invoke_id:"live-1" () with
   | Ok _ -> Alcotest.fail "a live run must not be recovered"
   | Error (Invalid_input _, _) -> ()
   | Error (e, _) -> Alcotest.failf "expected Invalid_input, got %s"
                       (error_to_string e));
  release := true;
  (match Invoke_context.invoke_handle_await handle with
   | Ok _ -> ()
   | Error (e, _) -> Alcotest.failf "async invoke: %s" (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Cross-subsystem: handoff, concurrency, cancellation, approvals             *)
(* -------------------------------------------------------------------------- *)

(* A handoff moves the loop to the target agent. The checkpoint must record the
   agent that will actually continue the run: recovering as the origin would
   hand the resumed loop the origin's tool set while the conversation carries
   the target's system prompt. *)
let test_handoff_checkpoint_records_the_active_agent () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  let seen_checkpoint = ref None in
  let target_calls = ref 0 in
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm [
                       tool_call_response [{ id = "tc-1"; name = "delegate";
                                             arguments = `Assoc [] }];
                       tool_call_response [{ id = "tc-2"; name = "target_tool";
                                             arguments = `Assoc [] }];
                       (* A second target batch: the checkpoint written after
                          the first one is what the second call can observe. *)
                       tool_call_response [{ id = "tc-3"; name = "target_tool";
                                             arguments = `Assoc [] }];
                       text_response "done";
                     ]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  let delegate = match Runtime.register_tool rt ~name:"delegate"
                   ~description:"hands off" ~input_schema:(`Assoc [])
                   ~handler:(fun _ _ ->
                     Handoff { target_agent_id = "target"; carry_context = true;
                               task = None }) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool delegate: %s" (error_to_string e)
  in
  let target_tool = match Runtime.register_tool rt ~name:"target_tool"
                       ~description:"target only" ~input_schema:(`Assoc [])
                       ~handler:(fun _ _ ->
                         incr target_calls;
                         if !target_calls = 2 then
                           seen_checkpoint :=
                             (match Sqlite_persistence.load_invoke_checkpoint sqlt "handoff-1" with
                              | Ok cp -> cp
                              | Error _ -> None);
                         Success (`String "target done")) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool target_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt (make_agent ~max_iterations:5 ~tools:[delegate] "origin"));
  ignore (Runtime.register_agent rt (make_agent ~max_iterations:5 ~tools:[target_tool] "target"));
  (match Runtime.invoke rt ~agent_id:"origin" ~message:"go" ~invoke_id:"handoff-1"
          ~enable_handoff:true () with
   | Ok _ -> ()
   | Error (e, _) -> Alcotest.failf "invoke: %s" (error_to_string e));
  (match !seen_checkpoint with
   | None -> Alcotest.fail "checkpoint was not observed"
   | Some cp ->
     Alcotest.(check string) "the checkpoint names the target agent"
       "target" cp.agent_id;
     Alcotest.(check (list string)) "the checkpoint names the target's tools"
       ["target_tool"] cp.tool_names)

(* Two fibers racing for the same id must not both run. The claim is a single
   critical section; before that, the check and the registration were separate
   and a yield between them let both through. *)
let test_duplicate_invoke_id_is_refused () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun _sqlt persist ->
  let started = ref false in
  let release = ref false in
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm [
                       tool_call_response [{ id = "tc-1"; name = "gate";
                                             arguments = `Assoc [] }];
                       text_response "done";
                     ]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  let gate = match Runtime.register_tool rt ~name:"gate" ~description:"blocks"
               ~input_schema:(`Assoc [])
               ~handler:(fun _ _ ->
                 started := true;
                 while not !release do Eio.Fiber.yield () done;
                 Success (`String "released")) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt (make_agent ~tools:[gate] "dup-agent"));
  let handle = Runtime.invoke_async rt ~agent_id:"dup-agent" ~message:"hi"
                 ~invoke_id:"dup-1" () in
  while not !started do Eio.Fiber.yield () done;
  (match Runtime.invoke rt ~agent_id:"dup-agent" ~message:"hi"
          ~invoke_id:"dup-1" () with
   | Ok _ -> Alcotest.fail "a second run with the same id must be refused"
   | Error (Invalid_input msg, _) ->
     Alcotest.(check bool) "explains the collision" true (contains msg "already in flight")
   | Error (e, _) -> Alcotest.failf "expected Invalid_input, got %s" (error_to_string e));
  release := true;
  (match Invoke_context.invoke_handle_await handle with
   | Ok _ -> ()
   | Error (e, _) -> Alcotest.failf "first run: %s" (error_to_string e))

(* Re-using an orphan's id used to overwrite its checkpoint silently. Recovery
   is explicit; a retry with the same business key must be told so. *)
let test_orphan_id_cannot_be_reused () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  seed_checkpoint ~invoke_id:"orphan-2" ~agent_id:"durable-agent" sqlt;
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm [text_response "unused"]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  ignore (Runtime.register_agent rt (make_agent "durable-agent"));
  (match Runtime.invoke rt ~agent_id:"durable-agent" ~message:"again"
          ~invoke_id:"orphan-2" () with
   | Ok _ -> Alcotest.fail "an orphan id must not be reused for a fresh run"
   | Error (Invalid_input msg, _) ->
     Alcotest.(check bool) "points at recovery" true (contains msg "recover_invoke")
   | Error (e, _) -> Alcotest.failf "expected Invalid_input, got %s" (error_to_string e));
  (match Sqlite_persistence.load_invoke_checkpoint sqlt "orphan-2" with
   | Ok (Some cp) -> Alcotest.(check int) "the orphan checkpoint is intact" 1 cp.iteration
   | Ok None -> Alcotest.fail "the orphan checkpoint was deleted"
   | Error e -> Alcotest.failf "load: %s" (error_to_string e))

let test_failed_run_removes_the_checkpoint () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  let calls = ref 0 in
  let llm : llm_service = {
    complete_fn = (fun _model _tools _conv ->
      let n = !calls in
      incr calls;
      if n = 0 then
        Ok (tool_call_response [{ id = "tc-1"; name = "echo"; arguments = `Assoc [] }])
      else Error (Internal "provider down"));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None;
  } in
  let rt = match create_runtime ~persistence:persist ~llm sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  let echo = match Runtime.register_tool rt ~name:"echo" ~description:"echoes"
               ~input_schema:(`Assoc [])
               ~handler:(fun _ _ -> Success (`String "A")) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt (make_agent ~tools:[echo] "durable-agent"));
  (match Runtime.invoke rt ~agent_id:"durable-agent" ~message:"hi"
          ~invoke_id:"fail-1" () with
   | Ok _ -> Alcotest.fail "expected the provider failure to surface"
   | Error _ -> ());
  (match Sqlite_persistence.load_invoke_checkpoint sqlt "fail-1" with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "a failed run left its checkpoint behind"
   | Error e -> Alcotest.failf "load: %s" (error_to_string e))

let test_failed_recovery_keeps_the_checkpoint () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  seed_checkpoint ~invoke_id:"recover-fail" ~agent_id:"durable-agent" sqlt;
  let llm : llm_service = {
    complete_fn = (fun _ _ _ -> Error (Internal "provider down"));
    stream_fn = (fun _ _ _ _ _ -> Error (Internal "provider down"));
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None;
  } in
  let rt = match create_runtime ~persistence:persist ~llm sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  let echo = match Runtime.register_tool rt ~name:"echo" ~description:"echoes"
               ~input_schema:(`Assoc [])
               ~handler:(fun _ _ -> Success (`String "A")) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt (make_agent ~tools:[echo] "durable-agent"));
  (match Runtime.recover_invoke rt ~invoke_id:"recover-fail" () with
   | Ok _ -> Alcotest.fail "expected recovery to fail"
   | Error _ -> ());
  (match Sqlite_persistence.load_invoke_checkpoint sqlt "recover-fail" with
   | Ok (Some cp) ->
     Alcotest.(check int) "checkpoint kept for retry" 1 cp.iteration
   | Ok None -> Alcotest.fail "a failed recovery deleted the checkpoint"
   | Error e -> Alcotest.failf "load: %s" (error_to_string e))

(* The approvals row owns a suspended run, so the durable row is removed. The
   approvals row has a TTL (300s by default); the SDK docs state that a
   suspended run is not covered by durable recovery. *)
let test_approval_suspension_removes_the_checkpoint () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm [
                       tool_call_response [{ id = "tc-1"; name = "needs_approval";
                                             arguments = `Assoc [] }];
                     ]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  let approval_tool = match Runtime.register_tool rt ~name:"needs_approval"
                        ~description:"asks" ~input_schema:(`Assoc [])
                        ~handler:(fun _ _ ->
                          Approval_required {
                            tool_name = "needs_approval"; tool_input = `Assoc [];
                            prompt = "ok?"; timeout = None; allowed_roles = [];
                          }) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  let agent = { (make_agent ~tools:[approval_tool] "approval-agent") with
                approval_handler =
                  Some (Approval.Async_callback (fun _ -> failwith "not awaited")) } in
  ignore (Runtime.register_agent rt agent);
  (match Runtime.invoke rt ~agent_id:"approval-agent" ~message:"hi"
          ~invoke_id:"approve-1" () with
   | Ok r ->
     Alcotest.(check bool) "the invoke suspended" true (r.approval_pending <> None)
   | Error (e, _) -> Alcotest.failf "invoke: %s" (error_to_string e));
  (match Sqlite_persistence.load_invoke_checkpoint sqlt "approve-1" with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "a suspended run must not keep the durable row"
   | Error e -> Alcotest.failf "load: %s" (error_to_string e))

(* Cancellation is an intentional stop, so the row must not survive as a
   pseudo-crash. Whether the cancellation unwinds by exception or is converted
   by the engine, the checkpoint is gone afterwards. *)
let test_cancelled_invoke_removes_the_checkpoint () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  let token = Cancellation.create_token sw in
  let llm : llm_service = {
    complete_fn = (fun _model _tools _conv ->
      raise (Eio.Cancel.Cancelled (Failure "cancelled")));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None;
  } in
  let rt = match create_runtime ~persistence:persist ~llm sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  ignore (Runtime.register_agent rt (make_agent "cancel-agent"));
  (match
     try Some (Runtime.invoke rt ~agent_id:"cancel-agent" ~message:"hi"
                 ~cancellation_token:token ~invoke_id:"cancel-1" ())
     with Eio.Cancel.Cancelled _ -> None
   with
   | None -> ()
   | Some (Error _) -> ()
   | Some (Ok _) -> Alcotest.fail "expected the cancellation to surface");
  (match Sqlite_persistence.load_invoke_checkpoint sqlt "cancel-1" with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "a cancelled run left an orphan row behind"
   | Error e -> Alcotest.failf "load: %s" (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Guards and resilience                                                      *)
(* -------------------------------------------------------------------------- *)

let test_durable_requires_a_backend () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let rt = match Runtime.create ~config:(runtime_config ())
                   ~llm:(scripted_llm [text_response "unused"]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  ignore (Runtime.register_agent rt (make_agent "durable-agent"));
  match Runtime.invoke rt ~agent_id:"durable-agent" ~message:"hi"
          ~durable:true () with
  | Ok _ -> Alcotest.fail "durable without persistence must be rejected"
  | Error (Invalid_input msg, _) ->
    Alcotest.(check bool) "names the missing backend" true
      (contains msg "persistence backend")
  | Error (e, _) -> Alcotest.failf "expected Invalid_input, got %s" (error_to_string e)

(* A newer writer may change a shape this runtime cannot decode. The row must
   survive startup (the newer runtime still owns it) and recovery must say the
   schema is newer rather than claiming the row is missing. *)
let test_newer_schema_undecodable_row_is_preserved () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  let db = Sqlite_persistence.raw_sqlite3_db sqlt in
  let state_json =
    {|{"invoke_id":"future-2","agent_id":"durable-agent","session_id":"sess-1",|} ^
    {|"schema_version":3,"iteration":1,"elapsed":0.5,"enable_handoff":false,|} ^
    {|"tool_names":[],"conversation":{"messages":"not-a-list","metadata":[]},|} ^
    {|"updated_at":1.0}|}
  in
  let sql =
    Printf.sprintf
      "INSERT INTO invoke_checkpoints (invoke_id, state_json, updated_at) \
       VALUES ('future-2', '%s', 1.0)" state_json
  in
  (match Sqlite3.exec db sql with
   | Sqlite3.Rc.OK -> ()
   | rc -> Alcotest.failf "seed newer row: %s" (Sqlite3.Rc.to_string rc));
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm []) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  ignore (Runtime.register_agent rt (make_agent "durable-agent"));
  Alcotest.(check (list (pair string string))) "not offered as a v1 orphan" []
    (Runtime.list_orphaned_invokes rt);
  (match Sqlite_persistence.load_invoke_checkpoint sqlt "future-2" with
   | Ok None -> Alcotest.fail "the newer-schema row was deleted at startup"
   | Ok (Some _) -> Alcotest.fail "a shape-incompatible v2 row was decoded as v1"
   | Error (Invalid_input msg) ->
     Alcotest.(check bool) "names the schema version" true
       (contains msg "schema_version")
   | Error e -> Alcotest.failf "expected Invalid_input, got %s" (error_to_string e));
  match Runtime.recover_invoke rt ~invoke_id:"future-2" () with
  | Ok _ -> Alcotest.fail "a newer checkpoint schema must be refused"
  | Error (Invalid_input msg, _) ->
    Alcotest.(check bool) "explains the version" true (contains msg "schema_version")
  | Error (e, _) -> Alcotest.failf "expected Invalid_input, got %s" (error_to_string e)

(* A corrupt row must not take startup down (the v0.14 lesson), and it must not
   be reported as recoverable either. *)
let test_corrupt_row_does_not_crash_startup () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_sqlite @@ fun sqlt persist ->
  let db = Sqlite_persistence.raw_sqlite3_db sqlt in
  (match Sqlite3.exec db
           "INSERT INTO invoke_checkpoints (invoke_id, state_json, updated_at) \
            VALUES ('corrupt-1', '{not json', 1.0)" with
   | Sqlite3.Rc.OK -> ()
   | rc -> Alcotest.failf "seed corrupt row: %s" (Sqlite3.Rc.to_string rc));
  let rt = match create_runtime ~persistence:persist
                   ~llm:(scripted_llm []) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  Alcotest.(check (list (pair string string))) "nothing recoverable" []
    (Runtime.list_orphaned_invokes rt);
  (match Sqlite_persistence.load_invoke_checkpoint sqlt "corrupt-1" with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "the undecodable row was not dropped"
   | Error e -> Alcotest.failf "load: %s" (error_to_string e))

(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "invoke durability" [
    "lifecycle", [
      Alcotest.test_case "checkpoint written in flight, cleared on success" `Quick
        test_durable_writes_then_clears_the_checkpoint;
      Alcotest.test_case "checkpoint records the replay context" `Quick
        test_checkpoint_records_replay_context;
      Alcotest.test_case "event bus session is restored when the runtime had none" `Quick
        test_event_bus_session_is_restored_when_unset;
    ];
    "recovery", [
      Alcotest.test_case "resumes from the checkpoint without re-running tools" `Quick
        test_recovery_resumes_from_the_checkpoint;
      Alcotest.test_case "newer checkpoint schema is refused" `Quick
        test_newer_schema_is_refused;
      Alcotest.test_case "newer undecodable row is preserved and refused" `Quick
        test_newer_schema_undecodable_row_is_preserved;
      Alcotest.test_case "replays workspace, appendix and skills" `Quick
        test_recovery_replays_workspace_appendix_and_skills;
      Alcotest.test_case "a missing workspace root fails closed" `Quick
        test_recovery_refuses_a_missing_workspace_root;
      Alcotest.test_case "a run started in this process is refused" `Quick
        test_a_live_run_is_not_recoverable;
      Alcotest.test_case "an orphan id cannot be reused" `Quick
        test_orphan_id_cannot_be_reused;
    ];
    "cross-subsystem", [
      Alcotest.test_case "a handoff checkpoint names the active agent" `Quick
        test_handoff_checkpoint_records_the_active_agent;
      Alcotest.test_case "a duplicate invoke id is refused" `Quick
        test_duplicate_invoke_id_is_refused;
      Alcotest.test_case "a failed run removes its checkpoint" `Quick
        test_failed_run_removes_the_checkpoint;
      Alcotest.test_case "a failed recovery keeps its checkpoint" `Quick
        test_failed_recovery_keeps_the_checkpoint;
      Alcotest.test_case "an approval suspension removes it" `Quick
        test_approval_suspension_removes_the_checkpoint;
      Alcotest.test_case "a cancelled run removes it" `Quick
        test_cancelled_invoke_removes_the_checkpoint;
    ];
    "guards", [
      Alcotest.test_case "durable requires a persistence backend" `Quick
        test_durable_requires_a_backend;
      Alcotest.test_case "a corrupt row does not crash startup" `Quick
        test_corrupt_row_does_not_crash_startup;
    ];
  ]
