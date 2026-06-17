(** MCP HTTP/SSE transport (MCP spec §4.1).

    POSTs JSON-RPC messages to a single endpoint.  The server may reply with a
    direct JSON response, an SSE stream, or [202 Accepted] for notifications. *)

type t

val create : url:string -> net:_ Eio.Net.t -> sw:Eio.Switch.t -> t

val request_response :
  t -> Mcp_types.jsonrpc_request -> (Mcp_types.jsonrpc_response, Types.error_category) result

val notify :
  t -> Mcp_types.jsonrpc_notification -> (unit, Types.error_category) result

val close : t -> unit

val set_sampling_handler :
  t -> (Yojson.Safe.t -> (Yojson.Safe.t, Types.error_category) result) -> unit

val to_transport : t -> Mcp_transport.t
