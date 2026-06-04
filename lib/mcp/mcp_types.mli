type server_id = private string
val server_id_of_string : string -> (server_id, Types.error_category) result
val server_id_to_string : server_id -> string
val server_id_compare : server_id -> server_id -> int

type server_config = {
  name            : string;
  command         : string;
  args            : string list;
  env             : (string * string) list;
  cwd             : string option;
  startup_timeout : float;
}

type prefix_style =
  | Hierarchical
  | Flat

type startup_policy =
  | Fail_fast
  | Log_and_continue

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

type request_id = Int_id of int | String_id of string

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

val request_to_yojson         : jsonrpc_request -> Yojson.Safe.t
val jsonrpc_request_of_yojson : Yojson.Safe.t -> (jsonrpc_request, string) result
val jsonrpc_response_to_yojson : jsonrpc_response -> Yojson.Safe.t
val response_of_yojson        : Yojson.Safe.t -> (jsonrpc_response, string) result
val notification_to_yojson    : jsonrpc_notification -> Yojson.Safe.t
val notification_of_yojson    : Yojson.Safe.t -> (jsonrpc_notification, string) result
val tool_of_yojson            : Yojson.Safe.t -> (mcp_tool, string) result
val resource_of_yojson        : Yojson.Safe.t -> (mcp_resource, string) result
val prompt_of_yojson          : Yojson.Safe.t -> (mcp_prompt, string) result
val capabilities_of_yojson    : Yojson.Safe.t -> (capabilities, string) result
val server_info_of_yojson     : Yojson.Safe.t -> (server_info, string) result

val method_initialize                : string
val method_initialized               : string
val method_tools_list                : string
val method_tools_call                : string
val method_resources_list            : string
val method_resources_read            : string
val method_resources_templates_list  : string
val method_prompts_list              : string
val method_prompts_get               : string
val method_ping                      : string
val method_shutdown                  : string
val method_progress                  : string
val method_cancelled                 : string
val method_tools_list_changed        : string

val protocol_version : string
