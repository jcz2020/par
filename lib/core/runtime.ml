open Types

let string_of_error_category (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input msg -> Printf.sprintf "Invalid_input: %s" msg
  | Types.External_failure msg -> Printf.sprintf "External_failure: %s" msg
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied msg -> Printf.sprintf "Permission_denied: %s" msg
  | Types.Internal msg -> Printf.sprintf "Internal: %s" msg

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
  steering_queue : Steering_queue.t;
  followup_queue : Steering_queue.t;
  runtime_id : string;
  mutable last_llm_call_at : float option;
  mutable last_llm_call_status : [ `Success | `Error of error_category | `Never_called ];
  mutable metrics : Metrics.counters;
  mutable tool_call_hooks : Hook.tool_call_hook list;
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

let make_agent ~id ?(system_prompt = "") ?(system_prompt_template = None)
    ~model ?(tools = []) ?(max_iterations = 10)
    ?(middleware = []) ?(retry_policy = None)
    ?(context_strategy = None) ?(resource_quota = None) () =
  let errors = ref [] in
  if String.length id = 0 then
    errors := "id must not be empty" :: !errors;
  if String.length system_prompt = 0 && system_prompt_template = None then
    errors := "system_prompt must be non-empty or system_prompt_template must be provided" :: !errors;
  if max_iterations <= 0 then
    errors := (Printf.sprintf "max_iterations must be > 0 (got %d)" max_iterations) :: !errors;
  let tool_names = Hashtbl.create (List.length tools) in
  List.iter (fun (td : Types.tool_descriptor) ->
    if String.length td.Types.name = 0 then
      errors := "tool name must not be empty" :: !errors
    else if Hashtbl.mem tool_names td.name then
      errors := (Printf.sprintf "duplicate tool name: %s" td.name) :: !errors
    else
      Hashtbl.add tool_names td.name ()
  ) tools;
  match !errors with
  | [] -> Ok {
      id; system_prompt; system_prompt_template; model; tools;
      max_iterations; middleware; retry_policy; context_strategy; resource_quota;
    }
  | errs -> Result.Error (Types.Invalid_input (String.concat "; " errs))

let register_agent rt (agent : agent_config) =
  let validated = make_agent
    ~id:agent.id
    ?system_prompt:(Some agent.system_prompt)
    ?system_prompt_template:(Some agent.system_prompt_template)
    ~model:agent.model
    ?tools:(Some agent.tools)
    ?max_iterations:(Some agent.max_iterations)
    ?middleware:(Some agent.middleware)
    ?retry_policy:(Some agent.retry_policy)
    ?context_strategy:(Some agent.context_strategy)
    ?resource_quota:(Some agent.resource_quota)
    () in
  match validated with
  | Ok valid_agent ->
    htbl_set rt.agents valid_agent.id valid_agent;
    Ok ()
  | Result.Error e -> Result.Error e

let register_tool rt ~name ~description ~input_schema ~handler
    ?(permission = Allow) ?timeout ?concurrency_limit ?(on_update = None) () =
  let descriptor = { Types.name; description; input_schema; permission; timeout; concurrency_limit; on_update } in
  match Tool_registry.register rt.tool_registry descriptor handler with
  | Error (`Duplicate_tool n) ->
    Result.Error (Types.Invalid_input (Printf.sprintf "Tool already registered: %s" n))
  | Ok () ->
    Ok { descriptor; handler }

let record_llm_success rt =
  rt.last_llm_call_at <- Some (Unix.gettimeofday ());
  rt.last_llm_call_status <- `Success;
  Metrics.incr_llm rt.metrics

let record_llm_error rt err =
  rt.last_llm_call_at <- Some (Unix.gettimeofday ());
  rt.last_llm_call_status <- `Error err;
  Metrics.incr_llm rt.metrics

let record_tool_invocation rt =
  Metrics.incr_tool_invocations rt.metrics

let record_task_completed rt =
  Metrics.incr_task_completed rt.metrics

let record_task_failed rt =
  Metrics.incr_task_failed rt.metrics

let invoke rt ~agent_id ~message ?cancellation_token () =
  let agent = htbl_get rt.agents agent_id in
  match agent with
  | None -> Result.Error (Invalid_input (Printf.sprintf "Agent not found: %s" agent_id))
  | Some config ->
    let token = match cancellation_token with
      | Some t -> t
      | None -> Cancellation.create_token rt.cancellation_root
    in
    let result = Engine.run_agent ~steering:(Some rt.steering_queue)
      ~followup:(Some rt.followup_queue)
      ~runtime_id:rt.runtime_id
      ~tool_call_hooks:(Some rt.tool_call_hooks)
      token config message rt.services.llm rt.tool_registry in
    (match result with
     | Ok _ -> record_llm_success rt
     | Error e -> record_llm_error rt e);
    result

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
    | Ok () -> ()
    | Error e -> Logs.err (fun m -> m "save_task_state failed: %s" (string_of_error_category e)));
  id

let get_task_status rt task_id =
  match htbl_get rt.tasks task_id with
  | Some task -> Ok (Some task.status)
  | None ->
    (match rt.services.persistence.load_task_state_fn task_id with
     | Ok (Some ts) -> Ok (Some ts.status)
     | Ok None -> Ok None
     | Error e ->
       Logs.err (fun m -> m "load_task_state failed: %s" (string_of_error_category e));
       Ok None)

let cancel_task rt task_id =
  let task_opt =
    match htbl_get rt.tasks task_id with
    | Some t -> Some t
    | None ->
      (match rt.services.persistence.load_task_state_fn task_id with
       | Ok (Some t) -> Some t
       | Ok None | Error _ -> None)
  in
  match task_opt with
  | None -> Result.Error (Invalid_input "Task not found")
  | Some task ->
    let updated = { task with status = Cancelled; updated_at = Unix.time () } in
    htbl_set rt.tasks task_id updated;
    (match rt.services.persistence.save_task_state_fn updated with
     | Ok () -> ()
     | Error e -> Logs.err (fun m -> m "save_task_state failed: %s" (string_of_error_category e)));
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
       | Ok () -> ()
       | Error e -> Logs.err (fun m -> m "save_task_state failed: %s" (string_of_error_category e)));
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
     | Ok () -> ()
     | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)))
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
       | Ok () -> ()
       | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
     Ok id
    | exception Workflow_engine.Workflow_suspended { checkpoint; _ } ->
      htbl_set rt.workflows id (Wf_suspended checkpoint);
      (match rt.services.persistence.save_workflow_state_fn id (Wf_suspended checkpoint) (Some checkpoint) with
        | Ok () -> ()
        | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
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
                  | Ok () -> ()
                  | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)))
              | _ -> ())))
       | None -> ());
      Ok id
   | Error err ->
     htbl_set rt.workflows id (Wf_failed err);
      (match rt.services.persistence.save_workflow_state_fn id (Wf_failed err) None with
       | Ok () -> ()
       | Error e -> Logs.err (fun m -> m "save_workflow_state failed: %s" (string_of_error_category e)));
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
  let validation_result = Validation.validate_runtime_config_result config in
  match validation_result with
  | Error _ as e -> e
  | Ok () ->
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
      steering_queue = Steering_queue.create ();
      followup_queue = Steering_queue.create ();
      last_llm_call_at = None;
      last_llm_call_status = `Never_called;
      metrics = Metrics.empty ();
      tool_call_hooks = [];
      runtime_id = Session_id.to_string (Session_id.create ());
    } in
    Ok rt

let steer rt message =
  Steering_queue.enqueue rt.steering_queue message

let follow_up rt message =
  Steering_queue.enqueue rt.followup_queue message

let drain_steering rt = Steering_queue.drain_all rt.steering_queue
let drain_followup rt = Steering_queue.drain_all rt.followup_queue
let has_pending_steering rt = Steering_queue.has_items rt.steering_queue
let has_pending_followup rt = Steering_queue.has_items rt.followup_queue

let close rt =
  Steering_queue.close rt.steering_queue;
  Steering_queue.close rt.followup_queue;
  Eio.Mutex.use_rw ~protect:false rt.shutdown_mutex (fun () ->
    rt.shutdown_requested := true
  );
  rt.services.persistence.close_fn ();
  rt.services.llm.close_fn ();
  0

let tool_registry rt = rt.tool_registry

let register_tool_call_hook rt hook =
  rt.tool_call_hooks <- rt.tool_call_hooks @ [hook]

let clear_tool_call_hooks rt =
  rt.tool_call_hooks <- []

let run_tool_call_hooks rt ctx =
  Hook.run_chain rt.tool_call_hooks ctx

let health rt = {
  runtime_alive = not !(rt.shutdown_requested);
  last_llm_call_at = rt.last_llm_call_at;
  last_llm_call_status = rt.last_llm_call_status;
  persistence_ok =
    (match rt.services.persistence.load_task_state_fn (Task_id.create ()) with
     | Ok _ | Error _ -> true
     | exception _ -> false);
}

let metrics_snapshot rt = Metrics.snapshot rt.metrics

