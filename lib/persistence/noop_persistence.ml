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

let load_conversations ?scope:_ _t _limit = Ok []

let save_pending_approval _t ~run_id:_ ~agent_id:_ ~payload:_ ~expires_at:_ = Ok ()

let load_pending_approval _t ~run_id:_ = Ok None

let delete_pending_approval _t ~run_id:_ = Ok ()

let list_expired_approvals _t ~cutoff:_ = Ok []

(* Durability requires a real backend: [invoke ~durable:true] rejects the noop
   service rather than silently checkpointing into nothing. *)
let save_invoke_checkpoint (_ : t) (_cp : invoke_checkpoint) = Ok ()

let load_invoke_checkpoint (_ : t) (_invoke_id : string) = Ok None

let list_invoke_checkpoints (_ : t) = Ok []

let delete_invoke_checkpoint (_ : t) (_invoke_id : string) = Ok ()

(* The noop backend has no shared state, so there is nothing to own. *)
let claim_invoke_lease (_ : t) ~invoke_id:_ ~owner:_ ~pid:_ ~ttl:_ = Ok true

let release_invoke_lease (_ : t) ~invoke_id:_ ~owner:_ = Ok ()

let list_invoke_leases (_ : t) = Ok []
