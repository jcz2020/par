open Par
open Types

let err_str (e : error_category) =
  Yojson.Safe.to_string (error_category_to_yojson e)

let tmp_db_path suffix =
  let path = Filename.temp_file suffix ".db" in
  Sys.remove path;
  path

let mk_env i sid ts = {
  id = Printf.sprintf "env-%d" i;
  metadata = {
    trace_id = None; span_id = None; timestamp = ts;
    source = "test"; session_id = sid;
  };
  payload = Shutdown_initiated;
  idempotency_key = Printf.sprintf "key-%d" i;
  delivery_attempt = 0;
}

let test_runtime_create_persists_published_events () =
  let db = tmp_db_path "e2e" in
  let cleanup () = (try Sys.remove db with _ -> ()) in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let config : runtime_config = {
        persistence = `Sqlite db;
        event_bus = Runtime.default_event_bus_config;
        default_quota = Runtime.default_quota;
        shutdown = Runtime.default_shutdown_config;
        llm_providers = [];
        eval_limits = { max_depth = 10; max_node_visits = 1000 };
        parallel_tool_execution = true;
        bash_confirm = Types.default_bash_confirm_config;
  event_retention_seconds = 604800.0;
      } in
      let mock_llm : Types.llm_service = {
        complete_fn = (fun _ _ _ ->
          Ok { Types.text = Some "mock"; tool_calls = None; finish_reason = Stop;
               usage = { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 };
               model = "mock" });
        stream_fn = (fun _ _ _ _ _ -> Error (Timeout));
        close_fn = ignore;
        complete_structured_fn = None;
      } in
      match Sqlite_persistence.create db with
      | Error e -> cleanup (); Alcotest.fail ("sqlite create: " ^ err_str e)
      | Ok sqlt ->
        let persist : Types.persistence_service = {
          save_events_fn = (fun envs -> Sqlite_persistence.save_events sqlt envs);
          load_events_fn = (fun tid -> Sqlite_persistence.load_events sqlt tid);
          load_events_by_session_fn = (fun sid -> Sqlite_persistence.load_events_by_session sqlt sid);
          load_sessions_fn = (fun lim -> Sqlite_persistence.load_sessions sqlt lim);
          save_task_state_fn = (fun ts -> Sqlite_persistence.save_task_state sqlt ts);
          load_task_state_fn = (fun tid -> Sqlite_persistence.load_task_state sqlt tid);
          save_workflow_state_fn = (fun id st cp -> Sqlite_persistence.save_workflow_state sqlt id st cp);
          load_workflow_state_fn = (fun id -> Sqlite_persistence.load_workflow_state sqlt id);
          save_conversation_fn = (fun sid conv -> Sqlite_persistence.save_conversation sqlt sid conv);
          load_conversation_fn = (fun sid -> Sqlite_persistence.load_conversation sqlt sid);
          load_most_recent_conversation_fn = (fun () -> Sqlite_persistence.load_most_recent_conversation sqlt);
          close_fn = (fun () -> Sqlite_persistence.close sqlt);
        } in
        match Runtime.create ~llm:mock_llm ~persistence:persist ~config sw with
        | Error e -> ignore (Sqlite_persistence.close sqlt); cleanup (); Alcotest.fail ("create: " ^ err_str e)
        | Ok rt ->
          Runtime.publish_event rt (Task_started { task_id = Task_id.create () });
          Runtime.publish_event rt (Llm_request_sent { task_id = Task_id.create (); model = "mock" });
          Runtime.publish_event rt Shutdown_initiated;
          ignore (Runtime.close rt)));
  (match Sqlite_persistence.create db with
   | Error e -> cleanup (); Alcotest.fail ("reopen: " ^ err_str e)
   | Ok t ->
     (match Sqlite_persistence.load_sessions t 10 with
      | Ok sessions ->
        Alcotest.(check bool) "sessions non-empty" true (sessions <> [])
      | Error _ -> Alcotest.fail "load_sessions failed");
     Sqlite_persistence.close t);
  cleanup ()

let test_save_and_load_by_session () =
  let db = tmp_db_path "save_load" in
  (match Sqlite_persistence.create db with
   | Error e -> Alcotest.fail ("create: " ^ err_str e)
   | Ok t ->
     let envs = [
       mk_env 1 "sess-a" 1000.0;
       mk_env 2 "sess-a" 1001.0;
       mk_env 3 "sess-b" 1002.0;
     ] in
     (match Sqlite_persistence.save_events t envs with
      | Error _ -> Alcotest.fail "save_events failed"
      | Ok () ->
        (match Sqlite_persistence.load_events_by_session t "sess-a" with
         | Ok events -> Alcotest.(check int) "sess-a has 2 events" 2 (List.length events)
         | Error _ -> Alcotest.fail "load_events_by_session failed");
        (match Sqlite_persistence.load_events_by_session t "sess-b" with
         | Ok events -> Alcotest.(check int) "sess-b has 1 event" 1 (List.length events)
         | Error _ -> Alcotest.fail "load_events_by_session failed");
        (match Sqlite_persistence.load_sessions t 10 with
         | Ok sessions -> Alcotest.(check int) "2 sessions" 2 (List.length sessions)
         | Error _ -> Alcotest.fail "load_sessions failed"));
     Sqlite_persistence.close t);
  try Sys.remove db with _ -> ()

let test_schema_migration () =
  let db = tmp_db_path "migrate" in
  let raw = Sqlite3.db_open db in
  let _ = Sqlite3.exec raw "CREATE TABLE events (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, payload TEXT NOT NULL, timestamp REAL NOT NULL, idempotency_key TEXT UNIQUE NOT NULL)" in
  ignore (Sqlite3.db_close raw);
  (match Sqlite_persistence.create db with
   | Error e -> Alcotest.fail ("migration: " ^ err_str e)
   | Ok t ->
     let check = Sqlite3.db_open db in
     let stmt = Sqlite3.prepare check "SELECT session_id, actions_json FROM events LIMIT 0" in
     let _ = Sqlite3.step stmt in
     let _ = Sqlite3.finalize stmt in
     ignore (Sqlite3.db_close check);
     Sqlite_persistence.close t;
     Alcotest.(check bool) "migration adds columns" true true);
  try Sys.remove db with _ -> ()

let test_retention_pruning () =
  let db = tmp_db_path "retention" in
  (match Sqlite_persistence.create db with
   | Error e -> Alcotest.fail ("create: " ^ err_str e)
   | Ok t ->
     let old_env = mk_env 1 "old-sess" 0.0 in
     (match Sqlite_persistence.save_events t [old_env] with
      | Error _ -> Alcotest.fail "save failed"
      | Ok () ->
        (match Sqlite_persistence.prune_old_events t ~ttl_seconds:1.0 with
         | Error _ -> Alcotest.fail "prune failed"
         | Ok () ->
           (match Sqlite_persistence.load_events_by_session t "old-sess" with
            | Ok [] -> Alcotest.(check bool) "old event pruned" true true
            | Ok _ -> Alcotest.fail "old event should be pruned"
            | Error _ -> Alcotest.fail "query failed")));
     Sqlite_persistence.close t);
  try Sys.remove db with _ -> ()

let () =
  Alcotest.run "event_persistence_e2e" [
    ("runtime", [
      Alcotest.test_case "create publishes events that persist" `Quick
        test_runtime_create_persists_published_events;
    ]);
    ("persistence", [
      Alcotest.test_case "save and load by session" `Quick test_save_and_load_by_session;
    ]);
    ("schema", [
      Alcotest.test_case "migration adds session_id + actions_json" `Quick test_schema_migration;
    ]);
    ("retention", [
      Alcotest.test_case "prune removes old events" `Quick test_retention_pruning;
    ]);
  ]
