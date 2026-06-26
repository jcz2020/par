(* — Persistence: PostgreSQL backend *)

open Par.Types

type t = {
  db : Postgresql.connection;
  mutex : Eio.Mutex.t;
}

let exec_sql (db : Postgresql.connection) sql =
  let res = db#exec sql in
  match res#status with
  | Postgresql.Command_ok | Postgresql.Tuples_ok -> Ok ()
  | _ -> Result.Error (Internal (Printf.sprintf "PostgreSQL error: %s" res#error))

let init_schema (db : Postgresql.connection) =
  let statements = [
    {|CREATE TABLE IF NOT EXISTS events (
         id                TEXT PRIMARY KEY,
         task_id           TEXT NOT NULL,
         payload           JSONB NOT NULL,
         timestamp         DOUBLE PRECISION NOT NULL,
         idempotency_key   TEXT UNIQUE NOT NULL,
         delivery_attempt  INTEGER DEFAULT 0,
         session_id        TEXT NOT NULL DEFAULT '',
         actions_json      TEXT
       )|};
    {|CREATE INDEX IF NOT EXISTS idx_events_task_id ON events(task_id)|};
    {|CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp)|};
    {|CREATE INDEX IF NOT EXISTS idx_events_session_id ON events(session_id)|};
     {|CREATE TABLE IF NOT EXISTS task_states (
          id          TEXT PRIMARY KEY,
          state       JSONB NOT NULL,
          updated_at  DOUBLE PRECISION NOT NULL
        )|};
     {|CREATE TABLE IF NOT EXISTS workflow_states (
           id          TEXT PRIMARY KEY,
           workflow_id TEXT NOT NULL,
           status      TEXT NOT NULL,
           checkpoint  JSONB,
           updated_at  DOUBLE PRECISION NOT NULL
         )|};
     {|CREATE TABLE IF NOT EXISTS conversations (
          session_id    TEXT PRIMARY KEY,
          messages_json JSONB NOT NULL,
          metadata_json JSONB NOT NULL,
          updated_at    DOUBLE PRECISION NOT NULL,
          turn_count    INTEGER NOT NULL
        )|};
     {|CREATE INDEX IF NOT EXISTS conv_updated ON conversations(updated_at DESC)|};
   ] in
  List.find_map (fun sql ->
    match exec_sql db sql with
    | Result.Error e -> Some (Result.Error e)
    | Ok () -> None
  ) statements
  |> function
  | Some e -> e
  | None ->
    let migrations = [
      {|ALTER TABLE events ADD COLUMN IF NOT EXISTS session_id TEXT NOT NULL DEFAULT ''|};
      {|ALTER TABLE events ADD COLUMN IF NOT EXISTS actions_json TEXT|};
    ] in
    List.iter (fun sql -> ignore (exec_sql db sql)) migrations;
    Ok ()

let default_retention_ttl = 7. *. 24. *. 60. *. 60.

let _prune_raw db ~ttl_seconds =
  let cutoff = Unix.gettimeofday () -. ttl_seconds in
  exec_sql db (Printf.sprintf "DELETE FROM events WHERE timestamp < %f" cutoff)

let prune_old_events t ~ttl_seconds =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    _prune_raw t.db ~ttl_seconds)

let create ?(retention_ttl = default_retention_ttl) conninfo =
  let db =
    try new Postgresql.connection ~conninfo ()
    with Postgresql.Error (Connection_failure msg) ->
      failwith msg
  in
  match db#status with
  | Postgresql.Ok ->
    (match init_schema db with
    | Ok () ->
      if retention_ttl > 0.0 then
        ignore (_prune_raw db ~ttl_seconds:retention_ttl);
      Ok { db; mutex = Eio.Mutex.create () }
    | Result.Error e -> db#finish; Result.Error e)
  | _ ->
    let msg = db#error_message in
    db#finish;
    Result.Error (Internal (Printf.sprintf "PostgreSQL connection: %s" msg))

let close t = t.db#finish

let extract_task_id = Par.Persistence_common.extract_task_id
let extract_session_id = Par.Persistence_common.extract_session_id

let insert_event (db : Postgresql.connection) (envelope : event_envelope) =
  let ev = envelope.payload in
  let session_id = extract_session_id envelope in
  let task_id = extract_task_id ev in
  let ts = envelope.metadata.timestamp in
  let id = envelope.id in
  let idem_key = envelope.idempotency_key in
  let json = Yojson.Safe.to_string (event_to_yojson ev) in
  let res =
    db#exec
      ~params:[| id; task_id; json; string_of_float ts; idem_key; session_id |]
      "INSERT INTO events (id, task_id, payload, timestamp, idempotency_key, session_id) \
       VALUES ($1, $2, $3::jsonb, $4, $5, $6) \
       ON CONFLICT (idempotency_key) DO NOTHING"
  in
  match res#status with
  | Postgresql.Command_ok | Postgresql.Tuples_ok -> Ok ()
  | _ -> Result.Error (Internal (Printf.sprintf "Event insert: %s" res#error))

let upsert_task_state (db : Postgresql.connection) (ts : task_state) =
  let id = Task_id.to_string ts.id in
  let json = Yojson.Safe.to_string (task_state_to_yojson ts) in
  let res =
    db#exec
      ~params:[| id; json; string_of_float ts.updated_at |]
      "INSERT INTO task_states (id, state, updated_at) \
       VALUES ($1, $2::jsonb, $3) \
       ON CONFLICT (id) DO UPDATE SET state = $2::jsonb, updated_at = $3"
  in
  match res#status with
  | Postgresql.Command_ok | Postgresql.Tuples_ok -> Ok ()
  | _ -> Result.Error (Internal (Printf.sprintf "Task upsert: %s" res#error))

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
    let res =
      t.db#exec
        ~params:[| tid |]
        "SELECT payload::text FROM events WHERE task_id = $1 ORDER BY timestamp ASC"
    in
    match res#status with
    | Postgresql.Tuples_ok ->
      let acc = ref [] in
      for i = 0 to res#ntuples - 1 do
        let payload = res#getvalue i 0 in
        (match event_of_yojson (Yojson.Safe.from_string payload) with
        | Ok ev -> acc := ev :: !acc
        | Error _ -> ()
        | exception Yojson.Json_error _ -> ())
      done;
      Ok (List.rev !acc)
    | _ -> Result.Error (Internal (Printf.sprintf "Load events: %s" res#error))
  )

let load_events_by_session t session_id =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let res =
      t.db#exec
        ~params:[| session_id |]
        "SELECT payload::text FROM events WHERE session_id = $1 ORDER BY timestamp ASC"
    in
    match res#status with
    | Postgresql.Tuples_ok ->
      let acc = ref [] in
      for i = 0 to res#ntuples - 1 do
        let payload = res#getvalue i 0 in
        (match event_of_yojson (Yojson.Safe.from_string payload) with
        | Ok ev -> acc := ev :: !acc
        | Error _ -> ()
        | exception Yojson.Json_error _ -> ())
      done;
      Ok (List.rev !acc)
    | _ -> Result.Error (Internal (Printf.sprintf "Load events by session: %s" res#error))
  )

let load_sessions t limit =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let res =
      t.db#exec
        ~params:[| string_of_int limit |]
        "SELECT session_id, COUNT(*) AS cnt, MIN(timestamp) AS first_at, MAX(timestamp) AS last_at \
         FROM events GROUP BY session_id ORDER BY last_at DESC LIMIT $1"
    in
    match res#status with
    | Postgresql.Tuples_ok ->
      let acc = ref [] in
      for i = 0 to res#ntuples - 1 do
        let session_id = res#getvalue i 0 in
        let count = int_of_string (res#getvalue i 1) in
        let first_at = float_of_string (res#getvalue i 2) in
        let last_at = float_of_string (res#getvalue i 3) in
        acc := { session_id; event_count = count; first_event_at = first_at; last_event_at = last_at } :: !acc
      done;
      Ok (List.rev !acc)
    | _ -> Result.Error (Internal (Printf.sprintf "Load sessions: %s" res#error))
  )

let load_recent_events t limit =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let res =
      t.db#exec
        ~params:[| string_of_int limit |]
        "SELECT payload::text FROM events ORDER BY timestamp DESC LIMIT $1"
    in
    match res#status with
    | Postgresql.Tuples_ok ->
      let acc = ref [] in
      for i = 0 to res#ntuples - 1 do
        let payload = res#getvalue i 0 in
        (match event_of_yojson (Yojson.Safe.from_string payload) with
        | Ok ev -> acc := ev :: !acc
        | Error _ -> ()
        | exception Yojson.Json_error _ -> ())
      done;
      Ok (List.rev !acc)
    | _ -> Result.Error (Internal (Printf.sprintf "Load recent: %s" res#error))
  )

let save_task_state t ts =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    upsert_task_state t.db ts
  )

let load_task_state t task_id =
  Eio.Mutex.use_ro t.mutex (fun () ->
    let tid = Task_id.to_string task_id in
    let res =
      t.db#exec
        ~params:[| tid |]
        "SELECT state::text FROM task_states WHERE id = $1"
    in
    match res#status with
    | Postgresql.Tuples_ok ->
      (if res#ntuples = 0 then Ok None
       else
         let state_json = res#getvalue 0 0 in
         (match task_state_of_yojson (Yojson.Safe.from_string state_json) with
         | Ok ts -> Ok (Some ts)
         | Error msg ->
           Result.Error (Internal (Printf.sprintf "Task state decode: %s" msg))))
    | Postgresql.Command_ok -> Ok None
    | _ -> Result.Error (Internal (Printf.sprintf "Load task state: %s" res#error))
  )

(* -------------------------------------------------------------------------- *)
(* Workflow state persistence                                             *)
(* -------------------------------------------------------------------------- *)

let upsert_workflow_state (db : Postgresql.connection) run_id status checkpoint =
  let id = Workflow_run_id.to_string run_id in
  let status_str = match status with
    | Wf_pending -> "pending"
    | Wf_running -> "running"
    | Wf_suspended _ -> "suspended"
    | Wf_completed _ -> "completed"
    | Wf_failed _ -> "failed"
  in
  let now = Unix.gettimeofday () in
  let params = match checkpoint with
    | Some cp ->
      let json = Yojson.Safe.to_string (workflow_checkpoint_to_yojson cp) in
      [| id; id; status_str; json; string_of_float now |]
    | None ->
      [| id; id; status_str; string_of_float now |]
  in
  let query = match checkpoint with
    | Some _ ->
      "INSERT INTO workflow_states (id, workflow_id, status, checkpoint, updated_at) \
       VALUES ($1, $2, $3, $4::jsonb, $5) \
       ON CONFLICT (id) DO UPDATE SET status = $3, checkpoint = $4::jsonb, updated_at = $5"
    | None ->
      "INSERT INTO workflow_states (id, workflow_id, status, checkpoint, updated_at) \
       VALUES ($1, $2, $3, NULL, $4) \
       ON CONFLICT (id) DO UPDATE SET status = $3, checkpoint = NULL, updated_at = $4"
  in
  let res = db#exec ~params query in
  match res#status with
  | Postgresql.Command_ok | Postgresql.Tuples_ok -> Ok ()
  | _ -> Result.Error (Internal (Printf.sprintf "Workflow state upsert: %s" res#error))

let load_workflow_state_from_db (db : Postgresql.connection) run_id =
  let id = Workflow_run_id.to_string run_id in
  let res =
    db#exec
      ~params:[| id |]
      "SELECT checkpoint::text FROM workflow_states WHERE id = $1"
  in
  match res#status with
  | Postgresql.Tuples_ok ->
    (if res#ntuples = 0 then Ok None
     else
       let col = res#getvalue 0 0 in
       if col = "" || col = "null" then Ok None
       else
         (match workflow_checkpoint_of_yojson (Yojson.Safe.from_string col) with
          | Ok cp -> Ok (Some cp)
          | Error msg ->
            Result.Error (Internal (Printf.sprintf "Workflow checkpoint decode: %s" msg))))
  | Postgresql.Command_ok -> Ok None
  | _ -> Result.Error (Internal (Printf.sprintf "Load workflow state: %s" res#error))

let save_workflow_state t run_id status checkpoint =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    upsert_workflow_state t.db run_id status checkpoint
  )

let load_workflow_state t run_id =
  Eio.Mutex.use_ro t.mutex (fun () ->
    load_workflow_state_from_db t.db run_id
  )

let transaction t f =
  Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
    match exec_sql t.db "BEGIN" with
    | Result.Error e -> Result.Error e
    | Ok () ->
      (match f t with
      | result ->
        (match exec_sql t.db "COMMIT" with
        | Ok () -> Ok result
        | Result.Error e -> Result.Error e)
      | exception ex ->
        (match exec_sql t.db "ROLLBACK" with
         | Ok () -> ()
         | Result.Error e ->
           Logs.err (fun m -> m "postgres_persistence: ROLLBACK failed: %s"
               (error_category_to_yojson e |> Yojson.Safe.to_string)));
        Result.Error (Internal (Printexc.to_string ex)))
  )
