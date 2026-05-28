open Par

(* -------------------------------------------------------------------------- *)
(* Config type                                                                *)
(* -------------------------------------------------------------------------- *)

type config = {
  provider : string;
  api_key : string;
  api_base : string option;
  model : string;
  persistence : string;
  db_uri : string option;
  temperature : float;
  system_prompt : string;
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
    Ok {
      provider = get_string "provider";
      api_key = get_string "api_key";
      api_base = get_opt_string "api_base";
      model = get_string "model";
      persistence = get_string "persistence";
      db_uri = get_opt_string "db_uri";
      temperature = get_float "temperature" default.temperature;
      system_prompt = get_string "system_prompt";
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
    max_tokens = None;
    top_p = None;
    stop_sequences = None;
  }

let to_persistence_config (cfg : config) : [ `Sqlite of string | `Postgresql of string ] =
  match String.lowercase_ascii cfg.persistence with
  | "postgres" ->
    let uri = match cfg.db_uri with Some u -> u | None -> "postgresql://localhost/par" in
    `Postgresql uri
  | _ ->
    `Sqlite "par.db"

let resolve_persistence (cfg : config) =
  match String.lowercase_ascii cfg.persistence with
  | "postgres" ->
    let conninfo = match cfg.db_uri with Some u -> u | None -> "postgresql://localhost/par" in
    `Postgresql conninfo
  | _ ->
    let path = "par.db" in
    `Sqlite path

(* -------------------------------------------------------------------------- *)
(* Config wizard (interactive)                                                *)
(* -------------------------------------------------------------------------- *)

let prompt_line label default =
  (match default with
   | Some d -> Printf.printf "%s [%s]: " label d
   | None -> Printf.printf "%s: " label);
  flush stdout;
  try
    match input_line stdin with
    | line when String.trim line <> "" -> String.trim line
    | _ -> (match default with Some d -> d | None -> "")
  with End_of_file ->
    (match default with Some d -> d | None -> "")

let prompt_opt_line label =
  Printf.printf "%s (留空跳过): " label;
  flush stdout;
  try
    match input_line stdin with
    | line when String.trim line <> "" -> Some (String.trim line)
    | _ -> None
  with End_of_file -> None

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
    let default_base = match existing_base with
      | Some b -> Some b
      | None -> None
    in
    Printf.printf "API Base URL (默认: %s)" api_base_hint;
    (match default_base with
     | Some b -> Printf.printf " [%s]" b
     | None -> ());
    Printf.printf ": ";
    flush stdout;
    (match input_line stdin with
     | line when String.trim line <> "" -> Some (String.trim line)
     | _ -> default_base)
  in

  let model_default = match existing with
    | Some c -> Some c.model | None -> Some default.model
  in
  let model = prompt_line "Model name" model_default in

  let pers_default = match existing with
    | Some c -> Some c.persistence | None -> Some default.persistence
  in
  let persistence = prompt_line "Persistence (sqlite/postgres)" pers_default in

  let db_uri =
    match String.lowercase_ascii persistence with
    | "postgres" ->
      prompt_opt_line "DB URI"
    | _ -> None
  in

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

  let cfg = {
    provider;
    api_key;
    api_base;
    model;
    persistence;
    db_uri;
    temperature;
    system_prompt;
  } in
  save cfg;
  Printf.printf "\n✓ 配置已保存到 %s\n" (config_path ())
