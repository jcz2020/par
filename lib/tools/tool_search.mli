(** Meta-tool for progressive tool loading. Named [tool_search];
    queries the per-call registry's Searchable-layer tools by keyword. *)

val name : string

val descriptor : Types.tool_descriptor

val search : query:string -> category:string option -> Types.tool_descriptor list -> Types.tool_descriptor list

val make_handler : Tool_registry.t -> Tool_registry.handler_fn
