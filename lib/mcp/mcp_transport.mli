(** MCP transport abstraction.

    A transport hides the wire protocol (stdio line-delimited JSON or HTTP/SSE)
    behind a small record of functions. *)

type t = {
  request_response :
    Mcp_types.jsonrpc_request -> (Mcp_types.jsonrpc_response, Types.error_category) result;
  notify : Mcp_types.jsonrpc_notification -> (unit, Types.error_category) result;
  close : unit -> unit;
}
