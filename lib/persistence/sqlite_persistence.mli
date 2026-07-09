(* — Persistence: SQLite backend *)

open Types

type t

val create : ?retention_ttl:float -> string -> (t, error_category) result
val close : t -> unit

val save_events : ?scope:string -> t -> event_envelope list -> (unit, error_category) result
val load_events : t -> Task_id.t -> (event list, error_category) result
val load_events_by_session : ?scope:string -> t -> string -> (event list, error_category) result
val load_sessions : ?scope:string -> t -> int -> (session_summary list, error_category) result
val load_recent_events : t -> int -> (event list, error_category) result
val prune_old_events : t -> ttl_seconds:float -> (unit, error_category) result
val save_task_state : t -> task_state -> (unit, error_category) result
val load_task_state : t -> Task_id.t -> (task_state option, error_category) result
val save_workflow_state : t -> Workflow_run_id.t -> workflow_status -> workflow_checkpoint option -> (unit, error_category) result
val load_workflow_state : t -> Workflow_run_id.t -> (workflow_checkpoint option, error_category) result
val load_all_suspended_workflows : t -> ((Workflow_run_id.t * workflow_status) list, error_category) result
val save_workflow_def : t -> string -> Yojson.Safe.t -> (unit, error_category) result
val load_all_workflow_defs : t -> ((string * Yojson.Safe.t) list, error_category) result
val save_conversation : ?scope:string -> t -> string -> conversation -> (unit, error_category) result
val load_conversation : t -> string -> (conversation option, error_category) result
val load_most_recent_conversation : ?scope:string -> t -> ((string * conversation) option, error_category) result
val transaction : t -> (t -> 'a) -> ('a, error_category) result

val raw_sqlite3_db : t -> Sqlite3.db
(** Unrestricted access to the underlying SQLite handle.
    Bypasses the internal mutex — caller is responsible for thread safety
    if the runtime may be using [t] concurrently (e.g. via [save_events]).
    Use cases: creating FTS5 virtual tables, custom indexes, raw queries
    that the typed API above does not cover. Do NOT close the returned
    handle; use [close] on [t] instead. *)
