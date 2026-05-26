(* §7 — Persistence: PostgreSQL backend *)

open Par_core.Types

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
         delivery_attempt  INTEGER DEFAULT 0
       )|};
    {|CREATE INDEX IF NOT EXISTS idx_events_task_id ON events(task_id)|};
    {|CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp)|};
    {|CREATE TABLE IF NOT EXISTS task_states (
         id          TEXT PRIMARY KEY,
         state       JSONB NOT NULL,
         updated_at  DOUBLE PRECISION NOT NULL
       )|};
  ] in
  List.find_map (fun sql ->
    match exec_sql db sql with
    | Result.Error e -> Some (Result.Error e)
    | Ok () -> None
  ) statements
  |> function
  | Some e -> e
  | None -> Ok ()

let create conninfo =
  let db =
    try new Postgresql.connection ~conninfo ()
    with Postgresql.Error (Connection_failure msg) ->
      failwith msg
  in
  match db#status with
  | Postgresql.Ok ->
    (match init_schema db with
    | Ok () -> Ok { db; mutex = Eio.Mutex.create () }
    | Result.Error e -> db#finish; Result.Error e)
  | _ ->
    let msg = db#error_message in
    db#finish;
    Result.Error (Internal (Printf.sprintf "PostgreSQL connection: %s" msg))

let close t = t.db#finish

let extract_task_id : event -> string = function
  | Task_created { task_id; _ } -> Task_id.to_string task_id
  | Task_started { task_id } -> Task_id.to_string task_id
  | Task_completed { task_id; _ } -> Task_id.to_string task_id
  | Task_failed { task_id; _ } -> Task_id.to_string task_id
  | Task_cancelled { task_id; _ } -> Task_id.to_string task_id
  | Task_suspended { task_id } -> Task_id.to_string task_id
  | Task_resumed { task_id } -> Task_id.to_string task_id
  | Llm_request_sent { task_id; _ } -> Task_id.to_string task_id
  | Llm_response_received { task_id; _ } -> Task_id.to_string task_id
  | Tool_invoked { task_id; _ } -> Task_id.to_string task_id
  | Tool_completed { task_id; _ } -> Task_id.to_string task_id
  | Tool_failed { task_id; _ } -> Task_id.to_string task_id
  | Workflow_started { workflow_run_id } -> Workflow_run_id.to_string workflow_run_id
  | Workflow_step_completed { step_id } -> step_id
  | Workflow_completed { workflow_run_id } -> Workflow_run_id.to_string workflow_run_id
  | Workflow_failed { workflow_run_id; _ } -> Workflow_run_id.to_string workflow_run_id
  | Approval_requested _ -> ""
  | Approval_granted _ -> ""
  | Approval_timeout -> ""
  | Shutdown_initiated -> ""
  | Shutdown_completed _ -> ""

let insert_event (db : Postgresql.connection) ev =
  let task_id = extract_task_id ev in
  let ts = Unix.gettimeofday () in
  let id = Printf.sprintf "evt_%s_%.6f" task_id ts in
  let idem_key = Printf.sprintf "idem_%s_%.6f" task_id ts in
  let json = Yojson.Safe.to_string (event_to_yojson ev) in
  let res =
    db#exec
      ~params:[| id; task_id; json; string_of_float ts; idem_key |]
      "INSERT INTO events (id, task_id, payload, timestamp, idempotency_key) \
       VALUES ($1, $2, $3::jsonb, $4, $5) \
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
        exec_sql t.db "ROLLBACK" |> ignore;
        Result.Error (Internal (Printexc.to_string ex)))
  )
