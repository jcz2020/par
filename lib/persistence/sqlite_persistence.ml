(* — Persistence: SQLite backend *)

open Types

type t = {
  db : Sqlite3.db;
  mutex : Eio.Mutex.t;
}

let raw_sqlite3_db t = t.db

(* -------------------------------------------------------------------------- *)
(* Schema                                                                *)
(* -------------------------------------------------------------------------- *)

let exec_sql db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> Ok ()
  | rc -> Result.Error (Internal (Printf.sprintf "SQLite error: %s" (Sqlite3.Rc.to_string rc)))

let init_schema db =
  let core_statements = [
    {|CREATE TABLE IF NOT EXISTS events (
         id                TEXT PRIMARY KEY,
         task_id           TEXT NOT NULL,
         payload           TEXT NOT NULL,
         timestamp         REAL NOT NULL,
         idempotency_key   TEXT UNIQUE NOT NULL,
         session_id        TEXT NOT NULL DEFAULT '',
         actions_json      TEXT
       )|};
     {|CREATE TABLE IF NOT EXISTS task_states (
         id          TEXT PRIMARY KEY,
         state       TEXT NOT NULL,
         updated_at  REAL NOT NULL
       )|};
     {|CREATE TABLE IF NOT EXISTS workflow_states (
         id          TEXT PRIMARY KEY,
         workflow_id TEXT NOT NULL,
         status      TEXT NOT NULL,
         checkpoint  TEXT,
         updated_at  REAL NOT NULL
       )|};
     {|CREATE TABLE IF NOT EXISTS conversations (
         session_id     TEXT PRIMARY KEY,
         messages_json  TEXT NOT NULL,
         metadata_json  TEXT NOT NULL,
         updated_at     REAL NOT NULL,
         turn_count     INTEGER NOT NULL
       )|};
    {|CREATE TABLE IF NOT EXISTS workflow_definitions (
         workflow_id  TEXT PRIMARY KEY,
         def_json     TEXT NOT NULL,
         updated_at   REAL NOT NULL
       )|};
  ] in
  (match List.find_map (fun sql ->
     match exec_sql db sql with
     | Result.Error e -> Some (Result.Error e)
     | Ok () -> None
   ) core_statements with
   | Some e -> e
   | None ->
     let migrations = [
       {|ALTER TABLE events ADD COLUMN session_id TEXT NOT NULL DEFAULT ''|};
       {|ALTER TABLE events ADD COLUMN actions_json TEXT|};
     ] in
     List.iter (fun sql ->
       match exec_sql db sql with
       | Ok () -> ()
       | Result.Error _ -> ()
     ) migrations;
     let indexes = [
       {|CREATE INDEX IF NOT EXISTS idx_events_task_id ON events(task_id, timestamp)|};
       {|CREATE INDEX IF NOT EXISTS idx_events_session_id ON events(session_id, timestamp)|};
       {|CREATE INDEX IF NOT EXISTS conv_updated ON conversations(updated_at DESC)|};
     ] in
     List.iter (fun sql -> ignore (exec_sql db sql)) indexes;
     Ok ())

let _prune_raw db ~ttl_seconds =
  let cutoff = Unix.gettimeofday () -. ttl_seconds in
  exec_sql db (Printf.sprintf "DELETE FROM events WHERE timestamp < %f" cutoff)

let prune_old_events t ~ttl_seconds =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    _prune_raw t.db ~ttl_seconds)

let default_retention_ttl = 7. *. 24. *. 60. *. 60.

(* -------------------------------------------------------------------------- *)
(* Connection init                                                       *)
(* -------------------------------------------------------------------------- *)

let create ?(retention_ttl = default_retention_ttl) db_path =
  let db = Sqlite3.db_open db_path in
  match init_schema db with
  | Ok () ->
    (match retention_ttl with
     | ttl when ttl > 0.0 ->
       (match _prune_raw db ~ttl_seconds:ttl with
        | Ok () -> Ok { db; mutex = Eio.Mutex.create () }
        | Result.Error e ->
          ignore (Sqlite3.db_close db);
          Result.Error e)
     | _ -> Ok { db; mutex = Eio.Mutex.create () })
  | Result.Error e ->
    (if not (Sqlite3.db_close db) then
       Logs.err (fun m -> m "sqlite_persistence: db_close failed during create error path"));
    Result.Error e

let close t =
  if not (Sqlite3.db_close t.db) then
    Logs.err (fun m -> m "sqlite_persistence: db_close failed")

(* -------------------------------------------------------------------------- *)
(* Event extraction helpers                                                *)
(* -------------------------------------------------------------------------- *)

let extract_task_id = Persistence_common.extract_task_id
let extract_session_id = Persistence_common.extract_session_id

(* -------------------------------------------------------------------------- *)
(* Write operations                                                      *)
(* -------------------------------------------------------------------------- *)

let insert_event db (envelope : event_envelope) =
  let ev = envelope.payload in
  let session_id = extract_session_id envelope in
  let stmt =
    Sqlite3.prepare db
      "INSERT OR IGNORE INTO events (id, task_id, payload, timestamp, idempotency_key, session_id, actions_json) \
       VALUES (?, ?, ?, ?, ?, ?, NULL)"
  in
  let task_id = extract_task_id ev in
  let ts = envelope.metadata.timestamp in
  let id = envelope.id in
  let idem_key = envelope.idempotency_key in
  let json = Yojson.Safe.to_string (event_to_yojson ev) in
  let _ = Sqlite3.bind_text stmt 1 id in
  let _ = Sqlite3.bind_text stmt 2 task_id in
  let _ = Sqlite3.bind_text stmt 3 json in
  let _ = Sqlite3.bind_double stmt 4 ts in
  let _ = Sqlite3.bind_text stmt 5 idem_key in
  let _ = Sqlite3.bind_text stmt 6 session_id in
  let step_result = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  match step_result with
  | Sqlite3.Rc.DONE | Sqlite3.Rc.ROW -> Ok ()
  | rc -> Result.Error (Internal (Printf.sprintf "Event insert: %s" (Sqlite3.Rc.to_string rc)))

let upsert_task_state db (ts : task_state) =
  let stmt =
    Sqlite3.prepare db
      "INSERT OR REPLACE INTO task_states (id, state, updated_at) VALUES (?, ?, ?)"
  in
  let id = Task_id.to_string ts.id in
  let json = Yojson.Safe.to_string (task_state_to_yojson ts) in
  let _ = Sqlite3.bind_text stmt 1 id in
  let _ = Sqlite3.bind_text stmt 2 json in
  let _ = Sqlite3.bind_double stmt 3 ts.updated_at in
  let step_result = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  match step_result with
  | Sqlite3.Rc.DONE | Sqlite3.Rc.ROW -> Ok ()
  | rc -> Result.Error (Internal (Printf.sprintf "Task upsert: %s" (Sqlite3.Rc.to_string rc)))

(* -------------------------------------------------------------------------- *)
(* PERSISTENCE_SERVICE implementation                                      *)
(* -------------------------------------------------------------------------- *)

let save_events t events =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    let results = List.map (insert_event t.db) events in
    match List.find_map (function Result.Error e -> Some e | _ -> None) results with
    | Some e -> Result.Error e
    | None -> Ok ()
  )

let load_events t task_id =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let tid = Task_id.to_string task_id in
    let stmt =
      Sqlite3.prepare t.db
        "SELECT payload FROM events WHERE task_id = ? ORDER BY timestamp ASC"
    in
    let _ = Sqlite3.bind_text stmt 1 tid in
    let acc = ref [] in
    let result =
      let stop = ref false in
      let error = ref None in
      while not !stop do
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          let payload = Sqlite3.column_text stmt 0 in
          (match event_of_yojson (Yojson.Safe.from_string payload) with
          | Ok ev -> acc := ev :: !acc
          | Error _ -> ()
          | exception Yojson.Json_error _ -> ())
        | Sqlite3.Rc.DONE -> stop := true
        | rc ->
          stop := true;
          error := Some (Result.Error (Internal (Printf.sprintf "Load events: %s" (Sqlite3.Rc.to_string rc))))
      done;
      match !error with
      | Some e -> e
      | None -> Ok (List.rev !acc)
    in
    let _ = Sqlite3.finalize stmt in
    result
  )

let load_events_by_session t session_id =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let stmt =
      Sqlite3.prepare t.db
        "SELECT payload FROM events WHERE session_id = ? ORDER BY timestamp ASC"
    in
    let _ = Sqlite3.bind_text stmt 1 session_id in
    let acc = ref [] in
    let result =
      let stop = ref false in
      let error = ref None in
      while not !stop do
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          let payload = Sqlite3.column_text stmt 0 in
          (match event_of_yojson (Yojson.Safe.from_string payload) with
          | Ok ev -> acc := ev :: !acc
          | Error _ -> ()
          | exception Yojson.Json_error _ -> ())
        | Sqlite3.Rc.DONE -> stop := true
        | rc ->
          stop := true;
          error := Some (Result.Error (Internal (Printf.sprintf "Load events by session: %s" (Sqlite3.Rc.to_string rc))))
      done;
      match !error with
      | Some e -> e
      | None -> Ok (List.rev !acc)
    in
    let _ = Sqlite3.finalize stmt in
    result
  )

let load_sessions t limit =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let stmt =
      Sqlite3.prepare t.db
        "SELECT session_id, COUNT(*) AS cnt, MIN(timestamp) AS first_at, MAX(timestamp) AS last_at \
         FROM events GROUP BY session_id ORDER BY last_at DESC LIMIT ?"
    in
    let _ = Sqlite3.bind_int stmt 1 limit in
    let acc = ref [] in
    let result =
      let stop = ref false in
      let error = ref None in
      while not !stop do
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          let session_id = Sqlite3.column_text stmt 0 in
          let count = Sqlite3.column_int stmt 1 in
          let first_at = Sqlite3.column_double stmt 2 in
          let last_at = Sqlite3.column_double stmt 3 in
          acc := { session_id; event_count = count; first_event_at = first_at; last_event_at = last_at } :: !acc
        | Sqlite3.Rc.DONE -> stop := true
        | rc ->
          stop := true;
          error := Some (Result.Error (Internal (Printf.sprintf "Load sessions: %s" (Sqlite3.Rc.to_string rc))))
      done;
      match !error with
      | Some e -> e
      | None -> Ok (List.rev !acc)
    in
    let _ = Sqlite3.finalize stmt in
    result
  )

let load_recent_events t limit =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let stmt =
      Sqlite3.prepare t.db
        "SELECT payload FROM events ORDER BY timestamp DESC LIMIT ?"
    in
    let _ = Sqlite3.bind_int stmt 1 limit in
    let acc = ref [] in
    let result =
      let stop = ref false in
      let error = ref None in
      while not !stop do
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          let payload = Sqlite3.column_text stmt 0 in
          (match event_of_yojson (Yojson.Safe.from_string payload) with
          | Ok ev -> acc := ev :: !acc
          | Error _ -> ()
          | exception Yojson.Json_error _ -> ())
        | Sqlite3.Rc.DONE -> stop := true
        | rc ->
          stop := true;
          error := Some (Result.Error (Internal (Printf.sprintf "Load recent: %s" (Sqlite3.Rc.to_string rc))))
      done;
      match !error with
      | Some e -> e
      | None -> Ok (List.rev !acc)
    in
    let _ = Sqlite3.finalize stmt in
    result
  )

let save_task_state t ts =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    upsert_task_state t.db ts
  )

let load_task_state t task_id =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let tid = Task_id.to_string task_id in
    let stmt =
      Sqlite3.prepare t.db "SELECT state FROM task_states WHERE id = ?"
    in
    let _ = Sqlite3.bind_text stmt 1 tid in
    let result =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let state_json = Sqlite3.column_text stmt 0 in
        (match task_state_of_yojson (Yojson.Safe.from_string state_json) with
        | Ok ts -> Ok (Some ts)
        | Error msg ->
          Result.Error (Internal (Printf.sprintf "Task state decode: %s" msg)))
      | Sqlite3.Rc.DONE -> Ok None
      | rc -> Result.Error (Internal (Printf.sprintf "Load task state: %s" (Sqlite3.Rc.to_string rc)))
    in
    let _ = Sqlite3.finalize stmt in
    result
  )

(* -------------------------------------------------------------------------- *)
(* Workflow state persistence                                             *)
(* -------------------------------------------------------------------------- *)

let upsert_workflow_state db run_id status checkpoint =
  let id = Workflow_run_id.to_string run_id in
  let status_str = match status with
    | Wf_pending -> "pending"
    | Wf_running -> "running"
    | Wf_suspended _ -> "suspended"
    | Wf_completed _ -> "completed"
    | Wf_failed _ -> "failed"
  in
  let checkpoint_json = match checkpoint with
    | Some cp -> Some (Yojson.Safe.to_string (workflow_checkpoint_to_yojson cp))
    | None -> None
  in
  let now = Unix.gettimeofday () in
  let stmt =
    Sqlite3.prepare db
      "INSERT OR REPLACE INTO workflow_states (id, workflow_id, status, checkpoint, updated_at) \
       VALUES (?, ?, ?, ?, ?)"
  in
  let _ = Sqlite3.bind_text stmt 1 id in
  let _ = Sqlite3.bind_text stmt 2 id in
  let _ = Sqlite3.bind_text stmt 3 status_str in
   (match checkpoint_json with
    | Some json ->
      (match Sqlite3.bind_text stmt 4 json with
       | Sqlite3.Rc.OK -> ()
       | rc -> Logs.err (fun m -> m "sqlite_persistence: bind_text failed: %s" (Sqlite3.Rc.to_string rc)))
    | None ->
      (match Sqlite3.bind stmt 4 Sqlite3.Data.NULL with
       | Sqlite3.Rc.OK -> ()
       | rc -> Logs.err (fun m -> m "sqlite_persistence: bind failed: %s" (Sqlite3.Rc.to_string rc))));
  let _ = Sqlite3.bind_double stmt 5 now in
  let step_result = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  match step_result with
  | Sqlite3.Rc.DONE | Sqlite3.Rc.ROW -> Ok ()
  | rc -> Result.Error (Internal (Printf.sprintf "Workflow state upsert: %s" (Sqlite3.Rc.to_string rc)))

let load_workflow_state_from_db db run_id =
  let id = Workflow_run_id.to_string run_id in
  let stmt =
    Sqlite3.prepare db "SELECT checkpoint FROM workflow_states WHERE id = ?"
  in
  let _ = Sqlite3.bind_text stmt 1 id in
  let result =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      (match Sqlite3.column stmt 0 with
       | Sqlite3.Data.TEXT json ->
         (match workflow_checkpoint_of_yojson (Yojson.Safe.from_string json) with
          | Ok cp -> Ok (Some cp)
          | Error msg ->
            Result.Error (Internal (Printf.sprintf "Workflow checkpoint decode: %s" msg)))
       | Sqlite3.Data.NULL -> Ok None
       | _ -> Result.Error (Internal "Workflow checkpoint: unexpected column type"))
    | Sqlite3.Rc.DONE -> Ok None
    | rc -> Result.Error (Internal (Printf.sprintf "Load workflow state: %s" (Sqlite3.Rc.to_string rc)))
  in
  let _ = Sqlite3.finalize stmt in
  result

let save_workflow_state t run_id status checkpoint =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    upsert_workflow_state t.db run_id status checkpoint
  )

let load_workflow_state t run_id =
  Eio.Mutex.use_ro t.mutex (fun () ->
    load_workflow_state_from_db t.db run_id
  )

 let load_all_suspended_workflows t =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let stmt =
      Sqlite3.prepare t.db
        "SELECT id, checkpoint FROM workflow_states WHERE status = 'suspended'"
    in
    let acc = ref [] in
    let result =
      let stop = ref false in
      let error = ref None in
      while not !stop do
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          let id_str = Sqlite3.column_text stmt 0 in
          let checkpoint_json = Sqlite3.column_text stmt 1 in
          let run_id = Workflow_run_id.of_string id_str in
          (match workflow_checkpoint_of_yojson (Yojson.Safe.from_string checkpoint_json) with
           | Ok cp -> acc := (run_id, Wf_suspended cp) :: !acc
           | Error msg ->
             Logs.err (fun m -> m "load_all_suspended: skipping run %s, decode error: %s"
                          id_str msg))
        | Sqlite3.Rc.DONE -> stop := true
        | rc ->
          stop := true;
          error := Some (Result.Error (Internal (Printf.sprintf "Load suspended: %s" (Sqlite3.Rc.to_string rc))))
      done;
      match !error with
      | Some e -> e
      | None -> Ok (List.rev !acc)
    in
    let _ = Sqlite3.finalize stmt in
    result
  )

let save_workflow_def t (workflow_id : string) (def_json : Yojson.Safe.t) =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    let json = Yojson.Safe.to_string def_json in
    let now = Unix.gettimeofday () in
    let stmt =
      Sqlite3.prepare t.db
        "INSERT OR REPLACE INTO workflow_definitions (workflow_id, def_json, updated_at) \
         VALUES (?, ?, ?)"
    in
    let _ = Sqlite3.bind_text stmt 1 workflow_id in
    let _ = Sqlite3.bind_text stmt 2 json in
    let _ = Sqlite3.bind_double stmt 3 now in
    let step_result = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    match step_result with
    | Sqlite3.Rc.DONE | Sqlite3.Rc.ROW -> Ok ()
    | rc -> Result.Error (Internal (Printf.sprintf "workflow_def upsert: %s" (Sqlite3.Rc.to_string rc)))
  )

let load_all_workflow_defs t =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let stmt =
      Sqlite3.prepare t.db
        "SELECT workflow_id, def_json FROM workflow_definitions"
    in
    let acc = ref [] in
    let result =
      let stop = ref false in
      let error = ref None in
      while not !stop do
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          let id_str = Sqlite3.column_text stmt 0 in
          let def_json = Sqlite3.column_text stmt 1 in
          acc := (id_str, Yojson.Safe.from_string def_json) :: !acc
        | Sqlite3.Rc.DONE -> stop := true
        | rc ->
          stop := true;
          error := Some (Result.Error (Internal (Printf.sprintf "Load workflow defs: %s" (Sqlite3.Rc.to_string rc))))
      done;
      match !error with
      | Some e -> e
      | None -> Ok (List.rev !acc)
    in
    let _ = Sqlite3.finalize stmt in
    result
  )

let transaction t f =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    match exec_sql t.db "BEGIN IMMEDIATE" with
    | Result.Error e -> Result.Error e
    | Ok () ->
      match f t with
      | result ->
        (match exec_sql t.db "COMMIT" with
        | Ok () -> Ok result
        | Result.Error e -> Result.Error e)
      | exception ex ->
        (match exec_sql t.db "ROLLBACK" with
         | Ok () -> ()
         | Result.Error e ->
           Logs.err (fun m -> m "sqlite_persistence: ROLLBACK failed: %s"
               (error_category_to_yojson e |> Yojson.Safe.to_string)));
        Result.Error (Internal (Printexc.to_string ex))
  )

let conversation_messages_to_json (msgs : Types.message list) : string =
  Yojson.Safe.to_string
    (`List (List.map Types.message_to_yojson msgs))

let conversation_metadata_to_json (md : (string * Yojson.Safe.t) list) : string =
  Yojson.Safe.to_string
    (`Assoc (List.map (fun (k, v) -> (k, v)) md))

let json_to_messages (s : string) : (Types.message list, string) result =
  match Yojson.Safe.from_string s with
  | `List xs ->
    let rec loop = function
      | [] -> Ok []
      | x :: rest ->
        (match Types.message_of_yojson x with
         | Ok m ->
           (match loop rest with
            | Ok rest -> Ok (m :: rest)
            | Error e -> Error e)
         | Error e -> Error e)
    in
    loop xs
  | _ -> Error "expected JSON array for messages"

let json_to_metadata (s : string) : ((string * Yojson.Safe.t) list, string) result =
  match Yojson.Safe.from_string s with
  | `Assoc xs -> Ok (List.map (fun (k, v) -> (k, v)) xs)
  | _ -> Error "expected JSON object for metadata"

let save_conversation t session_id (conv : Types.conversation) =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    let msgs_json = conversation_messages_to_json conv.Types.messages in
    let md_json = conversation_metadata_to_json conv.Types.metadata in
    let now = Unix.gettimeofday () in
    let turn_count = List.length conv.Types.messages in
    let stmt =
      Sqlite3.prepare t.db
        "INSERT OR REPLACE INTO conversations \
         (session_id, messages_json, metadata_json, updated_at, turn_count) \
         VALUES (?, ?, ?, ?, ?)"
    in
    let _ = Sqlite3.bind_text stmt 1 session_id in
    let _ = Sqlite3.bind_text stmt 2 msgs_json in
    let _ = Sqlite3.bind_text stmt 3 md_json in
    let _ = Sqlite3.bind_double stmt 4 now in
    let _ = Sqlite3.bind_int stmt 5 turn_count in
    let step_result = Sqlite3.step stmt in
    let _ = Sqlite3.finalize stmt in
    match step_result with
    | Sqlite3.Rc.DONE | Sqlite3.Rc.ROW -> Ok ()
    | rc -> Result.Error (Internal (Printf.sprintf "Conversation save: %s" (Sqlite3.Rc.to_string rc)))
  )

let load_conversation t session_id =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let stmt =
      Sqlite3.prepare t.db
        "SELECT messages_json, metadata_json FROM conversations WHERE session_id = ?"
    in
    let _ = Sqlite3.bind_text stmt 1 session_id in
    let result =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let msgs_raw = Sqlite3.column_text stmt 0 in
        let md_raw = Sqlite3.column_text stmt 1 in
        (match json_to_messages msgs_raw, json_to_metadata md_raw with
         | Ok msgs, Ok md -> Ok (Some { Types.messages = msgs; metadata = md })
         | Error msg, _ | _, Error msg ->
           Result.Error (Internal (Printf.sprintf "Conversation decode: %s" msg)))
      | Sqlite3.Rc.DONE -> Ok None
      | rc -> Result.Error (Internal (Printf.sprintf "Conversation load: %s" (Sqlite3.Rc.to_string rc)))
    in
    let _ = Sqlite3.finalize stmt in
    result
  )

let load_most_recent_conversation t =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let stmt =
      Sqlite3.prepare t.db
        "SELECT session_id, messages_json, metadata_json \
         FROM conversations ORDER BY updated_at DESC LIMIT 1"
    in
    let result =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let session_id = Sqlite3.column_text stmt 0 in
        let msgs_raw = Sqlite3.column_text stmt 1 in
        let md_raw = Sqlite3.column_text stmt 2 in
        (match json_to_messages msgs_raw, json_to_metadata md_raw with
         | Ok msgs, Ok md ->
           Ok (Some (session_id, { Types.messages = msgs; metadata = md }))
         | Error msg, _ | _, Error msg ->
           Result.Error (Internal (Printf.sprintf "Conversation decode (most-recent): %s" msg)))
      | Sqlite3.Rc.DONE -> Ok None
      | rc -> Result.Error (Internal (Printf.sprintf "Conversation load-most-recent: %s" (Sqlite3.Rc.to_string rc)))
    in
    let _ = Sqlite3.finalize stmt in
    result
  )
