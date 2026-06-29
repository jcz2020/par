type handler_fn = Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result

type t

val create : unit -> t

val register : t -> Types.tool_descriptor -> handler_fn -> (unit, [ `Duplicate_tool of string ]) result

val replace : t -> string -> handler_fn -> unit
(** Replace an existing handler by name. Used by [Runtime.install_bash_tool]
    to install a policy-aware bash handler over the placeholder. *)

val unregister : t -> string -> (unit, [ `Tool_not_found of string ]) result
(** Remove a handler by name. Returns [Error (`Tool_not_found name)] if
    no handler is registered under that name. Does NOT update agent
    configurations — agents may still hold stale descriptors. The engine
    returns [Internal "Tool handler not registered: ..."] at invoke time
    when an agent references an unregistered tool. To clean up agents,
    call [Runtime.update_agent_tools ~remove:[name]] per agent. *)

val resolve : t -> string -> handler_fn option

val find_descriptor : Types.tool_descriptor list -> string -> Types.tool_descriptor option

val names : t -> string list
