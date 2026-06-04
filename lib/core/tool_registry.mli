type handler_fn = Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result

type t

val create : unit -> t

val register : t -> Types.tool_descriptor -> handler_fn -> (unit, [ `Duplicate_tool of string ]) result

val replace : t -> string -> handler_fn -> unit
(** Replace an existing handler by name. Used by [Runtime.install_bash_tool]
    to install a policy-aware bash handler over the placeholder. *)

val resolve : t -> string -> handler_fn option

val find_descriptor : Types.tool_descriptor list -> string -> Types.tool_descriptor option

val names : t -> string list
