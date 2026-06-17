[@@@warning "-8-11-32-33-34-37-69"]
open Yojson.Safe

type server_id = string

let server_id_to_string (s : server_id) : string = s

let server_id_with_suffix (base : server_id) (suffix : string) : server_id =
  base ^ suffix

let server_id_compare (a : server_id) (b : server_id) : int =
  String.compare a b

let server_id_of_string (s : string) : (server_id, Types.error_category) result =
  let reject msg = Error (Types.Invalid_input msg) in
  if String.length s = 0 then
    reject "server_id: empty string"
  else if String.length s > 64 then
    reject (Printf.sprintf "server_id: length %d exceeds 64" (String.length s))
  else if not (Stdlib.String.for_all
                 (fun c ->
                    (c >= 'a' && c <= 'z')
                    || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9')
                    || c = '_' || c = '-' || c = '#')
                 s) then
    reject "server_id: contains forbidden characters (allowed: [A-Za-z0-9_-#])"
  else
    Ok s

type server_config =
  | Stdio_server of {
      name : string;
      command : string;
      args : string list;
      env : (string * string) list;
      cwd : string option;
      startup_timeout : float;
    }
  | Http_server of {
      name : string;
      url : string;
      headers : (string * string) list;
      startup_timeout : float;
    }

let server_name = function
  | Stdio_server s -> s.name
  | Http_server s -> s.name

let server_startup_timeout = function
  | Stdio_server s -> s.startup_timeout
  | Http_server s -> s.startup_timeout

let server_config_to_yojson (cfg : server_config) : Yojson.Safe.t =
  match cfg with
  | Stdio_server s ->
    `Assoc [
      "type", `String "stdio";
      "name", `String s.name;
      "command", `String s.command;
      "args", `List (List.map (fun a -> `String a) s.args);
      "env", `Assoc (List.map (fun (k, v) -> (k, `String v)) s.env);
      "cwd", (match s.cwd with Some d -> `String d | None -> `Null);
      "startup_timeout", `Float s.startup_timeout;
    ]
  | Http_server s ->
    `Assoc [
      "type", `String "http";
      "name", `String s.name;
      "url", `String s.url;
      "headers", `Assoc (List.map (fun (k, v) -> (k, `String v)) s.headers);
      "startup_timeout", `Float s.startup_timeout;
    ]

let server_config_of_yojson (j : Yojson.Safe.t) : (server_config, string) result =
  match j with
  | `Assoc fields ->
    let get_string key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Ok s
      | Some _ -> Error (Printf.sprintf "server_config.%s must be a string" key)
      | None -> Error (Printf.sprintf "server_config missing %s" key)
    in
    let get_string_list key =
      match List.assoc_opt key fields with
      | Some (`List items) ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | `String s :: rest -> loop (s :: acc) rest
          | _ :: _ -> Error (Printf.sprintf "server_config.%s must be a string list" key)
        in
        loop [] items
      | Some _ -> Error (Printf.sprintf "server_config.%s must be a list" key)
      | None -> Ok []
    in
    let get_pair_list key =
      match List.assoc_opt key fields with
      | Some (`Assoc pairs) ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | (k, `String v) :: rest -> loop ((k, v) :: acc) rest
          | _ :: _ -> Error (Printf.sprintf "server_config.%s must be string pairs" key)
        in
        loop [] pairs
      | Some _ -> Error (Printf.sprintf "server_config.%s must be an object" key)
      | None -> Ok []
    in
    let get_opt_string key =
      match List.assoc_opt key fields with
      | Some `Null | None -> Ok None
      | Some (`String s) -> Ok (Some s)
      | Some _ -> Error (Printf.sprintf "server_config.%s must be a string or null" key)
    in
    let get_float key =
      match List.assoc_opt key fields with
      | Some (`Float f) -> Ok f
      | Some (`Int i) -> Ok (float_of_int i)
      | Some _ -> Error (Printf.sprintf "server_config.%s must be a number" key)
      | None -> Error (Printf.sprintf "server_config missing %s" key)
    in
    (match List.assoc_opt "type" fields with
     | Some (`String "stdio") ->
       (match get_string "name" with
        | Error e -> Error e
        | Ok name ->
          match get_string "command" with
          | Error e -> Error e
          | Ok command ->
            match get_string_list "args" with
            | Error e -> Error e
            | Ok args ->
              match get_pair_list "env" with
              | Error e -> Error e
              | Ok env ->
                match get_opt_string "cwd" with
                | Error e -> Error e
                | Ok cwd ->
                  (match get_float "startup_timeout" with
                   | Error e -> Error e
                   | Ok startup_timeout ->
                     Ok (Stdio_server { name; command; args; env; cwd; startup_timeout })))
     | Some (`String "http") ->
       (match get_string "name" with
        | Error e -> Error e
        | Ok name ->
          match get_string "url" with
          | Error e -> Error e
          | Ok url ->
            match get_pair_list "headers" with
            | Error e -> Error e
            | Ok headers ->
              (match get_float "startup_timeout" with
               | Error e -> Error e
               | Ok startup_timeout ->
                 Ok (Http_server { name; url; headers; startup_timeout })))
     | Some (`String t) -> Error ("server_config: unknown type " ^ t)
     | Some _ -> Error "server_config: type must be a string"
     | None -> Error "server_config: missing type")
  | _ -> Error "server_config: must be a JSON object"

type prefix_style =
  | Hierarchical
  | Flat

type startup_policy =
  | Fail_fast
  | Log_and_continue

type request_id = Int_id of int | String_id of string

let request_id_matches a b = match a, b with
  | Int_id i, Int_id j -> i = j
  | String_id s, String_id t -> s = t
  | _ -> false

type jsonrpc_request = {
  id      : request_id;
  method_ : string;
  params  : Yojson.Safe.t option;
}

type jsonrpc_error = {
  code    : int;
  message : string;
  data    : Yojson.Safe.t option;
}

type jsonrpc_response = {
  id     : request_id;
  result : (Yojson.Safe.t, jsonrpc_error) result;
}

type jsonrpc_notification = {
  method_ : string;
  params  : Yojson.Safe.t option;
}

type mcp_tool = {
  name          : string;
  description   : string option;
  title         : string option;
  input_schema  : Yojson.Safe.t;
}
[@@deriving yojson]

type mcp_resource = {
  uri         : string;
  name        : string;
  description : string option;
  mime_type   : string option;
  title       : string option;
}
[@@deriving yojson]

type mcp_prompt_arg = {
  name        : string;
  description : string option;
  required    : bool;
}
[@@deriving yojson]

type mcp_prompt = {
  name        : string;
  description : string option;
  title       : string option;
  arguments   : mcp_prompt_arg list;
}
[@@deriving yojson]

type capabilities = {
  tools     : bool;
  resources : bool;
  prompts   : bool;
  logging   : bool;
  sampling  : bool;
}
[@@deriving yojson]

type server_info = {
  name    : string;
  version : string;
}
[@@deriving yojson]

let request_id_to_yojson (rid : request_id) : Yojson.Safe.t = match rid with
  | Int_id i -> `Int i
  | String_id s -> `String s

let request_id_of_yojson (j : Yojson.Safe.t) : (request_id, string) result =
  match j with
  | `Int i -> Ok (Int_id i)
  | `String s -> Ok (String_id s)
  | `Null -> Error "request_id: null is not accepted (JSON-RPC 2.0)"
  | `Bool _ -> Error "request_id: boolean is not a valid JSON-RPC id"
  | `Float f ->
    if Float.is_integer f then Ok (Int_id (Float.to_int f))
    else Error "request_id: non-integer float is not a valid JSON-RPC id"
  | `Intlit _ -> Error "request_id: integer literal is not a valid JSON-RPC id"
  | `Assoc _ -> Error "request_id: object is not a valid JSON-RPC id"
  | `List _ -> Error "request_id: array is not a valid JSON-RPC id"

let result_field = "result"
let error_field = "error"
let id_field = "id"
let method_field = "method"
let params_field = "params"

let jsonrpc_error_to_yojson (e : jsonrpc_error) : Yojson.Safe.t =
  let base = [
    "code", `Int e.code;
    "message", `String e.message;
  ] in
  match e.data with
  | None -> `Assoc base
  | Some d -> `Assoc (base @ ["data", d])

let jsonrpc_error_of_yojson (j : Yojson.Safe.t) : (jsonrpc_error, string) result =
  match j with
  | `Assoc fields ->
    let get_string key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Ok s
      | Some _ -> Error (Printf.sprintf "jsonrpc_error.%s must be a string" key)
      | None -> Error (Printf.sprintf "jsonrpc_error missing %s" key)
    in
    let get_int key =
      match List.assoc_opt key fields with
      | Some (`Int i) -> Ok i
      | Some _ -> Error (Printf.sprintf "jsonrpc_error.%s must be an int" key)
      | None -> Error (Printf.sprintf "jsonrpc_error missing %s" key)
    in
    (match get_int "code" with
     | Error e -> Error e
     | Ok code ->
       match get_string "message" with
       | Error e -> Error e
       | Ok message ->
         let data =
           match List.assoc_opt "data" fields with
           | None | Some `Null -> None
           | Some j -> Some j
         in
         Ok { code; message; data })
  | _ -> Error "jsonrpc_error must be a JSON object"

let jsonrpc_response_to_yojson (r : jsonrpc_response) : Yojson.Safe.t =
  let id_j = request_id_to_yojson r.id in
  match r.result with
  | Ok res ->
    `Assoc [id_field, id_j; result_field, res]
  | Error err ->
    `Assoc [id_field, id_j; error_field, jsonrpc_error_to_yojson err]

let response_of_yojson (j : Yojson.Safe.t) : (jsonrpc_response, string) result =
  match j with
  | `Assoc fields ->
    (match List.assoc_opt id_field fields with
     | None -> Error "response: missing id"
     | Some id_j ->
       match request_id_of_yojson id_j with
       | Error e -> Error e
       | Ok id ->
         let has_result = List.mem_assoc result_field fields in
         let has_error = List.mem_assoc error_field fields in
         match has_result, has_error with
         | true, true -> Error "response: both result and error present"
         | false, false -> Error "response: neither result nor error present"
         | true, false ->
           Ok { id; result = Ok (List.assoc result_field fields) }
         | false, true ->
           match jsonrpc_error_of_yojson (List.assoc error_field fields) with
           | Error e -> Error e
           | Ok err -> Ok { id; result = Error err })
  | _ -> Error "response: must be a JSON object"

let request_to_yojson (r : jsonrpc_request) : Yojson.Safe.t =
  let base = [
    id_field, request_id_to_yojson r.id;
    method_field, `String r.method_;
  ] in
  match r.params with
  | None -> `Assoc base
  | Some p -> `Assoc (base @ [params_field, p])

let jsonrpc_request_of_yojson (j : Yojson.Safe.t) : (jsonrpc_request, string) result =
  match j with
  | `Assoc fields ->
    (match List.assoc_opt id_field fields with
     | None -> Error "request: missing id"
     | Some id_j ->
       match request_id_of_yojson id_j with
       | Error e -> Error e
       | Ok id ->
         match List.assoc_opt method_field fields with
         | Some (`String m) ->
           let params =
             match List.assoc_opt params_field fields with
             | None | Some `Null -> None
             | Some p -> Some p
           in
           Ok { id; method_ = m; params }
         | Some _ -> Error "request: method must be a string"
         | None -> Error "request: missing method")
  | _ -> Error "request: must be a JSON object"

let notification_to_yojson (n : jsonrpc_notification) : Yojson.Safe.t =
  match n.params with
  | None -> `Assoc [method_field, `String n.method_]
  | Some p -> `Assoc [method_field, `String n.method_; params_field, p]

let notification_of_yojson (j : Yojson.Safe.t)
    : (jsonrpc_notification, string) result =
  match j with
  | `Assoc fields ->
    if List.mem_assoc id_field fields then
      Error "notification: must not carry an id field"
    else
      match List.assoc_opt method_field fields with
      | Some (`String m) ->
        let params =
          match List.assoc_opt params_field fields with
          | None | Some `Null -> None
          | Some p -> Some p
        in
        Ok { method_ = m; params }
      | Some _ -> Error "notification: method must be a string"
      | None -> Error "notification: missing method"
  | _ -> Error "notification: must be a JSON object"

let tool_of_yojson (j : Yojson.Safe.t) : (mcp_tool, string) result =
  match j with
  | `Assoc fields ->
    let get_string key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Ok s
      | Some _ -> Error (Printf.sprintf "tool.%s must be a string" key)
      | None -> Error (Printf.sprintf "tool missing %s" key)
    in
    let get_string_opt key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | _ -> None
    in
    (match get_string "name" with
     | Error e -> Error e
     | Ok name ->
       let description = get_string_opt "description" in
       let title = get_string_opt "title" in
       let input_schema =
         match List.assoc_opt "inputSchema" fields with
         | None | Some `Null -> `Assoc ["type", `String "object"]
         | Some schema -> schema
       in
       Ok { name; description; title; input_schema })
  | _ -> Error "tool: must be a JSON object"

let resource_of_yojson (j : Yojson.Safe.t) : (mcp_resource, string) result =
  match j with
  | `Assoc fields ->
    let get_string key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Ok s
      | Some _ -> Error (Printf.sprintf "resource.%s must be a string" key)
      | None -> Error (Printf.sprintf "resource missing %s" key)
    in
    let get_string_opt key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | _ -> None
    in
    (match get_string "uri" with
     | Error e -> Error e
     | Ok uri ->
       match get_string "name" with
       | Error e -> Error e
       | Ok name ->
         let description = get_string_opt "description" in
         let mime_type = get_string_opt "mimeType" in
         let title = get_string_opt "title" in
         Ok { uri; name; description; mime_type; title })
  | _ -> Error "resource: must be a JSON object"

let prompt_arg_of_yojson (j : Yojson.Safe.t) : (mcp_prompt_arg, string) result =
  match j with
  | `Assoc fields ->
    (match List.assoc_opt "name" fields with
     | Some (`String n) ->
       let description =
         match List.assoc_opt "description" fields with
         | Some (`String s) -> Some s
         | _ -> None
       in
       let required =
         match List.assoc_opt "required" fields with
         | Some (`Bool b) -> b
         | _ -> false
       in
       Ok { name = n; description; required }
     | Some _ -> Error "prompt argument name must be a string"
     | None -> Error "prompt argument missing name")
  | _ -> Error "prompt argument: must be a JSON object"

let prompt_of_yojson (j : Yojson.Safe.t) : (mcp_prompt, string) result =
  match j with
  | `Assoc fields ->
    (match List.assoc_opt "name" fields with
     | Some (`String name) ->
       let description =
         match List.assoc_opt "description" fields with
         | Some (`String s) -> Some s
         | _ -> None
       in
       let title =
         match List.assoc_opt "title" fields with
         | Some (`String s) -> Some s
         | _ -> None
       in
       let arguments : (mcp_prompt_arg list, string) result =
         match List.assoc_opt "arguments" fields with
         | None | Some `Null -> Ok []
         | Some (`List items) ->
           let rec loop acc = function
             | [] -> Ok (List.rev acc)
             | item :: rest ->
               match prompt_arg_of_yojson item with
               | Error e -> Error e
               | Ok arg -> loop (arg :: acc) rest
           in
           loop [] items
         | Some _ -> Error "prompt.arguments must be an array"
       in
       (match arguments with
        | Error e -> Error e
        | Ok args -> Ok { name; description; title; arguments = args })
     | Some _ -> Error "prompt.name must be a string"
     | None -> Error "prompt missing name")
  | _ -> Error "prompt: must be a JSON object"

let capabilities_of_yojson (j : Yojson.Safe.t) : (capabilities, string) result =
  match j with
  | `Assoc fields ->
    let cap key =
      match List.assoc_opt key fields with
      | None -> false
      | Some (`Bool b) -> b
      | Some _ -> true
    in
    Ok {
      tools     = cap "tools";
      resources = cap "resources";
      prompts   = cap "prompts";
      logging   = cap "logging";
      sampling  = cap "sampling";
    }
  | _ -> Error "capabilities: must be a JSON object"

let server_info_of_yojson (j : Yojson.Safe.t) : (server_info, string) result =
  match j with
  | `Assoc fields ->
    (match List.assoc_opt "name" fields with
     | Some (`String name) ->
       (match List.assoc_opt "version" fields with
        | Some (`String version) -> Ok { name; version }
        | Some _ -> Error "serverInfo.version must be a string"
        | None -> Error "serverInfo missing version")
     | Some _ -> Error "serverInfo.name must be a string"
     | None -> Error "serverInfo missing name")
  | _ -> Error "serverInfo: must be a JSON object"

let method_initialize               = "initialize"
let method_initialized              = "notifications/initialized"
let method_tools_list               = "tools/list"
let method_tools_call               = "tools/call"
let method_resources_list           = "resources/list"
let method_resources_read           = "resources/read"
let method_resources_templates_list = "resources/templates/list"
let method_prompts_list             = "prompts/list"
let method_prompts_get              = "prompts/get"
let method_ping                     = "ping"
let method_shutdown                 = "shutdown"
let method_progress                 = "notifications/progress"
let method_cancelled                = "notifications/cancelled"
let method_tools_list_changed       = "notifications/tools/list_changed"

let protocol_version = "2025-06-18"
