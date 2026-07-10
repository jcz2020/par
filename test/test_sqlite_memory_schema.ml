let vec0_available =
  let db = Sqlite3.db_open ":memory:" in
  let r = (try Sqlite3.enable_load_extension db true with Failure _ -> false) in
  ignore (Sqlite3.db_close db);
  r

let () =
  if not vec0_available then begin
    print_endline "[SKIP] SQLite load_extension not available on this platform";
    exit 0
  end
open Par_memory

let table_exists t name =
  let stmt =
    Sqlite3.prepare t.Sqlite_memory.db
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
  in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT name) in
  let found =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> true
    | _ -> false
  in
  let _ = Sqlite3.finalize stmt in
  found

let table_create_sql t name =
  let stmt =
    Sqlite3.prepare t.Sqlite_memory.db
      "SELECT sql FROM sqlite_master WHERE type='table' AND name=?"
  in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT name) in
  let result =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      let col = Sqlite3.column stmt 0 in
      (match col with
       | Sqlite3.Data.TEXT s -> Some s
       | _ -> None)
    | _ -> None
  in
  let _ = Sqlite3.finalize stmt in
  result

let vec_row_count t =
  let stmt =
    Sqlite3.prepare t.Sqlite_memory.db
      "SELECT count(*) FROM memory_entries_vec"
  in
  let count =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      (match Sqlite3.column stmt 0 with
       | Sqlite3.Data.INT n -> Int64.to_int n
       | _ -> 0)
    | _ -> 0
  in
  let _ = Sqlite3.finalize stmt in
  count

let test_fresh_db_has_fts_and_vec () =
  match Sqlite_memory.create ":memory:" with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    Alcotest.(check bool) "memory_entries_fts exists" true
      (table_exists t "memory_entries_fts");
    Alcotest.(check bool) "memory_entries_vec exists" true
      (table_exists t "memory_entries_vec");
    Alcotest.(check bool) "memory_entries base table exists" true
      (table_exists t "memory_entries");
    Sqlite_memory.close t

let test_custom_dimension () =
  match Sqlite_memory.create ~dimension:768 ":memory:" with
  | Error e -> Alcotest.failf "create dim=768: %s" (Memory_error.to_string e)
  | Ok t ->
    (match table_create_sql t "memory_entries_vec" with
     | None ->
       Alcotest.fail "memory_entries_vec CREATE statement not found"
     | Some sql ->
       Alcotest.(check bool) "DDL contains float[768]"
         (try ignore (Str.search_forward (Str.regexp_string "float[768]") sql 0); true
          with Not_found -> false) true);
    Sqlite_memory.close t

let test_migration_adds_vec_table () =
  let tmp_path = Filename.temp_file "par_mem_migration" ".db" in
  let raw_db = Sqlite3.db_open tmp_path in
  let _ =
    Sqlite3.exec raw_db
      "CREATE TABLE IF NOT EXISTS memory_entries (\
       \n  id INTEGER PRIMARY KEY AUTOINCREMENT,\
       \n  ext_id TEXT NOT NULL UNIQUE,\
       \n  content TEXT NOT NULL,\
       \n  summary TEXT,\
       \n  scope TEXT,\
       \n  metadata TEXT NOT NULL DEFAULT '{}',\
       \n  categories TEXT NOT NULL DEFAULT '[]',\
       \n  created_at REAL NOT NULL,\
       \n  updated_at REAL NOT NULL,\
       \n  last_used_at REAL,\
       \n  usage_count INTEGER NOT NULL DEFAULT 0,\
       \n  source TEXT NOT NULL DEFAULT '')"
  in
  let _ =
    Sqlite3.exec raw_db
      "CREATE VIRTUAL TABLE IF NOT EXISTS memory_entries_fts USING fts5(\
       \n  content, summary, scope,\
       \n  content='memory_entries', content_rowid='id',\
       \n  tokenize='porter unicode61')"
  in
  let check_stmt =
    Sqlite3.prepare raw_db
      "SELECT name FROM sqlite_master WHERE type='table' AND name='memory_entries_vec'"
  in
  let vec_exists_before =
    match Sqlite3.step check_stmt with
    | Sqlite3.Rc.ROW -> true
    | _ -> false
  in
  let _ = Sqlite3.finalize check_stmt in
  ignore (Sqlite3.db_close raw_db);
  Alcotest.(check bool) "vec0 absent before migration" false vec_exists_before;

  (match Sqlite_memory.create tmp_path with
   | Error e ->
     Sys.remove tmp_path;
     Alcotest.failf "create after migration: %s" (Memory_error.to_string e)
   | Ok t ->
     Alcotest.(check bool) "vec0 exists after migration" true
       (table_exists t "memory_entries_vec");
     Sqlite_memory.close t);
  Sys.remove tmp_path

let test_vec_table_empty_initially () =
  match Sqlite_memory.create ":memory:" with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    Alcotest.(check int) "vec0 row count is 0" 0 (vec_row_count t);
    Sqlite_memory.close t

let test_existing_ops_still_work () =
  match Sqlite_memory.create ~dimension:1536 ":memory:" with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ =
      Sqlite_memory.add t
        ~content:"OCaml structured concurrency with Eio"
        ~summary:"Eio basics" ~scope:"proj"
        ~categories:["concurrency"; "eio"] ()
    in
    let _ =
      Sqlite_memory.add t
        ~content:"Python asyncio uses event loops"
        ~summary:"asyncio basics" ~scope:"proj" ()
    in
    (match Sqlite_memory.search t ~scope:"proj" "OCaml Eio" with
     | Error e -> Alcotest.failf "search: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check bool) "search returns results" true
         (List.length results > 0);
       Alcotest.(check string) "content matches"
         "OCaml structured concurrency with Eio"
         (List.hd results).Memory_object.content);
    (match Sqlite_memory.list_all t ~scope:"proj" () with
     | Error e -> Alcotest.failf "list_all: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "list_all returns 2" 2 (List.length results));
    (match Sqlite_memory.search t ~scope:"proj" "asyncio" with
     | Error e -> Alcotest.failf "search asyncio: %s" (Memory_error.to_string e)
     | Ok results ->
       List.iter (fun (m : Memory_object.memory_object) ->
         ignore (Sqlite_memory.delete t m.id)
       ) results);
    (match Sqlite_memory.list_all t ~scope:"proj" () with
     | Error e -> Alcotest.failf "list_all after delete: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "one entry deleted" 1 (List.length results));
    Sqlite_memory.close t

let () =
  Eio_main.run (fun _env ->
    Alcotest.run "sqlite_memory_schema" [
      ("schema", [
         Alcotest.test_case "fresh db has fts5 and vec0" `Quick
           test_fresh_db_has_fts_and_vec;
         Alcotest.test_case "custom dimension" `Quick
           test_custom_dimension;
         Alcotest.test_case "vec0 empty initially" `Quick
           test_vec_table_empty_initially;
       ]);
      ("migration", [
         Alcotest.test_case "existing db gets vec0 on reopen" `Quick
           test_migration_adds_vec_table;
       ]);
      ("compat", [
         Alcotest.test_case "existing ops still work" `Quick
           test_existing_ops_still_work;
       ]);
    ])
