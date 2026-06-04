(* lib/mcp/mcp_errors.mli *)

type t =
  | Jsonrpc_parse_error     of { code : int; message : string; raw : string }
  | Jsonrpc_protocol_error  of { code : int; message : string; data : Yojson.Safe.t option }
  | Tool_call_failed        of { tool_name : string; message : string }
  | Server_crashed          of { pid : int; exit_code : int; stderr_tail : string }
  | Timeout_error           of { request_id : int; waited_seconds : float }
  | Cancelled               of { request_id : int; reason : string option }
  | Connection_closed
  | Spawn_failed            of { command : string; args : string list; unix_error : string }

(* Convert to PAR's polymorphic error_category for use at runtime boundary. *)
val to_category : t -> Types.error_category

(* Format as human-readable string for logs / event payloads. *)
val format : t -> string

(* === Constants === *)

(* JSON-RPC 2.0 standard error codes (https://www.jsonrpc.org/specification) *)
val code_parse_error        : int   (* -32700 *)
val code_invalid_request    : int   (* -32600 *)
val code_method_not_found   : int   (* -32601 *)
val code_invalid_params     : int   (* -32602 *)
val code_internal_error     : int   (* -32603 *)

(* MCP-specific / server-defined range *)
val code_server_error_min   : int   (* -32099 *)
val code_server_error_max   : int   (* -32000 *)

(* MCP-specific known codes (per python-sdk types/jsonrpc.py + spec) *)
val code_connection_closed  : int   (* -32000; SDK-only *)
val code_request_timeout    : int   (* -32001; SDK-only *)
val code_request_cancelled  : int   (* -32800; MCP §6 *)
val code_url_elicitation    : int   (* -32042; MCP elicitation required *)
