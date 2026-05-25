open Types

(* -------------------------------------------------------------------------- *)
(* §9 SDK — Runtime                                                          *)
(* -------------------------------------------------------------------------- *)

type runtime = {
  agents : (string, agent_config) protected_hashtbl;
  services : service_registry;
  cancellation_root : Eio.Switch.t;
  task_semaphore : Eio.Semaphore.t;
  shutdown_requested : bool Eio.Atomic.t;
  tasks : (Task_id.t, task_state) protected_hashtbl;
  workflows : (Workflow_run_id.t, workflow_status) protected_hashtbl;
}

let default_event_bus_config = {
  buffer_capacity = 10000;
  delivery = {
    max_delivery_attempts = 5;
    initial_retry_delay = 1.0;
    retry_backoff = Exponential { base = 1.0; max_delay = 30.0 };
    delivery_timeout = 30.0;
  };
  dlq_enabled = true;
  critical_event_types = [ "Shutdown_initiated"; "Shutdown_completed" ];
}

let default_shutdown_config = {
  drain_timeout = 30.0;
  cancel_grace_period = 5.0;
  flush_batch_size = 100;
}

let default_quota = {
  max_concurrent_tasks = 10;
  max_concurrent_tools_per_agent = 5;
  max_tokens_per_turn = None;
  max_total_tokens = None;
}

let register_agent rt agent =
  htbl_set rt.agents agent.id agent;
  Ok ()

let register_tool rt ~name ~description ~input_schema ~handler
    ?(permission = Allow) ?timeout ?concurrency_limit () =
  { name; description; input_schema; handler; permission; timeout; concurrency_limit }

let invoke rt ~agent_id ~message ?token =
  let agent = htbl_get rt.agents agent_id in
  match agent with
  | None -> Error (Invalid_input (Printf.sprintf "Agent not found: %s" agent_id))
  | Some config ->
    let token = match token with
      | Some t -> t
      | None -> Cancellation.create_token rt.cancellation_root
    in
    Engine.run_agent token config message rt.services.llm

let submit_task rt input ?(priority = 5) ?(timeout = 300.0) =
  let id = Task_id.create () in
  let task = {
    id;
    input;
    status = Pending;
    parent_id = None;
    workflow_run_id = None;
    priority;
    schedule = None;
    timeout;
    retry_policy = None;
    retry_count = 0;
    dependencies = [];
    depend_mode = `All_success;
    created_at = Unix.time ();
    updated_at = Unix.time ();
    output = None;
    error = None;
  } in
  htbl_set rt.tasks id task;
  id

let get_task_status rt task_id =
  match htbl_get rt.tasks task_id with
  | None -> Ok None
  | Some task -> Ok (Some task.status)

let cancel_task rt task_id =
  match htbl_get rt.tasks task_id with
  | None -> Error (Invalid_input "Task not found")
  | Some task ->
    let updated = { task with status = Cancelled; updated_at = Unix.time () } in
    htbl_set rt.tasks task_id updated;
    Ok ()

let approve_task rt task_id ~approver =
  match htbl_get rt.tasks task_id with
  | None -> Error (Invalid_input "Task not found")
  | Some task ->
    match task.status with
    | Waiting_input ->
      let updated = { task with status = Scheduled; updated_at = Unix.time () } in
      htbl_set rt.tasks task_id updated;
      Ok ()
    | _ -> Error (Invalid_input "Task is not waiting for approval")

let submit_workflow rt wf =
  let id = Workflow_run_id.create () in
  htbl_set rt.workflows id Wf_pending;
  Ok id

let get_workflow_status rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Error (Invalid_input "Workflow not found")
  | Some status -> Ok status

let cancel_workflow rt wf_id =
  htbl_set rt.workflows wf_id (Wf_failed (Internal "Cancelled"));
  Ok ()

let create ~config switch =
  let semaphore = Eio.Semaphore.make config.default_quota.max_concurrent_tasks in
  let rt = {
    agents = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
    services = {
      persistence = failwith "persistence not initialized";
      llm = failwith "llm not initialized";
      event_bus = failwith "event_bus not initialized";
      config;
    };
    cancellation_root = switch;
    task_semaphore = semaphore;
    shutdown_requested = Eio.Atomic.make false;
    tasks = { data = Hashtbl.create 256; mutex = Eio.Mutex.create () };
    workflows = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
  } in
  Ok rt

let close rt =
  Eio.Atomic.set rt.shutdown_requested true;
  0
