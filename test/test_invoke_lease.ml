(* test/test_invoke_lease.ml — two runtimes over one database (PAR-53d).
 *
 * Without ownership, each runtime sees the other's in-flight run as a
 * leftover row and recovers it, which executes the same tools twice. A lease
 * says who is running the run:
 *
 *   - a live holder keeps it, so the row is not offered for recovery;
 *   - a holder whose process is gone releases it, so a crashed run is
 *     recoverable at once.
 *)

open Par
open Par.Types

let error_to_string : error_category -> string = function
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid_input %S" s
  | Types.External_failure s -> Printf.sprintf "External_failure %S" s
  | Types.Permission_denied s -> Printf.sprintf "Permission_denied %S" s
  | Types.Internal s -> Printf.sprintf "Internal %S" s
  | Types.Rate_limited -> "Rate_limited"
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
  claim_invoke_lease_fn =
    (fun ~invoke_id ~owner ~pid ~ttl ->
       Sqlite_persistence.claim_invoke_lease sqlt ~invoke_id ~owner ~pid ~ttl);
  release_invoke_lease_fn =
    (fun ~invoke_id ~owner -> Sqlite_persistence.release_invoke_lease sqlt ~invoke_id ~owner);
  list_invoke_leases_fn = (fun () -> Sqlite_persistence.list_invoke_leases sqlt);
  close_fn = (fun () -> Sqlite_persistence.close sqlt);
}

(* Two handles on one file: the two runtimes are separate owners, like two
   processes would be. *)
let with_two_runtimes f =
  let path = Filename.temp_file "par_invoke_lease" ".db" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match Sqlite_persistence.create path with
       | Error e -> Alcotest.failf "sqlite create: %s" (error_to_string e)
       | Ok a ->
         (match Sqlite_persistence.create path with
          | Error e -> Alcotest.failf "sqlite create (second): %s" (error_to_string e)
          | Ok b -> f path a b))

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None; context_window = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }

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
    context_window_fn = None;
    cache_control_fn = None;
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
  system_prompt = stable_prompt "lease fixture";
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

let create_runtime ~persistence ~llm sw =
  Runtime.create ~persistence ~llm ~config:(runtime_config ()) sw

(* A run that is still in flight belongs to the runtime that started it: the
   other runtime must not offer it for recovery. *)
let test_a_live_run_is_not_an_orphan_for_another_runtime () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_two_runtimes @@ fun _path a b ->
  let started, started_u = Eio.Promise.create () in
  let release, release_u = Eio.Promise.create () in
  let rt_a = match create_runtime ~persistence:(persistence_of a)
                      ~llm:(scripted_llm [
                          tool_call_response [{ id = "tc-1"; name = "gate";
                                                arguments = `Assoc [] }];
                          text_response "done";
                        ]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create A: %s" (error_to_string e)
  in
  let rt_b = match create_runtime ~persistence:(persistence_of b)
                      ~llm:(scripted_llm []) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create B: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt_b)) @@ fun () ->
  let tb = match Runtime.register_tool rt_a ~name:"gate" ~description:"waits"
                  ~input_schema:(`Assoc [])
                  ~handler:(fun _ _ ->
                    Eio.Promise.resolve started_u ();
                    Eio.Promise.await release;
                    Success (`String "ok")) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt_a (make_agent ~tools:[tb] "leased-agent"));
  let invoker =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Runtime.invoke rt_a ~agent_id:"leased-agent" ~message:"hi"
        ~invoke_id:"leased-1" ())
  in
  Eio.Promise.await started;
  (* The row is there: the run is in flight and checkpointed. *)
  (match Sqlite_persistence.load_invoke_checkpoint a "leased-1" with
   | Ok (Some _) -> ()
   | Ok None -> Alcotest.fail "the in-flight run left no checkpoint"
   | Error e -> Alcotest.failf "load: %s" (error_to_string e));
  (* B starts after A: the row belongs to a live runtime, so it is not an
     orphan and cannot be recovered. *)
  let b2 = match Sqlite_persistence.create _path with
    | Ok h -> h
    | Error e -> Alcotest.failf "sqlite create (third): %s" (error_to_string e)
  in
  let rt_b2 = match create_runtime ~persistence:(persistence_of b2)
                       ~llm:(scripted_llm []) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create B2: %s" (error_to_string e)
  in
  Alcotest.(check (list (pair string string))) "not offered as an orphan" []
    (Runtime.list_orphaned_invokes rt_b2);
  (match Runtime.recover_invoke rt_b2 ~invoke_id:"leased-1" () with
   | Ok _ -> Alcotest.fail "a live run must not be recoverable by another runtime"
   | Error (Invalid_input msg, _) ->
     Alcotest.(check bool) "explains the ownership" true
       (contains msg "owned by another runtime" || contains msg "not recorded as an orphan")
   | Error (e, _) -> Alcotest.failf "expected Invalid_input, got %s" (error_to_string e));
  ignore (Runtime.close rt_b2);
  Eio.Promise.resolve release_u ();
  ignore (Eio.Promise.await invoker);
  ignore (Runtime.close rt_a)

(* A holder whose process is gone releases the lease: the run is a leftover
   row again and recovery works. *)
let test_a_dead_holder_releases_the_lease () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_two_runtimes @@ fun _path a b ->
  (* A checkpoint left behind by a run that is no longer in flight. *)
  (match Sqlite_persistence.save_invoke_checkpoint a {
       invoke_id = "dead-1"; agent_id = "leased-agent"; session_id = "sess-1";
       schema_version = Types.invoke_checkpoint_schema_version;
       iteration = 0; elapsed = 0.0; enable_handoff = false; tool_names = [];
       workspace_roots = None; workspace_sensitive_prefixes = None;
       system_prompt_appendix = None; skills = None;
       conversation = { messages = []; metadata = [] };
       updated_at = Unix.gettimeofday ();
     } with
   | Ok () -> ()
   | Error e -> Alcotest.failf "seed checkpoint: %s" (error_to_string e));
  (* The holder is gone: its pid is not running. *)
  (match Sqlite_persistence.claim_invoke_lease a ~invoke_id:"dead-1"
          ~owner:"dead-runtime" ~pid:999999999 ~ttl:300.0 with
   | Ok true -> ()
   | Ok false -> Alcotest.fail "the lease should have been taken"
   | Error e -> Alcotest.failf "seed lease: %s" (error_to_string e));
  let rt = match create_runtime ~persistence:(persistence_of b)
                     ~llm:(scripted_llm [text_response "resumed"]) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  ignore (Runtime.register_agent rt (make_agent "leased-agent"));
  Alcotest.(check (list (pair string string))) "the dead holder's run is an orphan"
    ["dead-1", "leased-agent"] (Runtime.list_orphaned_invokes rt);
  (match Runtime.recover_invoke rt ~invoke_id:"dead-1" () with
   | Ok r -> Alcotest.(check (option string)) "resumed" (Some "resumed") r.response.text
   | Error (e, _) -> Alcotest.failf "recover: %s" (error_to_string e))

(* Only one runtime can hold the lease: the takeover is a compare-and-swap. *)
let test_only_one_runtime_can_hold_the_lease () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  with_two_runtimes @@ fun _path a b ->
  let now = Unix.gettimeofday () in
  (match Sqlite_persistence.claim_invoke_lease a ~invoke_id:"race-1"
          ~owner:"runtime-a" ~pid:(Unix.getpid ()) ~ttl:300.0 with
   | Ok true -> ()
   | Ok false -> Alcotest.fail "the first claim should win"
   | Error e -> Alcotest.failf "claim A: %s" (error_to_string e));
  (match Sqlite_persistence.claim_invoke_lease b ~invoke_id:"race-1"
          ~owner:"runtime-b" ~pid:(Unix.getpid ()) ~ttl:300.0 with
   | Ok false -> ()
   | Ok true -> Alcotest.fail "a live holder must keep the lease"
   | Error e -> Alcotest.failf "claim B: %s" (error_to_string e));
  (* The holder can renew its own lease. *)
  (match Sqlite_persistence.claim_invoke_lease a ~invoke_id:"race-1"
          ~owner:"runtime-a" ~pid:(Unix.getpid ()) ~ttl:300.0 with
   | Ok true -> ()
   | Ok false -> Alcotest.fail "the holder must be able to renew"
   | Error e -> Alcotest.failf "renew: %s" (error_to_string e));
  (* Releasing hands it back. *)
  (match Sqlite_persistence.release_invoke_lease a ~invoke_id:"race-1"
          ~owner:"runtime-a" with
   | Ok () -> ()
   | Error e -> Alcotest.failf "release: %s" (error_to_string e));
  (match Sqlite_persistence.list_invoke_leases b with
   | Ok leases -> Alcotest.(check int) "no lease left" 0 (List.length leases)
   | Error e -> Alcotest.failf "list: %s" (error_to_string e));
  ignore now

let () =
  Alcotest.run "invoke lease" [
    "ownership", [
      Alcotest.test_case "a live run is not an orphan for another runtime" `Quick
        test_a_live_run_is_not_an_orphan_for_another_runtime;
      Alcotest.test_case "a dead holder releases the lease" `Quick
        test_a_dead_holder_releases_the_lease;
      Alcotest.test_case "only one runtime can hold the lease" `Quick
        test_only_one_runtime_can_hold_the_lease;
    ];
  ]
