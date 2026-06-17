(* lib/mcp/mcp_transport.ml
   v0.4.4 W1 — Transport abstraction for MCP servers.

   A transport is anything that can send a JSON-RPC request and return the
   matching response, send a one-way notification, and be closed.  This lets
   [Mcp_server] work over stdio or HTTP/SSE without caring about the wire
   details. *)

type t = {
  request_response :
    Mcp_types.jsonrpc_request -> (Mcp_types.jsonrpc_response, Types.error_category) result;
  notify : Mcp_types.jsonrpc_notification -> (unit, Types.error_category) result;
  close : unit -> unit;
}
