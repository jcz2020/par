open Types

exception Resource_limit of string

type eval_context = (string * Yojson.Safe.t) list

val evaluate : eval_context -> expression -> (Yojson.Safe.t, error_category) result

val evaluate_to_bool : eval_context -> expression -> (bool, error_category) result

val reset_visit : unit -> unit
