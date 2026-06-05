(* lib/mcp/mcp_client.ml
   v0.3.1 W2 — High-level MCP client API.
   Wraps Mcp_server with typed domain methods for tools, resources, and prompts. *)

[@@@warning "-32-34-37"]

type t = {
  server : Mcp_server.t;
}

let of_server s = { server = s }
let server t = t.server
let id t = Mcp_server.id t.server
let name t = Mcp_server.name t.server
let capabilities t = Mcp_server.capabilities t.server
let status t = Mcp_server.status t.server

let connect ~sw ~process_mgr ~clock (config : Mcp_types.server_config) :
  (t, Types.error_category) result =
  match Mcp_server.spawn ~sw ~process_mgr ~clock config with
  | Ok s -> Ok { server = s }
  | Error e -> Error e

let disconnect t = Mcp_server.stop t.server

(* --- Tools --- *)

let list_tools t : (Mcp_types.mcp_tool list, Types.error_category) result =
  match Mcp_server.call_method t.server
      ~method_:Mcp_types.method_tools_list ~params:(`Assoc []) with
  | Error e -> Error e
  | Ok json ->
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "tools" fields with
       | Some (`List items) ->
         let rec loop acc = function
           | [] -> Ok (List.rev acc)
           | item :: rest ->
             match Mcp_types.tool_of_yojson item with
             | Error msg -> Error (Types.Internal msg)
             | Ok tool -> loop (tool :: acc) rest
         in
         loop [] items
       | _ -> Error (Types.Internal "tools/list: missing 'tools' array"))
    | _ -> Error (Types.Internal "tools/list: response is not an object")

let call_tool t ~name ~arguments :
  (Yojson.Safe.t, Types.error_category) result =
  let params = `Assoc [
    "name", `String name;
    "arguments", arguments;
  ] in
  Mcp_server.call_method t.server ~method_:Mcp_types.method_tools_call ~params

(* --- Resources --- *)

let list_resources t : (Mcp_types.mcp_resource list, Types.error_category) result =
  match Mcp_server.call_method t.server
      ~method_:Mcp_types.method_resources_list ~params:(`Assoc []) with
  | Error e -> Error e
  | Ok json ->
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "resources" fields with
       | Some (`List items) ->
         let rec loop acc = function
           | [] -> Ok (List.rev acc)
           | item :: rest ->
             match Mcp_types.resource_of_yojson item with
             | Error msg -> Error (Types.Internal msg)
             | Ok r -> loop (r :: acc) rest
         in
         loop [] items
       | _ -> Error (Types.Internal "resources/list: missing 'resources' array"))
    | _ -> Error (Types.Internal "resources/list: response is not an object")

let read_resource t ~uri : (Yojson.Safe.t, Types.error_category) result =
  let params = `Assoc ["uri", `String uri] in
  Mcp_server.call_method t.server ~method_:Mcp_types.method_resources_read ~params

(* --- Prompts --- *)

let list_prompts t : (Mcp_types.mcp_prompt list, Types.error_category) result =
  match Mcp_server.call_method t.server
      ~method_:Mcp_types.method_prompts_list ~params:(`Assoc []) with
  | Error e -> Error e
  | Ok json ->
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "prompts" fields with
       | Some (`List items) ->
         let rec loop acc = function
           | [] -> Ok (List.rev acc)
           | item :: rest ->
             match Mcp_types.prompt_of_yojson item with
             | Error msg -> Error (Types.Internal msg)
             | Ok p -> loop (p :: acc) rest
         in
         loop [] items
       | _ -> Error (Types.Internal "prompts/list: missing 'prompts' array"))
    | _ -> Error (Types.Internal "prompts/list: response is not an object")

let get_prompt t ~name ?(arguments = []) () :
  (Yojson.Safe.t, Types.error_category) result =
  let args_json = `Assoc (List.map (fun (k, v) -> (k, `String v)) arguments) in
  let params = `Assoc [
    "name", `String name;
    "arguments", args_json;
  ] in
  Mcp_server.call_method t.server ~method_:Mcp_types.method_prompts_get ~params

(* --- Ping --- *)

let ping t : (Yojson.Safe.t, Types.error_category) result =
  Mcp_server.call_method t.server ~method_:Mcp_types.method_ping ~params:(`Assoc [])
