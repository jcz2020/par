open Par

(* -------------------------------------------------------------------------- *)
(* Config type                                                                *)
(* -------------------------------------------------------------------------- *)

type mcp_server_entry = {
  name : string;
  command : string;
  args : string list;
  env : (string * string) list;
  startup_timeout : float;
}

type agent_entry = {
  id : string;
  system_prompt : string;
  model : string option;
  max_iterations : int option;
  tools : string list option;
}

type config = {
  provider : string;
  api_key : string;
  api_base : string option;
  model : string;
  persistence : string;
  db_uri : string option;
  temperature : float;
  system_prompt : string;
  (* v0.3.0 new fields *)
  max_iterations : int;
  max_tokens : int option;
  top_p : float option;
  parallel_tool_execution : bool;
  template_variables : (string * string) list;
  system_prompt_template_override : string option;
  (* v0.3.3 MCP *)
  mcp_servers : mcp_server_entry list;
  agents : agent_entry list;
  event_retention_days : float;
}

(* -------------------------------------------------------------------------- *)
(* Default config values                                                      *)
(* -------------------------------------------------------------------------- *)

let default = {
  provider = "openai";
  api_key = "";
  api_base = None;
  model = "gpt-4";
  persistence = "sqlite";
  db_uri = None;
  temperature = 0.7;
  system_prompt = "You are a helpful assistant.";
  max_iterations = 1000000;
  max_tokens = None;
  top_p = None;
  parallel_tool_execution = true;
  template_variables = [("role", "AI助手"); ("task", "回答用户问题并提供帮助")];
  system_prompt_template_override = None;
  mcp_servers = [];
  agents = [];
  event_retention_days = 7.0;
}

(* -------------------------------------------------------------------------- *)
(* Paths                                                                      *)
(* -------------------------------------------------------------------------- *)

let config_dir () =
  let home = match Sys.getenv "HOME" with
    | h -> h
    | exception Not_found -> "/"
  in
  let dir = home ^ "/.par" in
  if not (Sys.file_exists dir) then
    Sys.mkdir dir 0o755;
  dir

let config_path () =
  config_dir () ^ "/config.json"

(* -------------------------------------------------------------------------- *)
(* JSON converters                                                            *)
(* -------------------------------------------------------------------------- *)

let to_json (cfg : config) : Yojson.Safe.t =
  `Assoc [
    ("provider", `String cfg.provider);
    ("api_key", `String cfg.api_key);
    ("api_base", (match cfg.api_base with Some u -> `String u | None -> `Null));
    ("model", `String cfg.model);
    ("persistence", `String cfg.persistence);
    ("db_uri", (match cfg.db_uri with Some u -> `String u | None -> `Null));
    ("temperature", `Float cfg.temperature);
    ("system_prompt", `String cfg.system_prompt);
    ("max_iterations", `Int cfg.max_iterations);
    ("max_tokens", (match cfg.max_tokens with Some n -> `Int n | None -> `Null));
    ("top_p", (match cfg.top_p with Some f -> `Float f | None -> `Null));
    ("parallel_tool_execution", `Bool cfg.parallel_tool_execution);
    ("template_variables", `Assoc (List.map (fun (k, v) -> (k, `String v)) cfg.template_variables));
    ("system_prompt_template_override", (match cfg.system_prompt_template_override with Some s -> `String s | None -> `Null));
    ("mcp_servers", `List (List.map (fun (s : mcp_server_entry) ->
      `Assoc [
        ("name", `String s.name);
        ("command", `String s.command);
        ("args", `List (List.map (fun a -> `String a) s.args));
        ("env", `Assoc (List.map (fun (k, v) -> (k, `String v)) s.env));
        ("startup_timeout", `Float s.startup_timeout);
      ]
    ) cfg.mcp_servers));
    ("agents", `List (List.map (fun (a : agent_entry) ->
      `Assoc [
        ("id", `String a.id);
        ("system_prompt", `String a.system_prompt);
        ("model", (match a.model with Some m -> `String m | None -> `Null));
        ("max_iterations", (match a.max_iterations with Some n -> `Int n | None -> `Null));
        ("tools", (match a.tools with Some names -> `List (List.map (fun n -> `String n) names) | None -> `Null));
      ]
    ) cfg.agents));
    ("event_retention_days", `Float cfg.event_retention_days);
  ]

let of_json (json : Yojson.Safe.t) : (config, string) result =
  try
    let get_string field =
      match Yojson.Safe.Util.(json |> member field |> to_string_option) with
      | Some s -> s
      | None -> ""
    in
    let get_opt_string field =
      match Yojson.Safe.Util.(json |> member field) with
      | `Null -> None
      | v -> (match Yojson.Safe.Util.to_string_option v with
              | Some s -> Some s
              | None -> None)
    in
    let get_float field default =
      match Yojson.Safe.Util.(json |> member field |> to_float_option) with
      | Some f -> f
      | None -> default
    in
    let get_int field default =
      match Yojson.Safe.Util.(json |> member field |> to_int_option) with
      | Some n -> n
      | None -> default
    in
    let get_opt_int field =
      match Yojson.Safe.Util.(json |> member field) with
      | `Int n -> Some n
      | _ -> None
    in
    let get_opt_float field =
      match Yojson.Safe.Util.(json |> member field) with
      | `Float f -> Some f
      | _ -> None
    in
    let get_bool field default =
      match Yojson.Safe.Util.(json |> member field |> to_bool_option) with
      | Some b -> b
      | None -> default
    in
    let get_string_pair_list field =
      match Yojson.Safe.Util.(json |> member field) with
      | `Assoc pairs ->
        List.filter_map (fun (k, v) ->
          match v with `String s -> Some (k, s) | _ -> None) pairs
      | _ -> default.template_variables
    in
    Ok {
      provider = get_string "provider";
      api_key = get_string "api_key";
      api_base = get_opt_string "api_base";
      model = get_string "model";
      persistence = get_string "persistence";
      db_uri = get_opt_string "db_uri";
      temperature = get_float "temperature" default.temperature;
      system_prompt = get_string "system_prompt";
      max_iterations = get_int "max_iterations" default.max_iterations;
      max_tokens = get_opt_int "max_tokens";
      top_p = get_opt_float "top_p";
      parallel_tool_execution = get_bool "parallel_tool_execution" default.parallel_tool_execution;
      template_variables = get_string_pair_list "template_variables";
      system_prompt_template_override = get_opt_string "system_prompt_template_override";
      mcp_servers = (match Yojson.Safe.Util.(json |> member "mcp_servers") with
        | `List entries ->
          List.filter_map (fun entry ->
            match entry with
            | `Assoc fields ->
              let get_s key = match List.assoc_opt key fields with Some (`String s) -> Some s | _ -> None in
              let get_sl key = match List.assoc_opt key fields with
                | Some (`List items) -> List.filter_map (function `String s -> Some s | _ -> None) items
                | _ -> [] in
              let get_pl key = match List.assoc_opt key fields with
                | Some (`Assoc pairs) -> List.filter_map (fun (k, v) -> match v with `String s -> Some (k, s) | _ -> None) pairs
                | _ -> [] in
              let get_f key = match List.assoc_opt key fields with Some (`Float f) -> f | _ -> 10.0 in
              (match get_s "name", get_s "command" with
               | Some name, Some command ->
                 Some { name; command; args = get_sl "args"; env = get_pl "env"; startup_timeout = get_f "startup_timeout" }
               | _ -> None)
            | _ -> None) entries
        | _ -> []);
      agents = (match Yojson.Safe.Util.(json |> member "agents") with
        | `List entries ->
          List.filter_map (fun entry ->
            match entry with
            | `Assoc fields ->
              let get_s key = match List.assoc_opt key fields with Some (`String s) -> Some s | _ -> None in
              let get_opt_int key = match List.assoc_opt key fields with Some (`Int n) -> Some n | _ -> None in
              Some {
                id = (match get_s "id" with Some s -> s | None -> "agent");
                system_prompt = (match get_s "system_prompt" with Some s -> s | None -> "You are a helpful assistant.");
                model = get_s "model";
                max_iterations = get_opt_int "max_iterations";
                tools = (match List.assoc_opt "tools" fields with
                  | Some (`List items) -> Some (List.filter_map (function `String s -> Some s | _ -> None) items)
                  | _ -> None);
              }
            | _ -> None) entries
        | _ -> []);
      event_retention_days = (match Yojson.Safe.Util.(json |> member "event_retention_days") with
        | `Float f -> f
        | `Int i -> float_of_int i
        | _ -> default.event_retention_days);
    }
  with exn ->
    Error (Printexc.to_string exn)

(* -------------------------------------------------------------------------- *)
(* Load / Save                                                                *)
(* -------------------------------------------------------------------------- *)

let load () : config option =
  let path = config_path () in
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      let n = in_channel_length ic in
      let s = Bytes.create n in
      really_input ic s 0 n;
      close_in ic;
      let json = Yojson.Safe.from_string (Bytes.to_string s) in
      (match of_json json with
       | Ok cfg -> Some cfg
       | Error _ -> None)
    with _ -> None

let save (cfg : config) : unit =
  let path = config_path () in
  let oc = open_out path in
  output_string oc (Yojson.Safe.pretty_to_string ~std:true (to_json cfg));
  output_char oc '\n';
  close_out oc

(* -------------------------------------------------------------------------- *)
(* Helpers: convert config to runtime types                                   *)
(* -------------------------------------------------------------------------- *)

let to_provider_tag (cfg : config) : [ `Openai | `Anthropic ] =
  match String.lowercase_ascii cfg.provider with
  | "anthropic" -> `Anthropic
  | _ -> `Openai

let to_model_config (cfg : config) : Types.model_config =
  { Types.
    provider = (match to_provider_tag cfg with `Openai -> `Openai | `Anthropic -> `Anthropic);
    model_name = cfg.model;
    api_base = cfg.api_base;
    temperature = cfg.temperature;
    max_tokens = cfg.max_tokens;
    top_p = cfg.top_p;
    stop_sequences = None;
  }

let to_persistence_config (_cfg : config) : [ `Sqlite of string ] =
  `Sqlite (config_dir () ^ "/par.db")

let resolve_persistence (_cfg : config) =
  `Sqlite (config_dir () ^ "/par.db")

(* -------------------------------------------------------------------------- *)
(* Config wizard (interactive)                                                *)
(* -------------------------------------------------------------------------- *)

let prompt_line label default =
  let prompt = match default with
    | Some d -> Printf.sprintf "%s [%s]: " label d
    | None -> Printf.sprintf "%s: " label
  in
  Printf.printf "%s" prompt;
  flush stdout;
  match input_line stdin with
  | line when String.trim line <> "" -> String.trim line
  | exception End_of_file -> (match default with Some d -> d | None -> "")
  | _ -> (match default with Some d -> d | None -> "")

let prompt_opt_line label =
  let prompt = Printf.sprintf "%s (留空跳过): " label in
  Printf.printf "%s" prompt;
  flush stdout;
  match input_line stdin with
  | line when String.trim line <> "" -> Some (String.trim line)
  | exception End_of_file -> None
  | _ -> None

let run_wizard () =
  let existing = load () in
  (match existing with
    | Some cfg ->
      Printf.printf "当前配置:\n";
      Printf.printf "  Provider:    %s\n" cfg.provider;
      Printf.printf "  Model:       %s\n" cfg.model;
      Printf.printf "  API Base:    %s\n" (match cfg.api_base with Some u -> u | None -> "(默认)");
      Printf.printf "  Persistence: %s\n" cfg.persistence;
      Printf.printf "  DB URI:      %s\n" (match cfg.db_uri with Some u -> u | None -> "(无)");
      Printf.printf "  Temperature: %.1f\n" cfg.temperature;
      Printf.printf "  Max Iterations: %d\n" cfg.max_iterations;
      Printf.printf "  Parallel Tools: %s\n" (if cfg.parallel_tool_execution then "开" else "关");
      (match List.assoc_opt "role" cfg.template_variables with
       | Some r -> Printf.printf "  Role: %s\n" r | None -> ());
      (match List.assoc_opt "task" cfg.template_variables with
       | Some t -> Printf.printf "  Task: %s\n" t | None -> ());
      Printf.printf "\n输入新值或按回车保留当前值。\n\n"
   | None ->
     Printf.printf "欢迎使用 PAR！首次运行配置向导。\n\n");

  let prov_default = match existing with
    | Some c -> Some c.provider | None -> Some default.provider
  in
  let provider = prompt_line "Provider (openai/anthropic)" prov_default in

  let api_key_default = match existing with
    | Some c when c.api_key <> "" -> Some c.api_key | _ -> None
  in
  let api_key = prompt_line "API Key" api_key_default in

  let api_base_hint = match String.lowercase_ascii provider with
    | "anthropic" -> "https://api.anthropic.com"
    | _ -> "https://api.openai.com/v1"
  in
  let api_base =
    let existing_base = match existing with Some c -> c.api_base | None -> None in
    let prompt = Printf.sprintf "API Base URL (默认: %s)%s: "
        api_base_hint
        (match existing_base with Some b -> Printf.sprintf " [%s]" b | None -> "")
    in
    Printf.printf "%s" prompt;
    flush stdout;
    match input_line stdin with
    | line when String.trim line <> "" -> Some (String.trim line)
    | exception End_of_file -> existing_base
    | _ -> existing_base
  in

  let model_default = match existing with
    | Some c -> Some c.model | None -> Some default.model
  in
  let model = prompt_line "Model name" model_default in

  let pers_default = match existing with
    | Some c -> Some c.persistence | None -> Some default.persistence
  in
  let persistence = prompt_line "Persistence (sqlite)" pers_default in
  let db_uri = None in

  let temp_default = match existing with
    | Some c -> Printf.sprintf "%.1f" c.temperature | None -> Printf.sprintf "%.1f" default.temperature
  in
  let temp_str = prompt_line "Temperature" (Some temp_default) in
  let temperature = match float_of_string_opt temp_str with
    | Some f -> f | None -> default.temperature
  in

  let prompt_default = match existing with
    | Some c -> Some c.system_prompt | None -> Some default.system_prompt
  in
  let system_prompt = prompt_line "System prompt" prompt_default in

  let role_default = match existing with
    | Some c -> (match List.assoc_opt "role" c.template_variables with Some r -> Some r | None -> Some "AI助手")
    | None -> Some "AI助手"
  in
  let role = prompt_line "Agent 角色" role_default in

  let task_default = match existing with
    | Some c -> (match List.assoc_opt "task" c.template_variables with Some t -> Some t | None -> Some "回答用户问题并提供帮助")
    | None -> Some "回答用户问题并提供帮助"
  in
  let task = prompt_line "Agent 任务" task_default in

  let max_iter_default = match existing with
    | Some c -> Some (string_of_int c.max_iterations)
    | None -> Some "10"
  in
  let max_iter_str = prompt_line "最大循环次数" max_iter_default in
  let max_iterations = match int_of_string_opt max_iter_str with
    | Some n when n > 0 -> n
    | _ -> 10
  in

  let parallel_default = match existing with
    | Some c -> Some (if c.parallel_tool_execution then "y" else "n")
    | None -> Some "y"
  in
  let parallel_input = prompt_line "并行工具执行 (y/n)" parallel_default in
  let parallel_tool_execution = match String.lowercase_ascii (String.trim parallel_input) with
    | "n" | "no" -> false
    | _ -> true
  in

  let cfg = {
    provider;
    api_key;
    api_base;
    model;
    persistence;
    db_uri;
    temperature;
    system_prompt;
    max_iterations;
    max_tokens = None;
    top_p = None;
    parallel_tool_execution;
    template_variables = [("role", role); ("task", task)];
    system_prompt_template_override = None;
    mcp_servers = [];
    agents = [];
    event_retention_days = default.event_retention_days;
  } in
  save cfg;
  Printf.printf "\n✓ 配置已保存到 %s\n" (config_path ())
