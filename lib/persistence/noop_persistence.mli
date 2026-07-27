open Types

type t

val create : string -> (t, error_category) result
val close : t -> unit

val save_events : ?scope:string -> t -> event_envelope list -> (unit, error_category) result
val load_events : t -> Task_id.t -> (event list, error_category) result
val save_task_state : t -> task_state -> (unit, error_category) result
val load_task_state : t -> Task_id.t -> (task_state option, error_category) result
val save_workflow_state : t -> Workflow_run_id.t -> workflow_status -> workflow_checkpoint option -> (unit, error_category) result
val load_workflow_state : t -> Workflow_run_id.t -> (workflow_checkpoint option, error_category) result
val save_conversation : ?scope:string -> t -> string -> conversation -> (unit, error_category) result
val load_conversation : t -> string -> (conversation option, error_category) result
val load_most_recent_conversation : ?scope:string -> t -> ((string * conversation) option, error_category) result
val save_pending_approval : t -> run_id:string -> agent_id:string -> payload:Yojson.Safe.t -> expires_at:float -> (unit, error_category) result
val load_pending_approval : t -> run_id:string -> (Yojson.Safe.t option, error_category) result
val delete_pending_approval : t -> run_id:string -> (unit, error_category) result
val list_expired_approvals : t -> cutoff:float -> (string list, error_category) result
val transaction : t -> (t -> 'a) -> ('a, error_category) result
