(* — Persistence: SQLite backend *)

open Types

type t = {
  db : Sqlite3.db;
  mutex : Eio.Mutex.t;
}

(* -------------------------------------------------------------------------- *)
(* Schema                                                                *)
(* -------------------------------------------------------------------------- *)

let exec_sql db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> Ok ()
  | rc -> Result.Error (Internal (Printf.sprintf "SQLite error: %s" (Sqlite3.Rc.to_string rc)))

let init_schema db =
  let statements = [
    {|CREATE TABLE IF NOT EXISTS events (
         id                TEXT PRIMARY KEY,
         task_id           TEXT NOT NULL,
         payload           TEXT NOT NULL,
         timestamp         REAL NOT NULL,
         idempotency_key   TEXT UNIQUE NOT NULL
       )|};
    {|CREATE INDEX IF NOT EXISTS idx_events_task_id ON events(task_id, timestamp)|};
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
   ] in
  List.find_map (fun sql ->
     match exec_sql db sql with
     | Result.Error e -> Some (Result.Error e)
     | Ok () -> None
   ) statements
  |> function
  | Some e -> e
  | None -> Ok ()

(* -------------------------------------------------------------------------- *)
(* Connection init                                                       *)
(* -------------------------------------------------------------------------- *)

let create db_path =
  let db = Sqlite3.db_open db_path in
  match init_schema db with
  | Ok () -> Ok { db; mutex = Eio.Mutex.create () }
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
  | Tool_progress { task_id; _ } -> Task_id.to_string task_id
  | Bash_invoked { task_id; _ } -> Task_id.to_string task_id
  | Bash_completed { task_id; _ } -> Task_id.to_string task_id
  | Workflow_started { workflow_run_id } -> Workflow_run_id.to_string workflow_run_id
  | Workflow_step_completed { step_id } -> step_id
  | Workflow_completed { workflow_run_id } -> Workflow_run_id.to_string workflow_run_id
  | Workflow_failed { workflow_run_id; _ } -> Workflow_run_id.to_string workflow_run_id
  | Approval_requested _ -> ""
  | Approval_granted _ -> ""
  | Approval_timeout -> ""
  | Shutdown_initiated -> ""
  | Shutdown_completed _ -> ""
  | Mcp_server_started _ -> ""
  | Mcp_server_failed _ -> ""
  | Mcp_server_stopped _ -> ""
  | Mcp_tool_invoked _ -> ""
  | Mcp_tool_completed _ -> ""
  | Mcp_resource_read _ -> ""
  | Mcp_prompt_rendered _ -> ""

(* -------------------------------------------------------------------------- *)
(* Write operations                                                      *)
(* -------------------------------------------------------------------------- *)

let insert_event db ev =
  let stmt =
    Sqlite3.prepare db
      "INSERT OR IGNORE INTO events (id, task_id, payload, timestamp, idempotency_key) \
       VALUES (?, ?, ?, ?, ?)"
  in
  let task_id = extract_task_id ev in
  let ts = Unix.gettimeofday () in
  let id = Printf.sprintf "evt_%s_%.6f" task_id ts in
  let idem_key = Printf.sprintf "idem_%s_%.6f" task_id ts in
  let json = Yojson.Safe.to_string (event_to_yojson ev) in
  let _ = Sqlite3.bind_text stmt 1 id in
  let _ = Sqlite3.bind_text stmt 2 task_id in
  let _ = Sqlite3.bind_text stmt 3 json in
  let _ = Sqlite3.bind_double stmt 4 ts in
  let _ = Sqlite3.bind_text stmt 5 idem_key in
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
