open Types

type t = unit

let create (_conninfo : string) =
  Ok ()

let close (_ : t) = ()

let save_events (_ : t) (_events : event_envelope list) = Ok ()

let load_events (_ : t) (_task_id : Task_id.t) = Ok []

let save_task_state (_ : t) (_ts : task_state) = Ok ()

let load_task_state (_ : t) (_task_id : Task_id.t) = Ok None

let save_workflow_state (_ : t) (_run_id : Workflow_run_id.t)
    (_status : workflow_status) (_checkpoint : workflow_checkpoint option) = Ok ()

let load_workflow_state (_ : t) (_run_id : Workflow_run_id.t) = Ok None

let transaction (_ : t) (f : t -> 'a) =
  Ok (f ())
