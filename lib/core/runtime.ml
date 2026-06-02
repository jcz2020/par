open Types

(* -------------------------------------------------------------------------- *)
(* SDK — Runtime                                                          *)
(* -------------------------------------------------------------------------- *)

type runtime = {
  agents : (string, agent_config) protected_hashtbl;
  services : service_registry;
  cancellation_root : Eio.Switch.t;
  task_semaphore : Eio.Semaphore.t;
  shutdown_requested : bool ref;
  shutdown_mutex : Eio.Mutex.t;
  tasks : (Task_id.t, task_state) protected_hashtbl;
  workflows : (Workflow_run_id.t, workflow_status) protected_hashtbl;
  workflow_defs : (string, workflow) protected_hashtbl;
  tool_registry : Tool_registry.t;
} [@@warning "-69"]

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

let register_agent rt (agent : agent_config) =
  htbl_set rt.agents agent.id agent;
  Ok ()

let register_tool rt ~name ~description ~input_schema ~handler
    ?(permission = Allow) ?timeout ?concurrency_limit () =
  let descriptor = { Types.name; description; input_schema; permission; timeout; concurrency_limit } in
  Tool_registry.register rt.tool_registry descriptor handler;
  { descriptor; handler }

let invoke rt ~agent_id ~message ?cancellation_token () =
  let agent = htbl_get rt.agents agent_id in
  match agent with
  | None -> Result.Error (Invalid_input (Printf.sprintf "Agent not found: %s" agent_id))
  | Some config ->
    let token = match cancellation_token with
      | Some t -> t
      | None -> Cancellation.create_token rt.cancellation_root
    in
    Engine.run_agent token config message rt.services.llm rt.tool_registry

let submit_task rt ?(priority = 5) ?(timeout = 300.0) input =
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
  (match rt.services.persistence.save_task_state_fn task with
   | Ok () -> () | Error _ -> ());
  id

let get_task_status rt task_id =
  match htbl_get rt.tasks task_id with
  | Some task -> Ok (Some task.status)
  | None ->
    (match rt.services.persistence.load_task_state_fn task_id with
     | Ok (Some ts) -> Ok (Some ts.status)
     | Ok None -> Ok None
     | Error _ -> Ok None)

let cancel_task rt task_id =
  let task =
    match htbl_get rt.tasks task_id with
    | Some t -> t
    | None ->
      (match rt.services.persistence.load_task_state_fn task_id with
       | Ok (Some t) -> t
       | Ok None | Error _ -> raise (Invalid_argument "Task not found"))
  in
  let updated = { task with status = Cancelled; updated_at = Unix.time () } in
  htbl_set rt.tasks task_id updated;
  (match rt.services.persistence.save_task_state_fn updated with
   | Ok () -> () | Error _ -> ());
  Ok ()

let approve_task rt task_id ~approver:_ =
  match htbl_get rt.tasks task_id with
  | None -> Result.Error (Invalid_input "Task not found")
  | Some task ->
    match task.status with
    | Waiting_input ->
      let updated = { task with status = Scheduled; updated_at = Unix.time () } in
      htbl_set rt.tasks task_id updated;
      (match rt.services.persistence.save_task_state_fn updated with
       | Ok () -> () | Error _ -> ());
      Ok ()
    | _ -> Result.Error (Invalid_input "Task is not waiting for approval")

let find_tool_across_agents rt tool_name =
  let result = ref None in
  htbl_iter rt.agents (fun _id (agent : agent_config) ->
    if result.contents = None then
      result := List.find_opt (fun (td : tool_descriptor) -> td.name = tool_name) agent.tools
  );
  result.contents

let submit_workflow rt wf =
  let id = Workflow_run_id.create () in
  htbl_set rt.workflows id Wf_running;
  let token = Cancellation.create_token rt.cancellation_root in
  let checkpoint_cb _step_id result =
    let cp = Workflow_engine.make_checkpoint ~step_path:[]
               ~step_results:[result]
               {
                 Workflow_engine.variables = wf.variables;
                 token;
                 agent_resolver = (fun aid -> htbl_get rt.agents aid);
                 tool_resolver = find_tool_across_agents rt;
                 llm = rt.services.llm;
                 registry = rt.tool_registry;
                 parallel_limit = wf.parallel_limit;
                 failure_policy = wf.failure_policy;
                 workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
                 on_step_complete = None;
                 workflow_run_id = Some id;
               }
    in
    (match rt.services.persistence.save_workflow_state_fn id Wf_running (Some cp) with
     | Ok () -> () | Error _ -> ())
  in
  let ctx = {
    Workflow_engine.variables = wf.variables;
    token;
    agent_resolver = (fun aid -> htbl_get rt.agents aid);
    tool_resolver = find_tool_across_agents rt;
    llm = rt.services.llm;
    registry = rt.tool_registry;
    parallel_limit = wf.parallel_limit;
    failure_policy = wf.failure_policy;
    workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
    on_step_complete = Some checkpoint_cb;
    workflow_run_id = Some id;
  } in
  (match Workflow_engine.execute_workflow ctx wf with
   | Ok result ->
     htbl_set rt.workflows id (Wf_completed result);
     (match rt.services.persistence.save_workflow_state_fn id (Wf_completed result) None with
      | Ok () -> () | Error _ -> ());
     Ok id
    | exception Workflow_engine.Workflow_suspended { checkpoint; _ } ->
      htbl_set rt.workflows id (Wf_suspended checkpoint);
      (match rt.services.persistence.save_workflow_state_fn id (Wf_suspended checkpoint) (Some checkpoint) with
       | Ok () -> () | Error _ -> ());
      (match Workflow_engine.Approval_deadline.lookup id with
       | Some deadline_entry ->
         let remaining = Workflow_engine.Approval_deadline.deadline_of deadline_entry -. Unix.gettimeofday () in
         if remaining > 0.0 then
           ignore (Eio.Fiber.fork ~sw:(Workflow_engine.Approval_deadline.switch_of deadline_entry) (fun () ->
             let deadline = Unix.gettimeofday () +. remaining in
             while Unix.gettimeofday () < deadline do
               Eio.Fiber.yield ()
             done;
             Workflow_engine.Approval_deadline.remove id;
             (match htbl_get rt.workflows id with
              | Some (Wf_suspended _) ->
                htbl_set rt.workflows id (Wf_failed (Timeout));
                (match rt.services.persistence.save_workflow_state_fn id (Wf_failed Timeout) None with
                 | Ok () -> () | Error _ -> ())
              | _ -> ())))
       | None -> ());
      Ok id
   | Error err ->
     htbl_set rt.workflows id (Wf_failed err);
     (match rt.services.persistence.save_workflow_state_fn id (Wf_failed err) None with
      | Ok () -> () | Error _ -> ());
     Ok id)

let get_workflow_status rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some status -> Ok status

let cancel_workflow rt wf_id =
  htbl_set rt.workflows wf_id (Wf_failed (Internal "Cancelled"));
  Ok ()

let register_workflow rt (wf : workflow) =
  htbl_set rt.workflow_defs wf.id wf;
  Ok ()

let approve_workflow rt wf_id ~approver:_ =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some (Wf_suspended _) -> Ok ()
  | Some _ -> Result.Error (Invalid_input "Workflow is not suspended")

let resume_workflow rt wf_id =
  match htbl_get rt.workflows wf_id with
  | None -> Result.Error (Invalid_input "Workflow not found")
  | Some (Wf_suspended _) ->
     (match rt.services.persistence.load_workflow_state_fn wf_id with
      | Ok (Some loaded_cp) ->
        let token = Cancellation.create_token rt.cancellation_root in
        let vars = loaded_cp.variables in
        let ctx = {
          Workflow_engine.variables = vars;
          token;
          agent_resolver = (fun aid -> htbl_get rt.agents aid);
          tool_resolver = find_tool_across_agents rt;
          llm = rt.services.llm;
          registry = rt.tool_registry;
          parallel_limit = 10;
          failure_policy = Fail_fast;
          workflow_resolver = (fun wid -> htbl_get rt.workflow_defs wid);
          on_step_complete = None;
          workflow_run_id = Some wf_id;
        } in
        (match Workflow_engine.execute_workflow ctx
          { id = "resumed"; name = "resumed"; version = 1;
            steps = Tool_call { tool_name = "echo"; input = `Assoc [] };
            variables = vars; failure_policy = Fail_fast;
            parallel_limit = 10; timeout = 300.0; on_complete = None }
        with
         | Ok result ->
           htbl_set rt.workflows wf_id (Wf_completed result);
           Ok (Some result)
         | exception Workflow_engine.Workflow_suspended { checkpoint = cp; _ } ->
           htbl_set rt.workflows wf_id (Wf_suspended cp);
           Ok None
         | Error err ->
           htbl_set rt.workflows wf_id (Wf_failed err);
           Error err)
      | Ok None -> Error (Internal "No checkpoint found for suspended workflow")
      | Error e -> Error e)
  | Some _ -> Result.Error (Invalid_input "Workflow is not suspended")

let noop_persistence : Types.persistence_service = {
  save_events_fn = (fun _events -> Ok ());
  load_events_fn = (fun _task_id -> Ok []);
  save_task_state_fn = (fun _ts -> Ok ());
  load_task_state_fn = (fun _task_id -> Ok None);
  save_workflow_state_fn = (fun _id _status _checkpoint -> Ok ());
  load_workflow_state_fn = (fun _id -> Ok None);
  close_fn = ignore;
}

module Noop_event_bus : EVENT_BUS_SERVICE = struct
  type t = unit
  type subscription = unit
  let publish () _event =
    prerr_endline "[WARN] Noop_event_bus.publish called — no event_bus configured"
  let subscribe () _handler =
    prerr_endline "[WARN] Noop_event_bus.subscribe called — no event_bus configured";
    ()
  let unsubscribe () _subscription =
    prerr_endline "[WARN] Noop_event_bus.unsubscribe called — no event_bus configured"
end

let create ?(persistence = noop_persistence)
           ?(event_bus = (module Noop_event_bus : EVENT_BUS_SERVICE))
           ?(llm = { complete_fn = (fun _ _tools _ -> Result.Error (Internal "LLM not initialized"));
                      stream_fn = (fun _ _tools _ _ _ -> Result.Error (Internal "LLM not initialized"));
                      close_fn = ignore })
           ~config switch =
  let semaphore = Eio.Semaphore.make config.default_quota.max_concurrent_tasks in
  let rt = {
    agents = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
    services = {
      persistence;
      llm;
      event_bus;
      config;
    };
    cancellation_root = switch;
    task_semaphore = semaphore;
    shutdown_requested = ref false;
    shutdown_mutex = Eio.Mutex.create ();
    tasks = { data = Hashtbl.create 256; mutex = Eio.Mutex.create () };
    workflows = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
    workflow_defs = { data = Hashtbl.create 16; mutex = Eio.Mutex.create () };
    tool_registry = Tool_registry.create ();
  } in
  Ok rt

let close rt =
  Eio.Mutex.use_rw ~protect:false rt.shutdown_mutex (fun () ->
    rt.shutdown_requested := true
  );
  rt.services.persistence.close_fn ();
  rt.services.llm.close_fn ();
  0

let tool_registry rt = rt.tool_registry
