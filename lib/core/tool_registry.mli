type handler_fn = Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result

type t

val create : unit -> t

val register : t -> Types.tool_descriptor -> handler_fn -> unit

val resolve : t -> string -> handler_fn option

val find_descriptor : Types.tool_descriptor list -> string -> Types.tool_descriptor option

val names : t -> string list
