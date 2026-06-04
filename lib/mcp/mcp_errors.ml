(* lib/mcp/mcp_errors.ml — MCP error ADT and JSON-RPC code -> error_category mapping.
   Pure module: no I/O, no side effects. *)

type t =
  | Jsonrpc_parse_error     of { code : int; message : string; raw : string }
  | Jsonrpc_protocol_error  of { code : int; message : string; data : Yojson.Safe.t option }
  | Tool_call_failed        of { tool_name : string; message : string }
  | Server_crashed          of { pid : int; exit_code : int; stderr_tail : string }
  | Timeout_error           of { request_id : int; waited_seconds : float }
  | Cancelled               of { request_id : int; reason : string option }
  | Connection_closed
  | Spawn_failed            of { command : string; args : string list; unix_error : string }

let code_parse_error       = -32700
let code_invalid_request   = -32600
let code_method_not_found  = -32601
let code_invalid_params    = -32602
let code_internal_error    = -32603

let code_server_error_min  = -32099
let code_server_error_max  = -32000

let code_connection_closed = -32000
let code_request_timeout   = -32001
let code_request_cancelled = -32800
let code_url_elicitation   = -32042

let to_category = function
  | Jsonrpc_parse_error { message; _ } ->
      Types.Invalid_input (Printf.sprintf "MCP parse error: %s" message)

  | Jsonrpc_protocol_error { code = c; message; _ } when c = code_invalid_request ->
      Types.Invalid_input (Printf.sprintf "MCP invalid request: %s" message)

  | Jsonrpc_protocol_error { code = c; message; _ } when c = code_method_not_found ->
      Types.Invalid_input (Printf.sprintf "MCP method not found: %s" message)

  | Jsonrpc_protocol_error { code = c; message; _ } when c = code_invalid_params ->
      Types.Invalid_input (Printf.sprintf "MCP invalid params: %s" message)

  | Jsonrpc_protocol_error { code = c; message; _ } when c = code_internal_error ->
      Types.Internal (Printf.sprintf "MCP internal error: %s" message)

  | Jsonrpc_protocol_error { code = c; message; _ } when c = code_parse_error ->
      Types.Invalid_input (Printf.sprintf "MCP parse error: %s" message)

  | Jsonrpc_protocol_error { code; message; _ }
    when code >= code_server_error_min && code <= code_server_error_max ->
      Types.External_failure
        (Printf.sprintf "MCP server-defined error %d: %s" code message)

  | Jsonrpc_protocol_error { code; message; _ } ->
      Types.Internal
        (Printf.sprintf "MCP unknown error code %d: %s" code message)

  | Tool_call_failed { tool_name; message } ->
      Types.Internal (Printf.sprintf "MCP tool %s failed: %s" tool_name message)

  | Server_crashed { pid; exit_code; stderr_tail } ->
      Types.External_failure
        (Printf.sprintf "MCP server (pid %d) crashed with exit %d: %s"
           pid exit_code stderr_tail)

  | Timeout_error _ ->
      Types.Timeout

  | Cancelled { request_id; _ } ->
      Types.Internal (Printf.sprintf "MCP request %d cancelled" request_id)

  | Connection_closed ->
      Types.External_failure "MCP connection closed unexpectedly"

  | Spawn_failed { command; args; unix_error } ->
      Types.External_failure
        (Printf.sprintf "MCP server failed to spawn: %s %s (%s)"
           command (String.concat " " args) unix_error)

let format = function
  | Jsonrpc_parse_error { message; _ } ->
      Printf.sprintf "MCP parse error: %s" message

  | Jsonrpc_protocol_error { code; message; _ } ->
      Printf.sprintf "MCP error %d: %s" code message

  | Tool_call_failed { tool_name; message } ->
      Printf.sprintf "MCP tool %s failed: %s" tool_name message

  | Server_crashed { pid; exit_code; stderr_tail } ->
      Printf.sprintf "MCP server (pid %d) crashed with exit %d: %s"
        pid exit_code stderr_tail

  | Timeout_error { request_id; waited_seconds } ->
      Printf.sprintf "MCP request %d timed out after %.3fs" request_id waited_seconds

  | Cancelled { request_id; reason } ->
      (match reason with
       | None -> Printf.sprintf "MCP request %d cancelled" request_id
       | Some r -> Printf.sprintf "MCP request %d cancelled: %s" request_id r)

  | Connection_closed ->
      "MCP connection closed unexpectedly"

  | Spawn_failed { command; args; unix_error } ->
      Printf.sprintf "MCP server failed to spawn: %s %s (%s)"
        command (String.concat " " args) unix_error
