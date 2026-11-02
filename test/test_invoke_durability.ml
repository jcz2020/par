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

(* -------------------------------------------------------------------------- *)
(* Fixtures                                                                   *)
(* -------------------------------------------------------------------------- *)

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None }

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

let seed_checkpoint ?(schema_version = 1) ~invoke_id ~agent_id sqlt =
  let cp : invoke_checkpoint = {
    invoke_id;
    agent_id;
    session_id = "sess-1";
    schema_version;
    iteration = 1;
    elapsed = 0.5;
    enable_handoff = false;
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
  seed_checkpoint ~schema_version:2 ~invoke_id:"future-1"
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
    (Runtime.list_orphaned_invokes rt)

(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "invoke durability" [
    "lifecycle", [
      Alcotest.test_case "checkpoint written in flight, cleared on success" `Quick
        test_durable_writes_then_clears_the_checkpoint;
    ];
    "recovery", [
      Alcotest.test_case "resumes from the checkpoint without re-running tools" `Quick
        test_recovery_resumes_from_the_checkpoint;
      Alcotest.test_case "newer checkpoint schema is refused" `Quick
        test_newer_schema_is_refused;
      Alcotest.test_case "a run started in this process is refused" `Quick
        test_a_live_run_is_not_recoverable;
    ];
    "guards", [
      Alcotest.test_case "durable requires a persistence backend" `Quick
        test_durable_requires_a_backend;
      Alcotest.test_case "a corrupt row does not crash startup" `Quick
        test_corrupt_row_does_not_crash_startup;
    ];
  ]
