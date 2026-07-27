open Par

let err_str (e : Types.error_category) =
  Yojson.Safe.to_string (Types.error_category_to_yojson e)

let tmp_db_path suffix =
  let path = Filename.temp_file suffix ".db" in
  Sys.remove path;
  path

let with_db f =
  let db = tmp_db_path "approvals" in
  (match Sqlite_persistence.create db with
   | Error e -> Alcotest.fail ("create: " ^ err_str e)
   | Ok t ->
     (try f t; Sqlite_persistence.close t
      with ex -> Sqlite_persistence.close t; raise ex));
  try Sys.remove db with _ -> ()

let test_save_load_delete_roundtrip () =
  with_db (fun t ->
    let payload = `Assoc [("action", `String "send_email")] in
    let now = Unix.gettimeofday () in
    let expires = now +. 300.0 in
    (match Sqlite_persistence.save_pending_approval t
            ~run_id:"run-1" ~agent_id:"agent-a" ~payload ~expires_at:expires with
     | Error e -> Alcotest.fail ("save: " ^ err_str e)
     | Ok () ->
       (match Sqlite_persistence.load_pending_approval t ~run_id:"run-1" with
        | Error e -> Alcotest.fail ("load: " ^ err_str e)
        | Ok None -> Alcotest.fail "expected Some payload"
        | Ok (Some loaded) ->
          Alcotest.(check string) "payload matches"
            (Yojson.Safe.to_string payload) (Yojson.Safe.to_string loaded));
       (match Sqlite_persistence.delete_pending_approval t ~run_id:"run-1" with
        | Error e -> Alcotest.fail ("delete: " ^ err_str e)
        | Ok () ->
          (match Sqlite_persistence.load_pending_approval t ~run_id:"run-1" with
           | Error e -> Alcotest.fail ("load after delete: " ^ err_str e)
           | Ok None -> ()
           | Ok (Some _) -> Alcotest.fail "expected None after delete"))))

let test_load_expired_returns_none () =
  with_db (fun t ->
    let payload = `Assoc [("action", `String "deploy")] in
    let now = Unix.gettimeofday () in
    let expired = now -. 10.0 in
    (match Sqlite_persistence.save_pending_approval t
            ~run_id:"run-expired" ~agent_id:"agent-b" ~payload ~expires_at:expired with
     | Error e -> Alcotest.fail ("save: " ^ err_str e)
     | Ok () ->
       (match Sqlite_persistence.load_pending_approval t ~run_id:"run-expired" with
        | Error e -> Alcotest.fail ("load: " ^ err_str e)
        | Ok None -> ()
        | Ok (Some _) -> Alcotest.fail "expired approval should return None")))

let test_list_expired_approvals () =
  with_db (fun t ->
    let now = Unix.gettimeofday () in
    let payload = `Null in
    (match Sqlite_persistence.save_pending_approval t
            ~run_id:"run-old" ~agent_id:"a" ~payload ~expires_at:(now -. 100.0) with
     | Error e -> Alcotest.fail ("save old: " ^ err_str e)
     | Ok () ->
       (match Sqlite_persistence.save_pending_approval t
               ~run_id:"run-new" ~agent_id:"b" ~payload ~expires_at:(now +. 100.0) with
        | Error e -> Alcotest.fail ("save new: " ^ err_str e)
        | Ok () ->
          (match Sqlite_persistence.list_expired_approvals t ~cutoff:now with
           | Error e -> Alcotest.fail ("list: " ^ err_str e)
           | Ok ids ->
             Alcotest.(check (list string)) "only expired" ["run-old"] ids))))

let test_migration_from_v07x_schema () =
  let db = tmp_db_path "migrate_approvals" in
  let raw = Sqlite3.db_open db in
  let sql = "CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, payload TEXT NOT NULL, timestamp REAL NOT NULL, idempotency_key TEXT UNIQUE NOT NULL)" in
  let _ = Sqlite3.exec raw sql in
  let sql2 = "CREATE TABLE IF NOT EXISTS task_states (id TEXT PRIMARY KEY, state TEXT NOT NULL, updated_at REAL NOT NULL)" in
  let _ = Sqlite3.exec raw sql2 in
  let sql3 = "CREATE TABLE IF NOT EXISTS workflow_states (id TEXT PRIMARY KEY, workflow_id TEXT NOT NULL, status TEXT NOT NULL, checkpoint TEXT, updated_at REAL NOT NULL)" in
  let _ = Sqlite3.exec raw sql3 in
  let sql4 = "CREATE TABLE IF NOT EXISTS conversations (session_id TEXT PRIMARY KEY, messages_json TEXT NOT NULL, metadata_json TEXT NOT NULL, updated_at REAL NOT NULL, turn_count INTEGER NOT NULL)" in
  let _ = Sqlite3.exec raw sql4 in
  let sql5 = "CREATE TABLE IF NOT EXISTS workflow_definitions (workflow_id TEXT PRIMARY KEY, def_json TEXT NOT NULL, updated_at REAL NOT NULL)" in
  let _ = Sqlite3.exec raw sql5 in
  ignore (Sqlite3.db_close raw);
  (match Sqlite_persistence.create db with
   | Error e -> Alcotest.fail ("migration: " ^ err_str e)
   | Ok t ->
     let payload = `Assoc [("test", `Bool true)] in
     let now = Unix.gettimeofday () in
     (match Sqlite_persistence.save_pending_approval t
             ~run_id:"migrate-run" ~agent_id:"migrate-agent" ~payload ~expires_at:(now +. 60.0) with
      | Error e -> Alcotest.fail ("save after migration: " ^ err_str e)
      | Ok () ->
        (match Sqlite_persistence.load_pending_approval t ~run_id:"migrate-run" with
         | Error e -> Alcotest.fail ("load after migration: " ^ err_str e)
         | Ok None -> Alcotest.fail "expected Some after migration"
         | Ok (Some _) -> ()));
     Sqlite_persistence.close t);
  try Sys.remove db with _ -> ()

let test_noop_stubs () =
  (match Noop_persistence.create ":memory:" with
   | Error e -> Alcotest.fail ("create: " ^ err_str e)
   | Ok t ->
     let payload = `Assoc [("key", `String "val")] in
     (match Noop_persistence.save_pending_approval t
             ~run_id:"r1" ~agent_id:"a1" ~payload ~expires_at:999.0 with
      | Error e -> Alcotest.fail ("noop save: " ^ err_str e)
      | Ok () -> ());
     (match Noop_persistence.load_pending_approval t ~run_id:"r1" with
      | Error e -> Alcotest.fail ("noop load: " ^ err_str e)
      | Ok None -> ()
      | Ok (Some _) -> Alcotest.fail "noop should return None");
     (match Noop_persistence.delete_pending_approval t ~run_id:"r1" with
      | Error e -> Alcotest.fail ("noop delete: " ^ err_str e)
      | Ok () -> ());
     (match Noop_persistence.list_expired_approvals t ~cutoff:0.0 with
      | Error e -> Alcotest.fail ("noop list: " ^ err_str e)
      | Ok [] -> ()
      | Ok _ -> Alcotest.fail "noop should return empty list"))

let () =
  Alcotest.run "approvals_persistence" [
    ("crud", [
      Alcotest.test_case "save load delete roundtrip" `Quick test_save_load_delete_roundtrip;
      Alcotest.test_case "expired returns None" `Quick test_load_expired_returns_none;
      Alcotest.test_case "list expired approvals" `Quick test_list_expired_approvals;
    ]);
    ("migration", [
      Alcotest.test_case "v0.7.x schema migration" `Quick test_migration_from_v07x_schema;
    ]);
    ("noop", [
      Alcotest.test_case "noop stubs" `Quick test_noop_stubs;
    ]);
  ]
