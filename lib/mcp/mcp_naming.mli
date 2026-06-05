(* lib/mcp/mcp_naming.mli
   Hierarchical default: "mcp__<server>__<tool>".
*)

(** Replace any char outside [a-zA-Z0-9_-] with '_'. Idempotent.
    Per the MCP spec (SEP-986), tool names may include [.] and [/], but
    PAR intentionally narrows this for LLM tool-naming safety (OpenAI/
    Anthropic function calling rejects [.] and [/]). This is documented
     as a design decision; a future release will evaluate a [?strict_spec_compliance]
    flag. *)
val sanitize : string -> string

(** Build the tool name as registered in PAR's tool_registry.
    - Hierarchical: "mcp__<server>__<tool>"   (default)
    - Flat:         "<server>_<tool>"
    Truncate to ≤60 chars (hard cap). Log [Logs.warn] at ≥50 chars
    but proceed with the full name. *)
val mangle_tool_name :
  style:Mcp_types.prefix_style ->
  server_name:string ->
  tool_name:string ->
  string

(** Reject empty / >32 chars / chars outside [a-zA-Z0-9_-]. *)
val validate_server_name : string -> (unit, Types.error_category) result

(** Preserves original (non-sanitized) names for UI display.
    Format: "<server>.<tool>". If either is empty, return "".
    Used by tools that need to show the user the original server-supplied
    name even when the registry name is mangled. *)
val display_title : server_name:string -> tool_name:string -> string

(** Detect which names in [to_add] are already in [existing].
    Returns the colliding names. Empty list = no collision. *)
val detect_collisions :
  existing:string list ->
  to_add:string list ->
  string list
