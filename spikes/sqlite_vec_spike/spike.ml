(* Phase B.0 spike: verify sqlite-vec is production-viable from OCaml.
 *
 * Pass criteria:
 *   - dune build succeeds
 *   - dune exec ./spike.exe prints 2 KNN rows with sane cosine distances
 *   - exit 0
 *
 * Failure modes:
 *   - "no such function: vec_version" → load_extension silently failed
 *     (check enable_load_extension return value, libsqlite3 build flags)
 *   - "vec0.so: cannot open" → path wrong, file missing
 *   - "no such table: v" → CREATE VIRTUAL TABLE failed
 *
 * Run: dune exec ./spike.exe
 *)

let vec0_path =
  if Sys.os_type = "Unix"
  then "/tmp/sqlite-vec-spike/vec0.so"
  else "/usr/local/lib/vec0.dylib"

let load_extension db path =
  (* Step 1: enable extension loading on the connection *)
  if not (Sqlite3.enable_load_extension db true) then
    (Printf.eprintf
       "FAIL: enable_load_extension returned false — libsqlite3 was built\
        with SQLITE_OMIT_LOAD_EXTENSION\n%!";
     exit 1);
  (* Step 2: trigger load via SQL (path must be literal, not bind param) *)
  let rc = Sqlite3.exec db (Printf.sprintf "SELECT load_extension('%s');" path) in
  (* Step 3: disable for safety *)
  let _ = Sqlite3.enable_load_extension db false in
  if rc <> Sqlite3.Rc.OK then begin
    Printf.eprintf "FAIL: load_extension exec rc=%s err=%s\n%!"
      (Sqlite3.Rc.to_string rc)
      (Sqlite3.errmsg db);
    exit 1
  end

let () =
  Printf.printf "=== sqlite-vec Phase B.0 spike ===\n";
  Printf.printf "vec0_path: %s\n" vec0_path;
  (* Confirm file exists *)
  if not (Sys.file_exists vec0_path) then begin
    Printf.eprintf "FAIL: vec0 file not found at %s\n%!" vec0_path;
    exit 1
  end;
  (* Open in-memory database *)
  let db = Sqlite3.db_open ":memory:" in
  (* Load extension *)
  load_extension db vec0_path;
  Printf.printf "[ok] load_extension succeeded\n";
  (* Sanity: confirm extension is alive *)
  (match Sqlite3.exec db "SELECT vec_version();" with
   | Sqlite3.Rc.OK -> Printf.printf "[ok] vec_version() callable\n"
   | rc ->
     Printf.eprintf "FAIL: vec_version() rc=%s err=%s\n%!"
       (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db);
     exit 1);
  (* Create virtual table — 8-dim float vectors, cosine distance *)
  let rc =
    Sqlite3.exec db
      "CREATE VIRTUAL TABLE v USING vec0( embedding float[8] \
       distance_metric=cosine );"
  in
  if rc <> Sqlite3.Rc.OK then
    (Printf.eprintf "FAIL: CREATE VIRTUAL TABLE rc=%s err=%s\n%!"
       (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db);
     exit 1);
  Printf.printf "[ok] CREATE VIRTUAL TABLE v USING vec0(...)\n";
  (* Insert 3 vectors via parameter binding *)
  let stmt =
    Sqlite3.prepare db "INSERT INTO v(rowid, embedding) VALUES (?, ?);"
  in
  let vecs =
    [|
      (1L, "[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]");
      (2L, "[0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1]");
      (3L, "[0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]");
    |]
  in
  Array.iter
    (fun (id, v) ->
      let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT id) in
      let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT v) in
      let _ = Sqlite3.step stmt in
      let _ = Sqlite3.reset stmt in
      let _ = Sqlite3.clear_bindings stmt in
      ())
    vecs;
  let _ = Sqlite3.finalize stmt in
  Printf.printf "[ok] inserted 3 vectors\n";
  (* KNN: 2 nearest neighbors of query vector using k=N form *)
  let knn =
    Sqlite3.prepare db
      "SELECT rowid, distance FROM v WHERE embedding MATCH ? AND k = 2;"
  in
  let _ =
    Sqlite3.bind knn 1
      (Sqlite3.Data.TEXT
         "[0.55, 0.55, 0.55, 0.55, 0.55, 0.55, 0.55, 0.55]")
  in
  Printf.printf "[ok] KNN query prepared\n";
  let rows = ref [] in
  while Sqlite3.step knn = Sqlite3.Rc.ROW do
    let rowid = Sqlite3.column knn 0 in
    let dist = Sqlite3.column knn 1 in
    let rowid_str =
      match rowid with
      | Sqlite3.Data.INT n -> Int64.to_string n
      | _ -> (
        match Sqlite3.Data.to_string rowid with
        | Some s -> s
        | None -> "<unknown>")
    in
    let dist_str =
      match Sqlite3.Data.to_string dist with
      | Some s -> s
      | None -> "<unknown>"
    in
    rows := (rowid_str, dist_str) :: !rows;
    Printf.printf "  KNN row: rowid=%s distance=%s\n" rowid_str dist_str
  done;
  let _ = Sqlite3.finalize knn in
  (* Validate: we should have exactly 2 rows *)
  let n = List.length !rows in
  if n <> 2 then
    (Printf.eprintf "FAIL: expected 2 KNN rows, got %d\n%!" n;
     exit 1);
  Printf.printf "[ok] KNN returned 2 rows as expected\n";
  (* Bonus: test vec_distance_cosine scalar function (manual KNN path) *)
  let manual =
    Sqlite3.prepare db
      "SELECT vec_distance_cosine(?, ?) AS d;"
  in
  let _ =
    Sqlite3.bind manual 1
      (Sqlite3.Data.TEXT "[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]")
  in
  let _ =
    Sqlite3.bind manual 2
      (Sqlite3.Data.TEXT "[0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]")
  in
  let _ = Sqlite3.step manual in
  let dist = Sqlite3.column manual 0 in
  Printf.printf "  vec_distance_cosine(orthogonal) = %s (expected ~1.0)\n"
    (match Sqlite3.Data.to_string dist with Some s -> s | None -> "<none>");
  let _ = Sqlite3.finalize manual in
  ignore (Sqlite3.db_close db);
  Printf.printf
    "=== spike PASSED — sqlite-vec is production-viable from OCaml ===\n%!"
