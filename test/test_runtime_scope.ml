(* Regression test for T11 / Bug 1.

   Bug 1 root cause: [Runtime.save_conversation] and
   [Runtime.load_most_recent_conversation] accepted a [?scope] argument
   in their signatures but silently dropped it at the
   [persistence_service] functor boundary. The underlying
   [Sqlite_persistence] layer always honored scope, so a
   persistence-direct test (test_sessions.ml::scope_filters_sessions)
   would have passed even while the Runtime-level API was broken.

   T6 plumbed the parameter through both Runtime methods. These tests
   verify the fix at the public Runtime API surface:

   1. within-scope roundtrip: save ~scope:"A" then load_most_recent
      ~scope:"A" returns the saved conversation.
   2. scope isolation: save ~scope:"A" is invisible to
      load_most_recent ~scope:"B".
   3. default (no-scope) roundtrip: save without ~scope then
      load_most_recent without ~scope returns the saved conversation
      (preserves pre-T6 behavior).

   Note: the runtime_config field [persistence = `Sqlite ":memory:"]
   is honored only by the FFI layer; the OCaml SDK takes persistence
   as an explicit [~persistence] argument (see test_generate.ml for
   the same convention). We construct the persistence_service by hand
   so save_conversation / load_most_recent_conversation actually hit
   a real SQLite handle. *)

open Par
open Types

(* -------------------------------------------------------------------------- *)
(* Fixtures                                                                   *)
(* -------------------------------------------------------------------------- *)

let dummy_usage : usage_stats = {
  prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
  cached_tokens = 0; cache_creation_input_tokens = 0;
  cache_read_input_tokens = 0;
}

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

(* A minimal conversation for direct persistence testing.
   [save_conversation] accepts an explicit ?conversation argument that
   overrides the runtime's current_conversation cell, but it still
   requires a non-None session_id (set as a side effect of [invoke]).
   So [with_persisted_runtime] registers a mock agent and does a
   single invoke to bootstrap the session_id before running tests. *)
let sample_conversation : conversation = {
  messages = [{
    role = User;
    content_blocks = [];
    tool_calls = None;
    tool_call_id = None;
    name = None;
    reasoning_content = None;
  }];
  metadata = [("test_marker", `String "runtime_scope")];
}

let mock_llm : llm_service = {
  complete_fn = (fun _ _ _ ->
    Ok { text = Some "mock"; reasoning_content = None;
         tool_calls = None; finish_reason = Stop;
         usage = dummy_usage; model = "mock" });
  stream_fn = (fun _ _ _ _ _ -> Error Timeout);
  close_fn = ignore;
  complete_structured_fn = None;
  list_models_fn = None;
  supports_native_tools_fn = None;
  context_window_fn = None; cache_control_fn = None;
}

let err_str (e : error_category) =
  Yojson.Safe.to_string (error_category_to_yojson e)

let test_runtime_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
}

(* Build a Runtime backed by an in-memory SQLite handle so that
   save_conversation / load_most_recent_conversation hit persistent
   storage rather than the default noop backend. Pattern copied from
   test_generate.ml::with_persisted_runtime. *)
let with_persisted_runtime (f : Runtime.runtime -> 'a) : 'a =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      match Sqlite_persistence.create ":memory:" with
      | Error e -> Alcotest.fail ("sqlite create: " ^ err_str e)
      | Ok sqlt ->
        let persist : persistence_service = {
          save_events_fn = (fun ?scope envs -> Sqlite_persistence.save_events ?scope sqlt envs);
          load_events_fn = (fun tid -> Sqlite_persistence.load_events sqlt tid);
          load_events_by_session_fn =
            (fun ?scope sid -> Sqlite_persistence.load_events_by_session ?scope sqlt sid);
          load_sessions_fn = (fun ?scope lim -> Sqlite_persistence.load_sessions ?scope sqlt lim);
          save_task_state_fn = (fun ts -> Sqlite_persistence.save_task_state sqlt ts);
          load_task_state_fn = (fun tid -> Sqlite_persistence.load_task_state sqlt tid);
          save_workflow_state_fn =
            (fun id st cp -> Sqlite_persistence.save_workflow_state sqlt id st cp);
          load_workflow_state_fn =
            (fun id -> Sqlite_persistence.load_workflow_state sqlt id);
          load_all_suspended_workflows_fn =
            (fun () -> Sqlite_persistence.load_all_suspended_workflows sqlt);
          save_workflow_def_fn =
            (fun id def -> Sqlite_persistence.save_workflow_def sqlt id def);
          load_all_workflow_defs_fn =
            (fun () -> Sqlite_persistence.load_all_workflow_defs sqlt);
          save_conversation_fn =
            (fun ?scope sid conv -> Sqlite_persistence.save_conversation ?scope sqlt sid conv);
          load_conversation_fn =
            (fun sid -> Sqlite_persistence.load_conversation sqlt sid);
          load_most_recent_conversation_fn =
            (fun ?scope () -> Sqlite_persistence.load_most_recent_conversation ?scope sqlt);
          save_pending_approval_fn =
            (fun ~run_id ~agent_id ~payload ~expires_at ->
              Sqlite_persistence.save_pending_approval sqlt ~run_id ~agent_id ~payload ~expires_at);
          load_pending_approval_fn =
            (fun ~run_id -> Sqlite_persistence.load_pending_approval sqlt ~run_id);
          delete_pending_approval_fn =
            (fun ~run_id -> Sqlite_persistence.delete_pending_approval sqlt ~run_id);
          close_fn = (fun () -> Sqlite_persistence.close sqlt);
        } in
        match Runtime.create ~llm:mock_llm ~persistence:persist
                ~config:test_runtime_config sw with
        | Error e ->
          (try Sqlite_persistence.close sqlt with _ -> ());
          Alcotest.fail ("Runtime.create: " ^ err_str e)
        | Ok rt ->
          let agent = match Runtime.make_agent ~id:"t"
                        ~system_prompt:(stable_prompt "test") ~model:dummy_model () with
            | Ok a -> a | Error e -> Alcotest.fail ("make_agent: " ^ err_str e) in
          (match Runtime.register_agent rt agent with
           | Error e -> Alcotest.fail ("register_agent: " ^ err_str e)
           | Ok () -> ());
          let _invoke_result = match Runtime.invoke rt ~agent_id:"t" ~message:"init" () with
            | Ok r -> r
            | Error (e, _) -> Alcotest.fail ("invoke: " ^ err_str e) in
          let result =
            try f rt
            with exn ->
              ignore (Runtime.close rt);
              raise exn
          in
          ignore (Runtime.close rt);
          result))

(* Helper: save [sample_conversation] under [?scope], failing the test
   if the save itself errors. *)
let save_sample ?scope rt =
  match Runtime.save_conversation ?scope ~conversation:sample_conversation rt () with
  | Error e -> Alcotest.fail ("save_conversation: " ^ err_str e)
  | Ok () -> ()

(* -------------------------------------------------------------------------- *)
(* Tests                                                                      *)
(* -------------------------------------------------------------------------- *)

(* Test 1: within-scope roundtrip. Verifies that [?scope] survives the
   Runtime -> persistence_service boundary in both directions. *)
let test_within_scope_returns_saved () =
  with_persisted_runtime (fun rt ->
    save_sample ~scope:"A" rt;
    match Runtime.load_most_recent_conversation ~scope:"A" rt () with
    | Error e -> Alcotest.fail ("load A: " ^ err_str e)
    | Ok None -> Alcotest.fail
        "load_most_recent_conversation ~scope:\"A\" returned None after save ~scope:\"A\""
    | Ok (Some (_sid, conv)) ->
      Alcotest.(check int)
        "roundtrip preserves message count"
        (List.length sample_conversation.messages)
        (List.length conv.messages))

(* Test 2: scope isolation. A conversation saved under scope "A" must
   not be visible to load_most_recent_conversation ~scope:"B". *)
let test_scope_isolation () =
  with_persisted_runtime (fun rt ->
    save_sample ~scope:"A" rt;
    match Runtime.load_most_recent_conversation ~scope:"B" rt () with
    | Error e -> Alcotest.fail ("load B: " ^ err_str e)
    | Ok None -> Alcotest.(check bool) "scope B sees nothing" true true
    | Ok (Some _) ->
      Alcotest.fail
        "scope leak: conversation saved under scope \"A\" was returned by load_most_recent_conversation ~scope:\"B\"")

(* Test 3: default (no-scope) roundtrip preserved. Verifies that
   callers that do not pass ?scope continue to see the pre-T6
   behavior: save without scope then load without scope returns the
   saved conversation. This guards against a regression where someone
   "fixes" scope plumbing by forcing a non-null default. *)
let test_default_no_scope_roundtrip () =
  with_persisted_runtime (fun rt ->
    save_sample rt;
    match Runtime.load_most_recent_conversation rt () with
    | Error e -> Alcotest.fail ("load default: " ^ err_str e)
    | Ok None -> Alcotest.fail
        "load_most_recent_conversation () returned None after save_conversation ()"
    | Ok (Some (_sid, conv)) ->
      Alcotest.(check int)
        "default roundtrip preserves message count"
        (List.length sample_conversation.messages)
        (List.length conv.messages))

let () =
  Alcotest.run "runtime_scope" [
    "scope_roundtrip", [
      Alcotest.test_case "save ~scope then load_most_recent ~scope returns it"
        `Quick test_within_scope_returns_saved;
    ];
    "scope_isolation", [
      Alcotest.test_case "save ~scope:A invisible to load_most_recent ~scope:B"
        `Quick test_scope_isolation;
    ];
    "default_behavior", [
      Alcotest.test_case "no-scope save + no-scope load roundtrip preserved"
        `Quick test_default_no_scope_roundtrip;
    ];
  ]
