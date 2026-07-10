open Memory_error
open Memory_object

type t = {
  db : Sqlite3.db;
  mutex : Eio.Mutex.t;
  dimension : int;
  embedding : Memory_service.embedding_fn option;
}

let exec_sql db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> Ok ()
  | rc ->
    Error (Database_error
             (Printf.sprintf "%s: %s"
                (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db)))

let check_fts5 db =
  match exec_sql db "CREATE VIRTUAL TABLE IF NOT EXISTS _fts5_check USING fts5(x);" with
  | Ok () ->
    ignore (exec_sql db "DROP TABLE IF EXISTS _fts5_check;");
    Ok ()
  | Error _ -> Error (FTS5_unavailable "this SQLite build lacks FTS5 support")

let resolve_vec_extension_path () =
  let so_name =
    if Sys.os_type = "Win32" then "vec0.dll"
    else if Sys.file_exists "/System/Library" then "vec0.dylib"
    else "vec0.so"
  in
  let exe_dir = Filename.dirname Sys.executable_name in
  let cwd = Sys.getcwd () in
  let candidates = [
    Filename.concat exe_dir so_name;
    Filename.concat exe_dir ("../lib/ffi/" ^ so_name);
    Filename.concat "/usr/local/lib/par" so_name;
    Filename.concat "/usr/local/share/par" so_name;
    Filename.concat cwd ("vendor/sqlite-vec/linux-x86_64/" ^ so_name);
    Filename.concat cwd ("vendor/sqlite-vec/macos-aarch64/" ^ so_name);
    Filename.concat cwd ("vendor/sqlite-vec/windows-x86_64/" ^ so_name);
    Filename.concat cwd ("../vendor/sqlite-vec/linux-x86_64/" ^ so_name);
    Filename.concat cwd ("../vendor/sqlite-vec/macos-aarch64/" ^ so_name);
    Filename.concat cwd ("../vendor/sqlite-vec/windows-x86_64/" ^ so_name);
  ] in
  List.find_opt Sys.file_exists candidates

let load_vec_extension db =
  match resolve_vec_extension_path () with
  | None -> Error (Database_error "vec0 extension not found in known locations")
  | Some path ->
    try
      if not (Sqlite3.enable_load_extension db true) then
        Error (Database_error "enable_load_extension returned false \
                               — SQLITE_OMIT_LOAD_EXTENSION")
      else
        let rc =
          Sqlite3.exec db (Printf.sprintf "SELECT load_extension('%s');" path)
        in
        let _ = Sqlite3.enable_load_extension db false in
        if rc <> Sqlite3.Rc.OK then
          Error (Database_error
                   (Printf.sprintf "load_extension failed: %s" (Sqlite3.errmsg db)))
        else Ok ()
    with Failure _ ->
      Error (Database_error "enable_load_extension not supported on this SQLite build")

let init_schema db ~dimension =
  let _ = exec_sql db "BEGIN" in
  let base_stmts = [
    "CREATE TABLE IF NOT EXISTS memory_entries (\
       id            INTEGER PRIMARY KEY AUTOINCREMENT,\
       ext_id        TEXT NOT NULL UNIQUE,\
       content       TEXT NOT NULL,\
       summary       TEXT,\
       scope         TEXT,\
       metadata      TEXT NOT NULL DEFAULT '{}',\
       categories    TEXT NOT NULL DEFAULT '[]',\
       created_at    REAL NOT NULL,\
       updated_at    REAL NOT NULL,\
       last_used_at  REAL,\
       usage_count   INTEGER NOT NULL DEFAULT 0,\
       source        TEXT NOT NULL DEFAULT ''\
     )";
    "CREATE INDEX IF NOT EXISTS idx_memory_scope \
       ON memory_entries(scope, updated_at DESC)";
    "CREATE INDEX IF NOT EXISTS idx_memory_ext_id \
       ON memory_entries(ext_id)";
    "CREATE VIRTUAL TABLE IF NOT EXISTS memory_entries_fts USING fts5(\
       content, summary, scope,\
       content='memory_entries', content_rowid='id',\
       tokenize='porter unicode61'\
     )";
    {|CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memory_entries BEGIN
        INSERT INTO memory_entries_fts(rowid, content, summary, scope)
        VALUES (new.id, new.content, new.summary, new.scope);
     END|};
    {|CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memory_entries BEGIN
        INSERT INTO memory_entries_fts(memory_entries_fts, rowid, content, summary, scope)
        VALUES ('delete', old.id, old.content, old.summary, old.scope);
     END|};
    {|CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE ON memory_entries BEGIN
        INSERT INTO memory_entries_fts(memory_entries_fts, rowid, content, summary, scope)
        VALUES ('delete', old.id, old.content, old.summary, old.scope);
        INSERT INTO memory_entries_fts(rowid, content, summary, scope)
        VALUES (new.id, new.content, new.summary, new.scope);
     END|};
   ] in
  let result = match List.find_map (fun sql ->
    match exec_sql db sql with
    | Ok () -> None
    | Error e -> Some (Error e)
  ) base_stmts with
  | Some e -> e
  | None ->
    let vec_sql =
      Printf.sprintf
        "CREATE VIRTUAL TABLE IF NOT EXISTS memory_entries_vec USING vec0(\
         \n  embedding float[%d] distance_metric=cosine)"
        dimension
    in
    (match exec_sql db vec_sql with
     | Ok () ->
       (* vec0 lazy-sync: DELETE trigger removes embedding; UPDATE
          trigger drops stale embedding (re-embed on next add/search).
          No INSERT trigger — application embeds on add. *)
       let vec_triggers = [
         {|CREATE TRIGGER IF NOT EXISTS memory_entries_vec_ad
           AFTER DELETE ON memory_entries BEGIN
             DELETE FROM memory_entries_vec WHERE rowid = OLD.id;
           END|};
         {|CREATE TRIGGER IF NOT EXISTS memory_entries_vec_au
           AFTER UPDATE OF content ON memory_entries BEGIN
             DELETE FROM memory_entries_vec WHERE rowid = OLD.id;
           END|};
       ] in
       (match List.find_map (fun sql ->
         match exec_sql db sql with
         | Ok () -> None
         | Error e -> Some (Error e)
       ) vec_triggers with
        | Some e -> e
        | None -> Ok ())
     | Error _ -> Ok ())
  in
  (match result with
   | Ok () -> ignore (exec_sql db "COMMIT")
   | Error _ -> ignore (exec_sql db "ROLLBACK"));
  result

let generate_id () =
  Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())

let float_array_to_blob (arr : float array) : string =
  let len = Array.length arr in
  let buf = Bytes.create (len * 4) in
  Array.iteri (fun i f ->
    let bits = Int32.bits_of_float f in
    Bytes.set_int32_le buf (i * 4) bits
  ) arr;
  Bytes.to_string buf

let insert_embedding db ~rowid ~dimension ~embedding_fn ~content =
  match embedding_fn [content] with
  | Error e ->
    Logs.warn (fun m -> m "Sqlite_memory: embedding generation failed: %s" e)
  | Ok vectors ->
    match vectors with
    | [] -> ()
    | vec :: _ ->
      if Array.length vec = 0 then ()
      else if Array.length vec <> dimension then
        Logs.warn (fun m -> m "Sqlite_memory: embedding dimension mismatch (expected %d, got %d), skipping"
          dimension (Array.length vec))
      else
        let blob = float_array_to_blob vec in
        let stmt = Sqlite3.prepare db
          "INSERT OR IGNORE INTO memory_entries_vec(rowid, embedding) VALUES (?, ?)" in
        let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int rowid)) in
        let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.BLOB blob) in
        let _ = Sqlite3.step stmt in
        let _ = Sqlite3.finalize stmt in
        ()

let select_cols =
  "ext_id, content, summary, scope, metadata, categories, \
    created_at, updated_at, last_used_at, usage_count, source"

let select_cols_qualified =
  "me.ext_id, me.content, me.summary, me.scope, me.metadata, me.categories, \
    me.created_at, me.updated_at, me.last_used_at, me.usage_count, me.source"

let row_to_memory (stmt : Sqlite3.stmt) : memory_object =
  let ext_id = Sqlite3.column_text stmt 0 in
  let content = Sqlite3.column_text stmt 1 in
  let summary =
    if Sqlite3.column_is_null stmt 2 then None
    else Some (Sqlite3.column_text stmt 2)
  in
  let scope =
    if Sqlite3.column_is_null stmt 3 then None
    else Some (Sqlite3.column_text stmt 3)
  in
  let metadata_json = Sqlite3.column_text stmt 4 in
  let categories_json = Sqlite3.column_text stmt 5 in
  let created_at = Sqlite3.column_double stmt 6 in
  let updated_at = Sqlite3.column_double stmt 7 in
  let _last_used_at =
    if Sqlite3.column_is_null stmt 8 then None
    else Some (Sqlite3.column_double stmt 8)
  in
  let _usage_count = Sqlite3.column_int stmt 9 in
  let source = Sqlite3.column_text stmt 10 in
  let metadata =
    match Yojson.Safe.from_string metadata_json with
    | `Assoc xs -> xs
    | _ -> []
    | exception _ -> []
  in
  let categories =
    match Yojson.Safe.from_string categories_json with
    | `List xs -> List.filter_map (function `String s -> Some s | _ -> None) xs
    | _ -> []
    | exception _ -> []
  in
  { id = ext_id; content; summary; scope; metadata; categories;
    created_at; updated_at; source; }

let collect_rows db sql bind_fn =
  let stmt = Sqlite3.prepare db sql in
  let () = bind_fn stmt in
  let results = ref [] in
  let rec loop () =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      results := row_to_memory stmt :: !results;
      loop ()
    | Sqlite3.Rc.DONE -> ()
    | rc -> raise (Sqlite3.Error (Sqlite3.Rc.to_string rc))
  in
  loop ();
  let _ = Sqlite3.finalize stmt in
  List.rev !results

let wrap_db_error f =
  try Ok (f ())
  with
  | Sqlite3.Error msg -> Error (Database_error msg)
  | Sqlite3.SqliteError msg -> Error (Database_error msg)

let create ?(dimension=1536) ?embedding_fn db_path =
  if dimension <= 0 then
    invalid_arg "Sqlite_memory.create: dimension must be positive";
  let fts5_db = Sqlite3.db_open ":memory:" in
  let result = check_fts5 fts5_db in
  let _ = Sqlite3.db_close fts5_db in
  match result with
  | Error e -> Error e
  | Ok () ->
    wrap_db_error (fun () ->
      let db = Sqlite3.db_open db_path in
      ignore (exec_sql db "PRAGMA journal_mode=WAL;");
      let _ = load_vec_extension db in
      match init_schema db ~dimension with
      | Ok () ->
        { db; mutex = Eio.Mutex.create (); dimension; embedding = embedding_fn }
      | Error (Database_error msg) ->
        ignore (Sqlite3.db_close db);
        raise (Sqlite3.Error msg)
      | Error e ->
        ignore (Sqlite3.db_close db);
        raise (Sqlite3.Error (to_string e)))

let add t ~content ?summary ?scope ?(metadata=[]) ?(categories=[]) ?(source="") () =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    wrap_db_error (fun () ->
      let ext_id = generate_id () in
      let now = Unix.gettimeofday () in
      let metadata_json = Yojson.Safe.to_string (`Assoc metadata) in
      let categories_json =
        Yojson.Safe.to_string (`List (List.map (fun s -> `String s) categories))
      in
      let stmt = Sqlite3.prepare t.db
        ("INSERT INTO memory_entries \
          (ext_id, content, summary, scope, metadata, categories, \
           created_at, updated_at, source) \
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)") in
      let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT ext_id) in
      let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT content) in
      let _ = Sqlite3.bind stmt 3 (match summary with
        | None -> Sqlite3.Data.NULL
        | Some s -> Sqlite3.Data.TEXT s) in
      let _ = Sqlite3.bind stmt 4 (match scope with
        | None -> Sqlite3.Data.NULL
        | Some s -> Sqlite3.Data.TEXT s) in
      let _ = Sqlite3.bind stmt 5 (Sqlite3.Data.TEXT metadata_json) in
      let _ = Sqlite3.bind stmt 6 (Sqlite3.Data.TEXT categories_json) in
      let _ = Sqlite3.bind stmt 7 (Sqlite3.Data.FLOAT now) in
      let _ = Sqlite3.bind stmt 8 (Sqlite3.Data.FLOAT now) in
      let _ = Sqlite3.bind stmt 9 (Sqlite3.Data.TEXT source) in
      let rc = Sqlite3.step stmt in
      let _ = Sqlite3.finalize stmt in
      (match rc with
       | Sqlite3.Rc.DONE -> ()
       | _ -> raise (Sqlite3.Error (Sqlite3.Rc.to_string rc)));
      let rowid = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
       (match t.embedding with
        | Some embed_fn -> insert_embedding t.db ~rowid ~dimension:t.dimension ~embedding_fn:embed_fn ~content
        | None -> ());
      { id = ext_id; content; summary; scope; metadata; categories;
        created_at = now; updated_at = now; source }))

let sanitize_fts_query (query : string) : string =
  let tokens = Str.split (Str.regexp "[ \t]+") (String.trim query) in
  let quoted = List.map (fun token ->
    let buf = Buffer.create (String.length token + 2) in
    Buffer.add_char buf '"';
    String.iter (fun c ->
      if c = '"' then Buffer.add_string buf "\"\""
      else Buffer.add_char buf c
    ) token;
    Buffer.add_char buf '"';
    Buffer.contents buf
  ) tokens in
  String.concat " AND " quoted

let bump_usage t ~ext_id =
  try
    let stmt = Sqlite3.prepare t.db
      "UPDATE memory_entries SET usage_count = usage_count + 1, \
       last_used_at = ? WHERE ext_id = ?" in
    let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.FLOAT (Unix.gettimeofday ())) in
    let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT ext_id) in
    let _ = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    ()
  with _ -> ()

let resolve_mode (mode : Memory_service.search_mode option) embedding_opt =
  match mode with
  | Some Memory_service.Auto | None ->
    (match embedding_opt with
     | Some _ -> Memory_service.Hybrid
     | None -> Memory_service.Keyword_only)
  | Some m -> m

let search_fts t ?scope ?(limit=5) query =
  let fts_query = sanitize_fts_query query in
  match scope with
  | None ->
    let sql =
      Printf.sprintf
        "SELECT %s FROM memory_entries_fts \
         JOIN memory_entries me ON me.id = memory_entries_fts.rowid \
         WHERE memory_entries_fts MATCH ? \
         ORDER BY rank LIMIT ?"
        select_cols_qualified in
    wrap_db_error (fun () ->
      let results = collect_rows t.db sql (fun stmt ->
        let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT fts_query) in
        let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int limit)) in
        ()) in
      List.iter (fun (m : memory_object) -> bump_usage t ~ext_id:m.id) results;
      results)
  | Some sc ->
    let sql =
      Printf.sprintf
        "SELECT %s FROM memory_entries_fts \
         JOIN memory_entries me ON me.id = memory_entries_fts.rowid \
         WHERE memory_entries_fts MATCH ? AND me.scope = ? \
         ORDER BY rank LIMIT ?"
        select_cols_qualified in
    wrap_db_error (fun () ->
      let results = collect_rows t.db sql (fun stmt ->
        let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT fts_query) in
        let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT sc) in
        let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.INT (Int64.of_int limit)) in
        ()) in
      List.iter (fun (m : memory_object) -> bump_usage t ~ext_id:m.id) results;
      results)

let search_vec t ?scope ?(limit=5) query_vec =
  let blob = float_array_to_blob query_vec in
  match scope with
  | None ->
    let sql =
      Printf.sprintf
        "SELECT %s FROM memory_entries me \
         INNER JOIN ( \
           SELECT rowid, distance FROM memory_entries_vec \
           WHERE embedding MATCH ? AND k = ? \
         ) vec ON me.id = vec.rowid"
        select_cols_qualified in
    wrap_db_error (fun () ->
      let results = collect_rows t.db sql (fun stmt ->
        let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.BLOB blob) in
        let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int limit)) in
        ()) in
      List.iter (fun (m : memory_object) -> bump_usage t ~ext_id:m.id) results;
      results)
  | Some sc ->
    let sql =
      Printf.sprintf
        "SELECT %s FROM memory_entries me \
         INNER JOIN ( \
           SELECT rowid, distance FROM memory_entries_vec \
           WHERE embedding MATCH ? AND k = ? \
         ) vec ON me.id = vec.rowid \
         WHERE me.scope = ?"
        select_cols_qualified in
    wrap_db_error (fun () ->
      let results = collect_rows t.db sql (fun stmt ->
        let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.BLOB blob) in
        let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int limit)) in
        let _ = Sqlite3.bind stmt 3 (Sqlite3.Data.TEXT sc) in
        ()) in
      List.iter (fun (m : memory_object) -> bump_usage t ~ext_id:m.id) results;
      results)

let hybrid_search t ?scope ?(limit=5) ?(weight_fts=0.5) ?(weight_vec=0.5)
    ?(rrf_k=60) ~query ~query_vec () =
  let fts_query = sanitize_fts_query query in
  let blob = float_array_to_blob query_vec in
  let overfetch = limit * 3 in
  let combined_rank_expr =
    Printf.sprintf
      "COALESCE(1.0 / (%d + f.fts_rank), 0.0) * %.6f + \
       COALESCE(1.0 / (%d + v.vec_rank), 0.0) * %.6f"
      rrf_k weight_fts rrf_k weight_vec
  in
  let scope_clause = match scope with None -> "" | Some _ -> " AND me.scope = ?" in
  let sql =
    Printf.sprintf
      "WITH fts_ranks AS (\
       \n  SELECT me.id AS mid, ROW_NUMBER() OVER (ORDER BY rank) AS fts_rank\
       \n  FROM memory_entries_fts\
       \n  JOIN memory_entries me ON me.id = memory_entries_fts.rowid\
       \n  WHERE memory_entries_fts MATCH ?%s\
       \n  ORDER BY rank\
       \n  LIMIT ?\
       \n),\
       \nvec_ranks AS (\
       \n  SELECT rowid AS vid, ROW_NUMBER() OVER (ORDER BY distance) AS vec_rank\
       \n  FROM memory_entries_vec\
       \n  WHERE embedding MATCH ? AND k = ?\
       \n)\
       \nSELECT %s,\
       \n       %s AS combined_rank\
       \nFROM memory_entries me\
       \nLEFT JOIN fts_ranks f ON f.mid = me.id\
       \nLEFT JOIN vec_ranks v ON v.vid = me.id\
       \nWHERE (f.mid IS NOT NULL OR v.vid IS NOT NULL)%s\
       \nORDER BY combined_rank DESC\
       \nLIMIT ?"
      scope_clause select_cols_qualified combined_rank_expr scope_clause
  in
  wrap_db_error (fun () ->
    let results = collect_rows t.db sql (fun stmt ->
      let p = ref 1 in
      (* FTS CTE: query, [scope], overfetch *)
      Sqlite3.bind stmt !p (Sqlite3.Data.TEXT fts_query) |> ignore;
      incr p;
      (match scope with
       | Some sc ->
         Sqlite3.bind stmt !p (Sqlite3.Data.TEXT sc) |> ignore; incr p
       | None -> ());
      Sqlite3.bind stmt !p (Sqlite3.Data.INT (Int64.of_int overfetch)) |> ignore;
      incr p;
      (* Vec CTE: blob, overfetch-as-k *)
      Sqlite3.bind stmt !p (Sqlite3.Data.BLOB blob) |> ignore;
      incr p;
      Sqlite3.bind stmt !p (Sqlite3.Data.INT (Int64.of_int overfetch)) |> ignore;
      incr p;
      (* Outer WHERE: [scope] *)
      (match scope with
       | Some sc ->
         Sqlite3.bind stmt !p (Sqlite3.Data.TEXT sc) |> ignore; incr p
       | None -> ());
      (* Final LIMIT *)
      Sqlite3.bind stmt !p (Sqlite3.Data.INT (Int64.of_int limit)) |> ignore;
      ()) in
    List.iter (fun (m : memory_object) -> bump_usage t ~ext_id:m.id) results;
    results)

let search t ?mode ?scope ?(limit=5) query =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    let resolved = resolve_mode mode t.embedding in
    match resolved with
    | Keyword_only -> search_fts t ?scope ~limit query
    | Vector_only ->
      (match t.embedding with
       | None -> Error Embedding_unavailable
       | Some embed_fn ->
         (match embed_fn [query] with
          | Error msg -> Error (Database_error (Printf.sprintf "embedding failed: %s" msg))
          | Ok [] -> search_fts t ?scope ~limit query
          | Ok (vec :: _) -> search_vec t ?scope ~limit vec))
    | Auto ->
      search_fts t ?scope ~limit query
    | Hybrid ->
      (match t.embedding with
       | None -> search_fts t ?scope ~limit query
       | Some embed_fn ->
         (match embed_fn [query] with
          | Error _ -> search_fts t ?scope ~limit query
          | Ok [] -> search_fts t ?scope ~limit query
          | Ok (vec :: _) ->
            (match hybrid_search t ?scope ~limit ~query ~query_vec:vec () with
             | Ok results -> Ok results
             | Error _ -> search_fts t ?scope ~limit query))))

let update t (existing : memory_object) =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    wrap_db_error (fun () ->
      let ext_id = generate_id () in
      let now = Unix.gettimeofday () in
      let metadata_json = Yojson.Safe.to_string (`Assoc existing.metadata) in
      let categories_json =
        Yojson.Safe.to_string
           (`List (List.map (fun s -> `String s) existing.categories))
      in
      (* Delete old row — vec0 and FTS5 triggers handle cascading cleanup *)
      let del_stmt = Sqlite3.prepare t.db
        "DELETE FROM memory_entries WHERE ext_id = ?" in
      let _ = Sqlite3.bind del_stmt 1 (Sqlite3.Data.TEXT existing.id) in
      let _ = Sqlite3.step del_stmt in
      let _ = Sqlite3.finalize del_stmt in
      let stmt = Sqlite3.prepare t.db
        ("INSERT INTO memory_entries \
          (ext_id, content, summary, scope, metadata, categories, \
           created_at, updated_at, source) \
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)") in
      let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT ext_id) in
      let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT existing.content) in
      let _ = Sqlite3.bind stmt 3 (match existing.summary with
        | None -> Sqlite3.Data.NULL
        | Some s -> Sqlite3.Data.TEXT s) in
      let _ = Sqlite3.bind stmt 4 (match existing.scope with
        | None -> Sqlite3.Data.NULL
        | Some s -> Sqlite3.Data.TEXT s) in
      let _ = Sqlite3.bind stmt 5 (Sqlite3.Data.TEXT metadata_json) in
      let _ = Sqlite3.bind stmt 6 (Sqlite3.Data.TEXT categories_json) in
      let _ = Sqlite3.bind stmt 7 (Sqlite3.Data.FLOAT existing.created_at) in
      let _ = Sqlite3.bind stmt 8 (Sqlite3.Data.FLOAT now) in
      let _ = Sqlite3.bind stmt 9 (Sqlite3.Data.TEXT existing.source) in
      let rc = Sqlite3.step stmt in
      let _ = Sqlite3.finalize stmt in
      (match rc with
       | Sqlite3.Rc.DONE -> ()
       | _ -> raise (Sqlite3.Error (Sqlite3.Rc.to_string rc)));
      { existing with id = ext_id; updated_at = now }))

let delete t ext_id =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    wrap_db_error (fun () ->
      let stmt = Sqlite3.prepare t.db
        "DELETE FROM memory_entries WHERE ext_id = ?" in
      let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT ext_id) in
      let rc = Sqlite3.step stmt in
      let _ = Sqlite3.finalize stmt in
      match rc with
      | Sqlite3.Rc.DONE ->
        if Sqlite3.changes t.db = 0 then
          raise (Sqlite3.Error "not found")
      | _ -> raise (Sqlite3.Error (Sqlite3.Rc.to_string rc))))

let list_all t ?scope ?(limit=50) () =
  Eio.Mutex.use_ro t.mutex (fun () ->
    match scope with
    | None ->
      let sql =
        Printf.sprintf
          "SELECT %s FROM memory_entries \
           ORDER BY last_used_at DESC NULLS LAST, usage_count DESC \
           LIMIT ?"
          select_cols in
      wrap_db_error (fun () ->
        collect_rows t.db sql (fun stmt ->
          let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.INT (Int64.of_int limit)) in
          ()))
    | Some sc ->
      let sql =
        Printf.sprintf
          "SELECT %s FROM memory_entries \
           WHERE scope = ? \
           ORDER BY last_used_at DESC NULLS LAST, usage_count DESC \
           LIMIT ?"
          select_cols in
      wrap_db_error (fun () ->
        collect_rows t.db sql (fun stmt ->
          let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT sc) in
          let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int limit)) in
          ())))

let render_index t ?(max_entries=50) ?scope () =
  let results = match list_all t ?scope ~limit:max_entries () with
    | Ok l -> l
    | Error _ -> []
  in
  if results = [] then ""
  else
    let buf = Buffer.create 2048 in
    let count = ref 0 in
    List.iter (fun (m : memory_object) ->
      if !count < max_entries then begin
        let scope_tag = match m.scope with
          | None -> ""
          | Some s -> Printf.sprintf " [%s]" s
        in
        let summary_text = match m.summary with
          | None ->
            let len = min 80 (String.length m.content) in
            String.sub m.content 0 len
          | Some s -> s
        in
        let cat_tag = match m.categories with
          | [] -> ""
          | cs -> Printf.sprintf " (%s)" (String.concat ", " cs)
        in
        Buffer.add_string buf
          (Printf.sprintf "- %s%s%s — %s\n"
             m.id scope_tag cat_tag summary_text);
        incr count
      end
    ) results;
    Buffer.contents buf

let close t =
  match Sqlite3.db_close t.db with
  | true -> ()
  | false ->
    Logs.err (fun m -> m "Sqlite_memory: db_close failed: database was busy")

let make_service ?(dimension=1536) ?embedding_fn db_path =
  match create ~dimension ?embedding_fn db_path with
  | Error e -> Error e
  | Ok t ->
    Ok {
      Memory_service.add_fn = (fun ~content ?summary ?scope ?metadata ?categories ?source () ->
        add t ~content ?summary ?scope ?metadata ?categories ?source ());
      search_fn = (fun ?mode ?scope ?limit query ->
        search t ?mode ?scope ?limit query);
      update_fn = (fun obj -> update t obj);
      delete_fn = (fun id -> delete t id);
      list_all_fn = (fun ?scope ?limit () ->
        list_all t ?scope ?limit ());
      close_fn = (fun () -> close t);
      render_index_fn = (fun ?max_entries ?scope () ->
        render_index t ?max_entries ?scope ());
    }
