(* lib/core/mcp_tools.ml — bridge MCP server tools into PAR's tool model.
 *
 * PAR's agent loop looks a tool's descriptor up in the agent's advertised
 * tool list and its handler up in the per-call registry. An MCP server
 * exposes neither, so this module turns the server's own tool declarations
 * into PAR descriptors and handlers.
 *
 * MCP tool names are used exactly as the server reports them. A name that an
 * explicitly registered tool already claims is not overridden: the per-call
 * registry keeps the explicit tool, and the schema check in the engine
 * surfaces the disagreement rather than silently running one tool's handler
 * behind another tool's schema. *)

open Types

(* -------------------------------------------------------------------------- *)
(* Descriptors                                                                 *)
(* -------------------------------------------------------------------------- *)

let descriptor_of (tool : Mcp_types.mcp_tool) : tool_descriptor =
  { name = tool.name
  ; description = (match tool.description with
      | Some d -> d
      | None -> "")
  ; input_schema = tool.input_schema
  ; output_schema = None
  ; permission = Allow
  ; timeout = Some 30.0
  ; concurrency_limit = None
  ; on_update = None
  ; cache_control = None
  }

(* -------------------------------------------------------------------------- *)
(* Handlers                                                                    *)
(* -------------------------------------------------------------------------- *)

(* MCP reports a tool-level failure inside a successful JSON-RPC response, by
   setting "isError" on the result. Left as a success it would look to the
   agent loop like a tool that ran and produced output. *)
let is_error_result (result : Yojson.Safe.t) =
  match result with
  | `Assoc fields ->
    (match List.assoc_opt "isError" fields with
     | Some (`Bool true) -> true
     | _ -> false)
  | _ -> false

(* The result body is a list of content blocks; the model is far better served
   by the text than by the block structure. *)
let text_of_result (result : Yojson.Safe.t) =
  match result with
  | `Assoc fields ->
    (match List.assoc_opt "content" fields with
     | Some (`List blocks) ->
       blocks
       |> List.filter_map (fun block ->
            match block with
            | `Assoc b -> (match List.assoc_opt "text" b with
                | Some (`String t) -> Some t
                | _ -> None)
            | _ -> None)
       |> String.concat "\n"
     | _ -> "")
  | _ -> ""

let handler_of (client : Mcp_client.t) ~(tool_name : string) : Tool_registry.handler_fn =
  fun input _token ->
    match Mcp_client.call_tool client ~name:tool_name ~arguments:input with
    | Error e ->
      Error { category = e
            ; message = Printf.sprintf "MCP tool %s failed: %s" tool_name
                (Types.string_of_error_category e)
            ; retryable = false
            ; metadata = [] }
    | Ok result ->
      if is_error_result result then
        Error { category = External_failure "MCP tool reported an error"
              ; message = (match text_of_result result with
                  | "" -> Printf.sprintf "MCP tool %s reported an error" tool_name
                  | t -> Printf.sprintf "MCP tool %s reported an error: %s" tool_name t)
              ; retryable = false
              ; metadata = [] }
      else
        Success result

(* -------------------------------------------------------------------------- *)
(* Listing                                                                     *)
(* -------------------------------------------------------------------------- *)

(* The tool set of every configured server, paired with its handler. A server
   that cannot be listed contributes nothing: the rest of the runtime stays
   usable, and the caller finds out by observing the missing tools. *)
let entries (servers : (Mcp_types.server_id * Mcp_server.t) list) :
    (tool_descriptor * Tool_registry.handler_fn) list =
  List.concat_map
    (fun (_server_id, server) ->
      let client = Mcp_client.of_server server in
      match Mcp_client.list_tools client with
      | Ok tools ->
        List.map
          (fun (tool : Mcp_types.mcp_tool) ->
            (descriptor_of tool, handler_of client ~tool_name:tool.name))
          tools
      | Error _ -> [])
    servers
