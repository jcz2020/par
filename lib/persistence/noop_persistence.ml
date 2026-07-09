open Types

type t = {
  conversations : (string, conversation) Hashtbl.t;
}

let create (_conninfo : string) =
  Ok { conversations = Hashtbl.create 16 }

let close (_ : t) = ()

let save_events ?scope:_ (_ : t) (_events : event_envelope list) = Ok ()

let load_events (_ : t) (_task_id : Task_id.t) = Ok []

let save_task_state (_ : t) (_ts : task_state) = Ok ()

let load_task_state (_ : t) (_task_id : Task_id.t) = Ok None

let save_workflow_state (_ : t) (_run_id : Workflow_run_id.t)
    (_status : workflow_status) (_checkpoint : workflow_checkpoint option) = Ok ()

let load_workflow_state (_ : t) (_run_id : Workflow_run_id.t) = Ok None

let transaction (t : t) (f : t -> 'a) =
  Ok (f t)

let save_conversation ?scope:_ t session_id conv =
  Hashtbl.replace t.conversations session_id conv;
  Ok ()

let load_conversation t session_id =
  Ok (Hashtbl.find_opt t.conversations session_id)

let load_most_recent_conversation ?scope:_ t =
  let acc = ref None in
  let _ : unit = Hashtbl.fold (fun k v () ->
    match !acc with
    | None -> acc := Some (k, v)
    | Some _ -> ()
  ) t.conversations () in
  Ok !acc
