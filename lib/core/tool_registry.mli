type handler_fn = Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result

type tool_layer = Always | Searchable

type t

val create : unit -> t

val register : t -> Types.tool_descriptor -> handler_fn -> (unit, [ `Duplicate_tool of string ]) result

val register_searchable : t -> Types.tool_descriptor -> handler_fn -> (unit, [ `Duplicate_tool of string ]) result

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

val set_layer : t -> string -> tool_layer -> unit

val searchable_descriptors : t -> Types.tool_descriptor list

val layer_of : t -> string -> tool_layer

val find_descriptor : Types.tool_descriptor list -> string -> Types.tool_descriptor option

val names : t -> string list

val copy_all : src:t -> dst:t -> unit
(** Copy all bindings from [src] into [dst], overwriting any existing entries
    in [dst] that share a name. Used by [Runtime.per_call_registry] to seed a
    fresh per-invocation registry with the caller-registered tools before
    overwriting the workspace-sensitive ones (e.g. bash) with effective-workspace
    closures. *)
