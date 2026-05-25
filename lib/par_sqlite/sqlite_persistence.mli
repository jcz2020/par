(* §7 — Persistence: SQLite backend *)

open Types

type t

val create : string -> (t, error_category) result
val close : t -> unit

val save_events : t -> event list -> (unit, error_category) result
val load_events : t -> Task_id.t -> (event list, error_category) result
val save_task_state : t -> task_state -> (unit, error_category) result
val load_task_state : t -> Task_id.t -> (task_state option, error_category) result
val transaction : t -> (t -> 'a) -> ('a, error_category) result
