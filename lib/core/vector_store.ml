open Types

type document = {
  id : string;
  content : string;
  metadata : Yojson.Safe.t option;
}

type search_result = {
  doc : document;
  score : float;
}

type t =
  | Sqlite_vec_backend of { db : Sqlite3.db; mutex : Eio.Mutex.t; dimension : int }
  | Hnsw_backend of { index : Hnsw.t; mutex : Eio.Mutex.t; dimension : int }

(* === SQLite-vec backend (existing implementation) === *)

let sqlite_error_to_category msg =
  Internal ("SQLite: " ^ msg)

let exec_sql db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> Result.Ok ()
  | rc ->
    Result.Error
      (sqlite_error_to_category
         (Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db))

let load_extension db path =
  if not (Sqlite3.enable_load_extension db true) then
    Result.Error
      (Types.Internal
         "enable_load_extension returned false — \
          SQLITE_OMIT_LOAD_EXTENSION")
  else
    let rc =
      Sqlite3.exec db
        (Printf.sprintf "SELECT load_extension('%s');" path)
    in
    let _ = Sqlite3.enable_load_extension db false in
    if rc <> Sqlite3.Rc.OK then
      Result.Error
        (sqlite_error_to_category
           ("load_extension failed: " ^ Sqlite3.errmsg db))
    else Result.Ok ()

let init_schema db dimension =
  let documents_sql =
    "CREATE TABLE IF NOT EXISTS vs_documents (\
     \n  id TEXT PRIMARY KEY,\
     \n  content TEXT NOT NULL,\
     \n  metadata TEXT)"
  in
  let vec_sql =
    Printf.sprintf
      "CREATE VIRTUAL TABLE IF NOT EXISTS vs_items USING vec0(\
     \n  embedding float[%d] distance_metric=cosine)"
      dimension
  in
  match exec_sql db documents_sql with
  | Result.Error e -> Result.Error e
  | Result.Ok () ->
    (match exec_sql db vec_sql with
     | Result.Error e -> Result.Error e
     | Result.Ok () -> exec_sql db "CREATE INDEX IF NOT EXISTS idx_vs_doc_id ON vs_documents(id)")

let create ~db_path ~vec_extension_path ~dimension () =
  let db = Sqlite3.db_open db_path in
  match load_extension db vec_extension_path with
  | Result.Error e ->
    ignore (Sqlite3.db_close db);
    Result.Error e
  | Result.Ok () ->
    (match init_schema db dimension with
     | Result.Error e ->
       ignore (Sqlite3.db_close db);
       Result.Error e
     | Result.Ok () ->
       Result.Ok (Sqlite_vec_backend { db; mutex = Eio.Mutex.create (); dimension }))

let json_string_to_doc s =
  if s = "" || s = "NULL" then None
  else
    try Some (Yojson.Safe.from_string s)
    with _ -> None

(* === Backend dispatch === *)

let create_for_backend (backend : vector_store_backend) =
  match backend with
  | Vs_sqlite_vec { db_path; vec_extension_path; dimension } ->
    create ~db_path ~vec_extension_path ~dimension ()
  | Vs_hnsw { persist_path; dimension; m; ef_construction; ef_search } ->
    (match persist_path with
     | Some path when Sys.file_exists path ->
       (match Hnsw.load ~path with
        | Ok index -> Ok (Hnsw_backend { index; mutex = Eio.Mutex.create (); dimension })
        | Error e -> Error e)
     | _ ->
       (match Hnsw.create ~dimension ~m ~ef_construction ~ef_search
                ~distance_metric:`Cosine () with
        | Ok index -> Ok (Hnsw_backend { index; mutex = Eio.Mutex.create (); dimension })
        | Error e -> Error e))

let add t docs =
  match t with
  | Sqlite_vec_backend s ->
    if docs = [] then Result.Ok ()
    else
      let dim = s.dimension in
      List.iter
        (fun ({ id; _ }, vec) ->
          if Array.length vec <> dim then
            invalid_arg
              (Printf.sprintf
                 "Vector_store.add: vector dimension mismatch (expected %d, \
                  got %d for doc %s)"
                 dim (Array.length vec) id))
        docs;
      Eio.Mutex.use_rw s.mutex ~protect:true (fun () ->
        match exec_sql s.db "BEGIN TRANSACTION" with
        | Result.Error e -> Result.Error e
        | Result.Ok () ->
          let errors = ref [] in
          List.iter
            (fun ({ id; content; metadata }, vec) ->
              let meta_str =
                match metadata with
                | None -> ""
                | Some json -> Yojson.Safe.to_string json
              in
              let stmt =
                Sqlite3.prepare s.db
                  "INSERT OR REPLACE INTO vs_documents (id, content, metadata) \
                   VALUES (?, ?, ?)"
              in
              let _ = Sqlite3.bind_text stmt 1 id in
              let _ = Sqlite3.bind_text stmt 2 content in
              let _ = Sqlite3.bind_text stmt 3 meta_str in
              let rc = Sqlite3.step stmt in
              let _ = Sqlite3.finalize stmt in
              if rc <> Sqlite3.Rc.DONE then begin
                errors :=
                  sqlite_error_to_category
                    ("doc insert: " ^ Sqlite3.errmsg s.db)
                  :: !errors
              end;
              let rowid =
                Sqlite3.last_insert_rowid s.db
              in
              let vec_json =
                let buf = Buffer.create 256 in
                Buffer.add_string buf "[";
                Array.iteri
                  (fun i v ->
                    if i > 0 then Buffer.add_string buf ", ";
                    Buffer.add_string buf (string_of_float v))
                  vec;
                Buffer.add_string buf "]";
                Buffer.contents buf
              in
              let stmt2 =
                Sqlite3.prepare s.db
                  "INSERT OR REPLACE INTO vs_items (rowid, embedding) VALUES (?, \
                   ?)"
              in
              let _ = Sqlite3.bind stmt2 1 (Sqlite3.Data.INT rowid) in
              let _ =
                Sqlite3.bind_text stmt2 2 vec_json
              in
              let rc2 = Sqlite3.step stmt2 in
              let _ = Sqlite3.finalize stmt2 in
              if rc2 <> Sqlite3.Rc.DONE then begin
                errors :=
                  sqlite_error_to_category
                    ("vec insert: " ^ Sqlite3.errmsg s.db)
                  :: !errors
              end)
            docs;
          match !errors with
          | [] ->
            let _ = exec_sql s.db "COMMIT" in
            Result.Ok ()
          | e :: _ ->
            let _ = exec_sql s.db "ROLLBACK" in
            Result.Error e)
  | Hnsw_backend s ->
    if docs = [] then Result.Ok ()
    else
      Eio.Mutex.use_rw s.mutex ~protect:true (fun () ->
        let errors = ref [] in
        List.iter
          (fun ({ id; _ }, vec) ->
            match Hnsw.insert s.index ~id vec with
            | Ok () -> ()
            | Error e -> errors := e :: !errors)
          docs;
        match !errors with
        | [] -> Result.Ok ()
        | e :: _ -> Result.Error e)

let search t ~query ~k =
  match t with
  | Sqlite_vec_backend s ->
    if Array.length query <> s.dimension then
      invalid_arg
        (Printf.sprintf
           "Vector_store.search: query dimension mismatch (expected %d, got %d)"
           s.dimension (Array.length query));
    Eio.Mutex.use_ro s.mutex (fun () ->
      let vec_json =
        let buf = Buffer.create 256 in
        Buffer.add_string buf "[";
        Array.iteri
          (fun i v ->
            if i > 0 then Buffer.add_string buf ", ";
            Buffer.add_string buf (string_of_float v))
          query;
        Buffer.add_string buf "]";
        Buffer.contents buf
      in
      let sql =
        "SELECT d.id, d.content, d.metadata, v.distance \
         \nFROM vs_items v \
         \nJOIN vs_documents d ON d.rowid = v.rowid \
         \nWHERE v.embedding MATCH ? AND k = ? \
         \nORDER BY v.distance"
      in
      let stmt = Sqlite3.prepare s.db sql in
      let _ = Sqlite3.bind_text stmt 1 vec_json in
      let _ =
        Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int k))
      in
      let results = ref [] in
      let stop = ref false in
      while not !stop do
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          let id =
            match Sqlite3.column stmt 0 with
            | Sqlite3.Data.TEXT s -> s
            | other -> (
              match Sqlite3.Data.to_string other with
              | Some s -> s
              | None -> "")
          in
          let content =
            match Sqlite3.column stmt 1 with
            | Sqlite3.Data.TEXT s -> s
            | other -> (
              match Sqlite3.Data.to_string other with
              | Some s -> s
              | None -> "")
          in
          let metadata =
            match Sqlite3.column stmt 2 with
            | Sqlite3.Data.TEXT s -> json_string_to_doc s
            | _ -> None
          in
          let distance =
            match Sqlite3.column stmt 3 with
            | Sqlite3.Data.FLOAT f -> f
            | other -> (
              match Sqlite3.Data.to_float other with
              | Some f -> f
              | None -> 0.0)
          in
          let score = 1.0 -. distance in
          let doc = { id; content; metadata } in
          results := { doc; score } :: !results
        | Sqlite3.Rc.DONE -> stop := true
        | _ -> stop := true
      done;
      let _ = Sqlite3.finalize stmt in
      Result.Ok (List.rev !results))
  | Hnsw_backend s ->
    if Array.length query <> s.dimension then
      invalid_arg
        (Printf.sprintf
           "Vector_store.search: query dimension mismatch (expected %d, got %d)"
           s.dimension (Array.length query));
    Eio.Mutex.use_ro s.mutex (fun () ->
      let raw = Hnsw.search s.index ~query ~k in
      let results = List.map (fun (id, distance) ->
        let score = 1.0 -. distance in
        let doc = { id; content = ""; metadata = None } in
        { doc; score }
      ) raw in
      Result.Ok results)

let delete t ~ids =
  match t with
  | Sqlite_vec_backend s ->
    if ids = [] then Result.Ok ()
    else
      Eio.Mutex.use_rw s.mutex ~protect:true (fun () ->
        match exec_sql s.db "BEGIN TRANSACTION" with
        | Result.Error e -> Result.Error e
        | Result.Ok () ->
          List.iter
          (fun id ->
            let stmt =
              Sqlite3.prepare s.db
                "SELECT rowid FROM vs_documents WHERE id = ?"
            in
            let _ = Sqlite3.bind_text stmt 1 id in
            let rowid =
              match Sqlite3.step stmt with
              | Sqlite3.Rc.ROW ->
                let r =
                  match Sqlite3.column stmt 0 with
                  | Sqlite3.Data.INT n -> Some n
                  | _ -> None
                in
                let _ = Sqlite3.finalize stmt in
                r
              | _ ->
                let _ = Sqlite3.finalize stmt in
                None
            in
            match rowid with
            | None -> ()
            | Some rid ->
              let stmt2 =
                Sqlite3.prepare s.db
                  "DELETE FROM vs_items WHERE rowid = ?"
              in
              let _ = Sqlite3.bind stmt2 1 (Sqlite3.Data.INT rid) in
              let _ = Sqlite3.step stmt2 in
              let _ = Sqlite3.finalize stmt2 in
              let stmt3 =
                Sqlite3.prepare s.db
                  "DELETE FROM vs_documents WHERE id = ?"
              in
              let _ = Sqlite3.bind_text stmt3 1 id in
              let _ = Sqlite3.step stmt3 in
              let _ = Sqlite3.finalize stmt3 in
              ())
          ids;
        let _ = exec_sql s.db "COMMIT" in
        Result.Ok ())
  | Hnsw_backend s ->
    if ids = [] then Result.Ok ()
    else
      Eio.Mutex.use_rw s.mutex ~protect:true (fun () ->
        let errors = ref [] in
        List.iter (fun id ->
          match Hnsw.delete s.index ~id with
          | Ok () -> ()
          | Error e -> errors := e :: !errors
        ) ids;
        match !errors with
        | [] -> Result.Ok ()
        | e :: _ -> Result.Error e)

let close t =
  match t with
  | Sqlite_vec_backend s ->
    Eio.Mutex.use_rw s.mutex ~protect:true (fun () ->
      ignore (Sqlite3.db_close s.db))
  | Hnsw_backend s ->
    Eio.Mutex.use_rw s.mutex ~protect:true (fun () ->
      Hnsw.close s.index)
