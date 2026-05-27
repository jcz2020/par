open Par_core

(* -------------------------------------------------------------------------- *)
(* Shared CLI argument definitions                                            *)
(* -------------------------------------------------------------------------- *)

let persistence_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "persistence" ] ~docv:"BACKEND" ~doc:"Storage backend: sqlite|postgres (default: sqlite)")

let db_path =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "db-path" ] ~docv:"PATH" ~doc:"SQLite database path (default: par.db)")

let db_uri =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "db-uri" ] ~docv:"URI" ~doc:"PostgreSQL connection URI")

let provider_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "provider" ] ~docv:"PROVIDER" ~doc:"LLM provider: openai|anthropic (default: openai)")

let api_key =
  let open Cmdliner in
  Arg.(required & opt (some string) None &
    info [ "api-key" ] ~docv:"KEY" ~doc:"API key for LLM provider")

let api_base =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "api-base" ] ~docv:"URL" ~doc:"Custom API base URL")

let model_name =
  let open Cmdliner in
  Arg.(value & opt string "gpt-4" &
    info [ "model" ] ~docv:"NAME" ~doc:"Model name (default: gpt-4)")

let system_prompt =
  let open Cmdliner in
  Arg.(value & opt string "You are a helpful assistant." &
    info [ "system-prompt" ] ~docv:"PROMPT" ~doc:"Agent system prompt")

let agent_id =
  let open Cmdliner in
  Arg.(value & opt string "default-agent" &
    info [ "agent-id" ] ~docv:"ID" ~doc:"Agent ID (default: default-agent)")

let max_iterations =
  let open Cmdliner in
  Arg.(value & opt int 10 &
    info [ "max-iterations" ] ~docv:"N" ~doc:"Max ReAct iterations (default: 10)")

let temperature =
  let open Cmdliner in
  Arg.(value & opt float 0.7 &
    info [ "temperature" ] ~docv:"FLOAT" ~doc:"Temperature (default: 0.7)")

let message_opt =
  let open Cmdliner in
  Arg.(required & opt (some string) None &
    info [ "message"; "m" ] ~docv:"MSG" ~doc:"Message to send to the agent")

let task_id_arg =
  let open Cmdliner in
  Arg.(required & opt (some string) None &
    info [ "task-id" ] ~docv:"ID" ~doc:"Task ID")

let run_id_arg =
  let open Cmdliner in
  Arg.(required & opt (some string) None &
    info [ "run-id" ] ~docv:"ID" ~doc:"Workflow run ID")

let workflow_file =
  let open Cmdliner in
  Arg.(required & opt (some string) None &
    info [ "workflow-file" ] ~docv:"PATH" ~doc:"Path to workflow JSON file")

(* -------------------------------------------------------------------------- *)
(* Shared helpers                                                             *)
(* -------------------------------------------------------------------------- *)

let error_category_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid input: %s" s
  | Types.External_failure s -> Printf.sprintf "External failure: %s" s
  | Types.Rate_limited -> "Rate limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission denied: %s" s
  | Types.Internal s -> Printf.sprintf "Internal error: %s" s

let resolve_persistence_config backend db_path_val db_uri_val =
  match backend with
  | Some "postgres" ->
    let uri = match db_uri_val with Some u -> u | None -> "postgresql://localhost/par" in
    `Postgresql uri
  | Some "sqlite" | None ->
    let path = match db_path_val with Some p -> p | None -> "par.db" in
    `Sqlite path
  | Some other ->
    Printf.eprintf "Error: unknown persistence backend '%s'\n" other;
    exit 1

let make_sqlite_persistence db_path =
  match Par_sqlite.Sqlite_persistence.create db_path with
  | Error e ->
    Printf.eprintf "Error opening SQLite database: %s\n" (error_category_to_string e);
    exit 1
  | Ok t ->
    { Types.
      save_events_fn = (fun events -> Par_sqlite.Sqlite_persistence.save_events t events);
      load_events_fn = (fun task_id -> Par_sqlite.Sqlite_persistence.load_events t task_id);
      save_task_state_fn = (fun ts -> Par_sqlite.Sqlite_persistence.save_task_state t ts);
      load_task_state_fn = (fun task_id -> Par_sqlite.Sqlite_persistence.load_task_state t task_id);
      close_fn = (fun () -> Par_sqlite.Sqlite_persistence.close t);
    }

let make_persistence_service backend db_path_val _db_uri_val =
  match backend with
  | Some "postgres" ->
    Printf.eprintf "PostgreSQL not yet implemented\n"; exit 1
  | Some "sqlite" | None ->
    let path = match db_path_val with Some p -> p | None -> "par.db" in
    make_sqlite_persistence path
  | Some other ->
    Printf.eprintf "Error: unknown persistence backend '%s'\n" other;
    exit 1

let resolve_provider provider_val =
  match provider_val with
  | Some "anthropic" -> `Anthropic
  | Some "openai" | None -> `Openai
  | Some other ->
    Printf.eprintf "Error: unknown provider '%s'\n" other;
    exit 1

let make_llm_service provider_tag api_key_val api_base_val (net : [< `Generic | `Unix > `Generic ] Eio.Net.ty Eio.Resource.t) =
  let open Types in
  let net_gen = (net :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  match provider_tag with
  | `Openai ->
    let cfg = Openai { api_key = api_key_val; base_url = api_base_val; organization = None } in
    (match Par_openai.Openai_provider.create cfg with
     | Error e ->
       Printf.eprintf "Error creating OpenAI provider: %s\n" (error_category_to_string e);
       exit 1
      | Ok t ->
        Par_openai.Openai_provider.set_network t net_gen;
        { complete_fn = (fun mc tools conv -> Par_openai.Openai_provider.complete t mc tools conv);
          stream_fn = (fun mc tools conv sc cb -> Par_openai.Openai_provider.stream t mc tools conv sc cb);
          close_fn = (fun () -> Par_openai.Openai_provider.close t) })
  | `Anthropic ->
    let cfg = Anthropic { api_key = api_key_val; base_url = api_base_val } in
    (match Par_anthropic.Anthropic_provider.create cfg with
     | Error e ->
       Printf.eprintf "Error creating Anthropic provider: %s\n" (error_category_to_string e);
       exit 1
     | Ok t ->
       Par_anthropic.Anthropic_provider.set_network t net_gen;
       { complete_fn = (fun mc tools conv -> Par_anthropic.Anthropic_provider.complete t mc tools conv);
         stream_fn = (fun mc tools conv sc cb -> Par_anthropic.Anthropic_provider.stream t mc tools conv sc cb);
         close_fn = (fun () -> Par_anthropic.Anthropic_provider.close t) })

let make_runtime_config persistence_val =
  { Types.
    persistence = persistence_val;
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [] }

(* -------------------------------------------------------------------------- *)
(* Built-in tools                                                              *)
(* -------------------------------------------------------------------------- *)

let builtin_tools ~switch =
  let open Types in
  let token = Cancellation.create_token switch in

  (* calculator: evaluates arithmetic expressions *)
  let calculator =
    { name = "calculator"
    ; description = "Evaluate a mathematical expression and return the numeric result. \
                     Input: {\"expression\": \"2 + 3 * 4\"}. Supports +, -, *, /, parentheses."
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc
            [("expression", `Assoc [("type", `String "string"); ("description", `String "Math expression to evaluate")])])
        ; ("required", `List [`String "expression"])
        ]
    ; handler = (fun input _tok ->
        let expr = match Yojson.Safe.Util.(input |> member "expression" |> to_string_option) with
          | Some e -> e | None -> ""
        in
        let ops = [("+", ( +. )); ("-", ( -. )); ("*", ( *. )); ("/", ( /. ))] in
        let clean = String.trim expr in
        if clean = "" then
          Error { category = Invalid_input "Empty expression"; message = "Empty"; retryable = false; metadata = [] }
        else
          (try
            (* Use OCaml's expression parser via a safe subset *)
            let tokens = ref [] in
            let buf = Buffer.create 16 in
            let flush_buf () =
              if Buffer.length buf > 0 then
                (tokens := Buffer.contents buf :: !tokens; Buffer.clear buf)
            in
            String.iter (fun c ->
              if c = ' ' then flush_buf ()
              else if List.exists (fun (op, _) -> String.make 1 c = op) ops then begin
                flush_buf ();
                tokens := String.make 1 c :: !tokens
              end else Buffer.add_char buf c
            ) clean;
            flush_buf ();
            let toks = List.filter (fun s -> s <> "") !tokens in
            (* Simple recursive descent for +/- with *// precedence *)
            let parse_num s =
              match float_of_string_opt s with
              | Some f -> f
              | None -> 0.0
            in
            let rec parse_addsub acc = function
              | [] -> acc
              | "+" :: rest ->
                let (v, rest') = collect_muldiv rest in
                parse_addsub (acc +. v) rest'
              | "-" :: rest ->
                let (v, rest') = collect_muldiv rest in
                parse_addsub (acc -. v) rest'
              | _ :: _ as rest ->
                let (v, rest') = collect_muldiv rest in
                parse_addsub v rest'
            and collect_muldiv toks =
              let rec gather acc toks =
                match toks with
                | "*" :: n :: rest -> gather (acc *. parse_num n) rest
                | "/" :: n :: rest -> gather (acc /. parse_num n) rest
                | "+" :: _ | "-" :: _ | [] -> (acc, toks)
                | n :: rest -> gather (parse_num n) rest
              in
              match toks with
              | n :: rest -> gather (parse_num n) rest
              | [] -> (0.0, [])
            in
            let r = parse_addsub 0.0 toks in
            if Float.is_integer r then
              Success (`Float (Float.of_int (int_of_float r)))
            else
              Success (`Float r)
          with _ ->
            Error { category = Invalid_input "Failed to parse expression"; message = "Parse error"; retryable = false; metadata = [] }))
    ; permission = Allow
    ; timeout = Some 5.0
    ; concurrency_limit = None
    }
  in

  (* get_time: returns current UTC time *)
  let get_time =
    { name = "get_time"
    ; description = "Get the current date and time in UTC. Input: {}"
    ; input_schema = `Assoc [("type", `String "object"); ("properties", `Assoc [])]
    ; handler = (fun _input _tok ->
        let tm = Unix.gmtime (Unix.time ()) in
        let iso = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (1900 + tm.Unix.tm_year) (1 + tm.Unix.tm_mon) tm.Unix.tm_mday
          tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
        in
        Success (`String iso))
    ; permission = Allow
    ; timeout = Some 2.0
    ; concurrency_limit = None
    }
  in

  (* echo: returns the input as-is *)
  let echo =
    { name = "echo"
    ; description = "Echo back the input text. Input: {\"text\": \"...\"}"
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc [("text", `Assoc [("type", `String "string")])])
        ; ("required", `List [`String "text"])
        ]
    ; handler = (fun input _tok ->
        let txt = match Yojson.Safe.Util.(input |> member "text" |> to_string_option) with
          | Some s -> s | None -> Yojson.Safe.to_string input
        in
        Success (`String txt))
    ; permission = Allow
    ; timeout = Some 2.0
    ; concurrency_limit = None
    }
  in

  (* generate_uuid: UUID v4 *)
  let generate_uuid_tool =
    { name = "generate_uuid"
    ; description = "Generate a random UUID v4. Input: {}"
    ; input_schema = `Assoc [("type", `String "object"); ("properties", `Assoc [])]
    ; handler = (fun _input _tok ->
        let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () in
        Success (`String (Uuidm.to_string uuid)))
    ; permission = Allow
    ; timeout = Some 1.0
    ; concurrency_limit = None
    }
  in

  (* hash_text: hash of text *)
  let hash_text =
    { name = "hash_text"
    ; description = "Compute a hash of text. Input: {\"text\": \"...\", \"algorithm\": \"sha256\"}. \
                     Supported: md5, sha1, sha256 (default)."
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc
            [ ("text", `Assoc [("type", `String "string"); ("description", `String "Text to hash")])
            ; ("algorithm", `Assoc [("type", `String "string"); ("description", `String "md5, sha1, or sha256 (default)")])
            ])
        ; ("required", `List [`String "text"])
        ]
    ; handler = (fun input _tok ->
        let txt = match Yojson.Safe.Util.(input |> member "text" |> to_string_option) with
          | Some s -> s | None -> ""
        in
        let algo = match Yojson.Safe.Util.(input |> member "algorithm" |> to_string_option) with
          | Some a -> String.lowercase_ascii a | None -> "sha256"
        in
        let hex =
          if algo = "md5" then Digest.to_hex (Digest.string txt)
          else if algo = "sha1" then Digestif.SHA1.to_hex (Digestif.SHA1.digest_string txt)
          else Digestif.SHA256.to_hex (Digestif.SHA256.digest_string txt)
        in
        Success (`Assoc [("hash", `String hex); ("algorithm", `String algo)]))
    ; permission = Allow
    ; timeout = Some 2.0
    ; concurrency_limit = None
    }
  in

  (* generate_password: random secure password *)
  let generate_password_tool =
    { name = "generate_password"
    ; description = "Generate a random password. Input: {\"length\": 16, \"include_symbols\": true}"
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc
            [ ("length", `Assoc [("type", `String "integer"); ("description", `String "Password length (default 16)")])
            ; ("include_symbols", `Assoc [("type", `String "boolean"); ("description", `String "Include !@#$%^&* symbols (default true)")])
            ])
        ]
    ; handler = (fun input _tok ->
        let len = match Yojson.Safe.Util.(input |> member "length" |> to_int_option) with
          | Some n -> max 4 (min 128 n)
          | None -> 16
        in
        let with_symbols = match Yojson.Safe.Util.(input |> member "include_symbols" |> to_bool_option) with
          | Some b -> b | None -> true
        in
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
          ^ if with_symbols then "!@#$%^&*" else ""
        in
        let chars_len = String.length chars in
        let rng = Random.State.make_self_init () in
        let buf = Bytes.create len in
        for i = 0 to len - 1 do
          Bytes.set buf i chars.[Random.State.int rng chars_len]
        done;
        Success (`String (Bytes.to_string buf)))
    ; permission = Allow
    ; timeout = Some 1.0
    ; concurrency_limit = None
    }
  in

  (* string_stats: word/char/line count *)
  let string_stats =
    { name = "string_stats"
    ; description = "Count characters, words, and lines in text. Input: {\"text\": \"...\"}"
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc [("text", `Assoc [("type", `String "string"); ("description", `String "Text to analyze")])])
        ; ("required", `List [`String "text"])
        ]
    ; handler = (fun input _tok ->
        let txt = match Yojson.Safe.Util.(input |> member "text" |> to_string_option) with
          | Some s -> s | None -> ""
        in
        let char_count = String.length txt in
        let line_count = List.length (String.split_on_char '\n' txt) in
        let words = String.split_on_char ' ' (String.concat " " (String.split_on_char '\n' txt)) in
        let word_count = List.length (List.filter (fun w -> String.length (String.trim w) > 0) words) in
        Success (`Assoc [
          ("characters", `Int char_count);
          ("words", `Int word_count);
          ("lines", `Int line_count);
        ]))
    ; permission = Allow
    ; timeout = Some 1.0
    ; concurrency_limit = None
    }
  in

  (* json_format: pretty print JSON *)
  let json_format =
    { name = "json_format"
    ; description = "Format and validate a JSON string. Input: {\"json\": \"{\\\"key\\\": \\\"value\\\"}\"}"
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc [("json", `Assoc [("type", `String "string"); ("description", `String "JSON string to format")])])
        ; ("required", `List [`String "json"])
        ]
    ; handler = (fun input _tok ->
        let json_str = match Yojson.Safe.Util.(input |> member "json" |> to_string_option) with
          | Some s -> s | None -> "{}"
        in
        (try
           let json = Yojson.Safe.from_string json_str in
           Success (`String (Yojson.Safe.pretty_to_string ~std:true json))
         with Yojson.Json_error msg ->
           Error { category = Invalid_input ("Invalid JSON: " ^ msg); message = msg; retryable = false; metadata = [] }))
    ; permission = Allow
    ; timeout = Some 2.0
    ; concurrency_limit = None
    }
  in

  (* convert_temperature: C/F/K conversion *)
  let convert_temperature_tool =
    { name = "convert_temperature"
    ; description = "Convert temperature between Celsius, Fahrenheit, and Kelvin. \
                     Input: {\"value\": 100, \"from\": \"C\", \"to\": \"F\"}"
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc
            [ ("value", `Assoc [("type", `String "number"); ("description", `String "Temperature value")])
            ; ("from", `Assoc [("type", `String "string"); ("description", `String "Unit: C, F, or K")])
            ; ("to", `Assoc [("type", `String "string"); ("description", `String "Unit: C, F, or K")])
            ])
        ; ("required", `List [`String "value"; `String "from"; `String "to"])
        ]
    ; handler = (fun input _tok ->
        let value = match Yojson.Safe.Util.(input |> member "value") with
          | `Float f -> f | `Int n -> float_of_int n | _ -> 0.0
        in
        let from_unit = match Yojson.Safe.Util.(input |> member "from" |> to_string_option) with
          | Some s -> String.uppercase_ascii s | None -> "C"
        in
        let to_unit = match Yojson.Safe.Util.(input |> member "to" |> to_string_option) with
          | Some s -> String.uppercase_ascii s | None -> "F"
        in
        let to_celsius v = match from_unit with
          | "F" -> (v -. 32.0) *. 5.0 /. 9.0
          | "K" -> v -. 273.15
          | _ -> v
        in
        let from_celsius c = match to_unit with
          | "F" -> c *. 9.0 /. 5.0 +. 32.0
          | "K" -> c +. 273.15
          | _ -> c
        in
        let result = from_celsius (to_celsius value) in
        Success (`Assoc [
          ("value", `Float result);
          ("unit", `String to_unit);
          ("original_value", `Float value);
          ("original_unit", `String from_unit);
        ]))
    ; permission = Allow
    ; timeout = Some 1.0
    ; concurrency_limit = None
    }
  in

  (* url_encode: URL encode/decode *)
  let url_encode_tool =
    { name = "url_encode"
    ; description = "URL-encode or URL-decode a string. Input: {\"text\": \"hello world\", \"decode\": false}"
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc
            [ ("text", `Assoc [("type", `String "string"); ("description", `String "Text to encode/decode")])
            ; ("decode", `Assoc [("type", `String "boolean"); ("description", `String "true to decode, false to encode (default)")])
            ])
        ; ("required", `List [`String "text"])
        ]
    ; handler = (fun input _tok ->
        let text = match Yojson.Safe.Util.(input |> member "text" |> to_string_option) with
          | Some s -> s | None -> ""
        in
        let decode = match Yojson.Safe.Util.(input |> member "decode" |> to_bool_option) with
          | Some b -> b | None -> false
        in
        if decode then begin
          let len = String.length text in
          let buf = Buffer.create len in
          let i = ref 0 in
          while !i < len do
            let c = String.get text !i in
            if Char.equal c '%' && !i + 2 < len then begin
              let hex = String.sub text (!i + 1) 2 in
              (try Buffer.add_char buf (Char.chr (int_of_string ("0x" ^ hex)))
               with _ -> Buffer.add_char buf c);
              i := !i + 3
            end else if Char.equal c '+' then begin
              Buffer.add_char buf ' ';
              incr i
            end else begin
              Buffer.add_char buf c;
              incr i
            end
          done;
          Success (`String (Buffer.contents buf))
        end else begin
          let safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~" in
          let buf = Buffer.create (String.length text * 3) in
          String.iter (fun c ->
            if String.contains safe c then Buffer.add_char buf c
            else Printf.bprintf buf "%%%02X" (Char.code c)
          ) text;
          Success (`String (Buffer.contents buf))
        end)
    ; permission = Allow
    ; timeout = Some 1.0
    ; concurrency_limit = None
    }
  in

  ignore token;
  [ calculator
  ; get_time
  ; echo
  ; generate_uuid_tool
  ; hash_text
  ; generate_password_tool
  ; string_stats
  ; json_format
  ; convert_temperature_tool
  ; url_encode_tool
  ]

let make_agent_config id prompt provider_tag model temp max_iter tools =
  { Types.
    id; system_prompt = prompt;
    model = {
      provider = (match provider_tag with `Openai -> `Openai | `Anthropic -> `Anthropic);
      model_name = model; api_base = None; temperature = temp;
      max_tokens = None; top_p = None; stop_sequences = None;
    };
    tools; max_iterations = max_iter; middleware = [];
    retry_policy = None; context_strategy = None; resource_quota = None }

let print_error (e : Types.error_category) =
  Printf.eprintf "Error: %s\n" (error_category_to_string e)

let error_to_json (e : Types.error_category) =
  `Assoc [ ("error", `String (error_category_to_string e)) ]

let print_json json =
  Printf.printf "%s\n" (Yojson.Safe.pretty_to_string ~std:true json)

let die json = print_json json; exit 1
let die_error e = print_error e; exit 1

(* -------------------------------------------------------------------------- *)
(* REPL loop for 'par run'                                                    *)
(* -------------------------------------------------------------------------- *)

let repl rt agent_id_val =
  Printf.printf "par> Enter messages (Ctrl+D to exit)\n";
  let rec loop () =
    Printf.printf "par> ";
    flush stdout;
    (try
       match input_line stdin with
       | line when String.trim line = "" -> loop ()
       | line ->
         (match Runtime.invoke rt ~agent_id:agent_id_val ~message:line () with
          | Error e -> print_error e
          | Ok resp ->
            (match resp.Types.text with
             | Some txt -> Printf.printf "%s\n" txt
             | None -> print_json (Types.llm_response_to_yojson resp));
            flush stdout);
         loop ()
     with End_of_file -> Printf.printf "\nGoodbye.\n")
  in
  loop ()

(* -------------------------------------------------------------------------- *)
(* 'par run' subcommand                                                       *)
(* -------------------------------------------------------------------------- *)

let ensure_rng () =
  Mirage_crypto_rng_unix.use_default ()

let cmd_run persistence_val db_path_val db_uri_val provider_val
      api_key_val api_base_val model_val prompt agent_id_val
      max_iter temp =
  ensure_rng ();
  let pers = make_persistence_service persistence_val db_path_val db_uri_val in
  let persistence_config = resolve_persistence_config persistence_val db_path_val db_uri_val in
  let provider_tag = resolve_provider provider_val in
  let config = make_runtime_config persistence_config in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun switch ->
  let net = Eio.Stdenv.net env in
  let llm = make_llm_service provider_tag api_key_val api_base_val net in
  match Runtime.create ~persistence:pers ~llm ~config switch with
  | Error e -> die_error e
  | Ok rt ->
    let tools = builtin_tools ~switch in
    let agent = make_agent_config agent_id_val prompt provider_tag model_val temp max_iter tools in
    (match Runtime.register_agent rt agent with
     | Error e -> die_error e
     | Ok () ->
        repl rt agent_id_val;
       ignore (Runtime.close rt))

let term_run =
  let open Cmdliner.Term in
  const cmd_run
  $ persistence_arg $ db_path $ db_uri $ provider_arg
  $ api_key $ api_base $ model_name $ system_prompt $ agent_id
  $ max_iterations $ temperature

let info_run = Cmdliner.Cmd.info "run" ~doc:"Start runtime and run agent interactively"

(* -------------------------------------------------------------------------- *)
(* 'par invoke' subcommand                                                    *)
(* -------------------------------------------------------------------------- *)

let cmd_invoke persistence_val db_path_val db_uri_val provider_val
      api_key_val api_base_val model_val agent_id_val msg temp =
  ensure_rng ();
  let pers = make_persistence_service persistence_val db_path_val db_uri_val in
  let persistence_config = resolve_persistence_config persistence_val db_path_val db_uri_val in
  let provider_tag = resolve_provider provider_val in
  let config = make_runtime_config persistence_config in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun switch ->
  let net = Eio.Stdenv.net env in
  let llm = make_llm_service provider_tag api_key_val api_base_val net in
  match Runtime.create ~persistence:pers ~llm ~config switch with
  | Error e -> die (error_to_json e)
  | Ok rt ->
    let tools = builtin_tools ~switch in
    let agent = make_agent_config agent_id_val "" provider_tag model_val temp 10 tools in
    (match Runtime.register_agent rt agent with
     | Error e -> die (error_to_json e)
     | Ok () ->
       (match Runtime.invoke rt ~agent_id:agent_id_val ~message:msg () with
        | Error e -> die (error_to_json e)
        | Ok resp ->
          print_json (Types.llm_response_to_yojson resp);
          ignore (Runtime.close rt)))

let term_invoke =
  let open Cmdliner.Term in
  const cmd_invoke
  $ persistence_arg $ db_path $ db_uri $ provider_arg
  $ api_key $ api_base $ model_name $ agent_id $ message_opt $ temperature

let info_invoke = Cmdliner.Cmd.info "invoke" ~doc:"Send a single message to an agent and print response as JSON"

(* -------------------------------------------------------------------------- *)
(* 'par task submit' subcommand                                               *)
(* -------------------------------------------------------------------------- *)

let cmd_task_submit persistence_val db_path_val db_uri_val _provider_val
      _api_key_val _api_base_val agent_id_val msg =
  let pers = make_persistence_service persistence_val db_path_val db_uri_val in
  let persistence_config = resolve_persistence_config persistence_val db_path_val db_uri_val in
  let config = make_runtime_config persistence_config in
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun switch ->
  match Runtime.create ~persistence:pers ~config switch with
  | Error e -> die (error_to_json e)
  | Ok rt ->
    let input = Types.Agent_input { agent_id = agent_id_val; message = msg } in
    let task_id = Runtime.submit_task rt input in
    print_json (`Assoc [ ("task_id", `String (Types.Task_id.to_string task_id)) ]);
    ignore (Runtime.close rt)

let term_task_submit =
  let open Cmdliner.Term in
  const cmd_task_submit
  $ persistence_arg $ db_path $ db_uri $ provider_arg $ api_key $ api_base
  $ agent_id $ message_opt

let info_task_submit = Cmdliner.Cmd.info "submit" ~doc:"Submit a task to the runtime"

(* -------------------------------------------------------------------------- *)
(* 'par task status' subcommand                                               *)
(* -------------------------------------------------------------------------- *)

let cmd_task_status persistence_val db_path_val db_uri_val tid =
  let pers = make_persistence_service persistence_val db_path_val db_uri_val in
  let persistence_config = resolve_persistence_config persistence_val db_path_val db_uri_val in
  let config = make_runtime_config persistence_config in
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun switch ->
  match Runtime.create ~persistence:pers ~config switch with
  | Error e -> die (error_to_json e)
  | Ok rt ->
    (match Runtime.get_task_status rt tid with
     | Error e -> die (error_to_json e)
     | Ok None ->
       print_json (`Assoc [ ("status", `String "not_found") ]);
       ignore (Runtime.close rt)
     | Ok (Some status) ->
       print_json (`Assoc [ ("status", `String (Types.status_to_string status)) ]);
       ignore (Runtime.close rt))

let term_task_status =
  let open Cmdliner.Term in
  const (fun p db u tid_s ->
    match Types.Task_id.of_string tid_s with
    | Error (`Invalid_id s) -> Printf.eprintf "Invalid task ID: %s\n" s; exit 1
    | Ok tid -> cmd_task_status p db u tid)
  $ persistence_arg $ db_path $ db_uri $ task_id_arg

let info_task_status = Cmdliner.Cmd.info "status" ~doc:"Get task status"

(* -------------------------------------------------------------------------- *)
(* 'par task cancel' subcommand                                               *)
(* -------------------------------------------------------------------------- *)

let cmd_task_cancel persistence_val db_path_val db_uri_val tid =
  let pers = make_persistence_service persistence_val db_path_val db_uri_val in
  let persistence_config = resolve_persistence_config persistence_val db_path_val db_uri_val in
  let config = make_runtime_config persistence_config in
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun switch ->
  match Runtime.create ~persistence:pers ~config switch with
  | Error e -> die (error_to_json e)
  | Ok rt ->
    (match Runtime.cancel_task rt tid with
     | Error e -> die (error_to_json e)
     | Ok () ->
       print_json (`Assoc [ ("result", `String "cancelled") ]);
       ignore (Runtime.close rt))

let term_task_cancel =
  let open Cmdliner.Term in
  const (fun p db u tid_s ->
    match Types.Task_id.of_string tid_s with
    | Error (`Invalid_id s) -> Printf.eprintf "Invalid task ID: %s\n" s; exit 1
    | Ok tid -> cmd_task_cancel p db u tid)
  $ persistence_arg $ db_path $ db_uri $ task_id_arg

let info_task_cancel = Cmdliner.Cmd.info "cancel" ~doc:"Cancel a task"

(* -------------------------------------------------------------------------- *)
(* 'par task' group                                                           *)
(* -------------------------------------------------------------------------- *)

let cmd_task =
  let open Cmdliner.Cmd in
  group (info "task" ~doc:"Task management") [
    v info_task_submit term_task_submit;
    v info_task_status term_task_status;
    v info_task_cancel term_task_cancel;
  ]

(* -------------------------------------------------------------------------- *)
(* 'par workflow submit' subcommand                                           *)
(* -------------------------------------------------------------------------- *)

let cmd_workflow_submit persistence_val db_path_val db_uri_val provider_val
      api_key_val api_base_val model_val temp max_iter wf_path =
  ensure_rng ();
  let pers = make_persistence_service persistence_val db_path_val db_uri_val in
  let persistence_config = resolve_persistence_config persistence_val db_path_val db_uri_val in
  let provider_tag = resolve_provider provider_val in
  let config = make_runtime_config persistence_config in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun switch ->
  let net = Eio.Stdenv.net env in
  let llm = make_llm_service provider_tag api_key_val api_base_val net in
  match Runtime.create ~persistence:pers ~llm ~config switch with
  | Error e -> die (error_to_json e)
  | Ok rt ->
    let tools = builtin_tools ~switch in
    let prompt = "You are a helpful assistant. You have access to these tools:\n\
                  - calculator: evaluate math expressions (e.g. \"2 + 3 * 4\")\n\
                  - get_time: get current UTC date/time\n\
                  - echo: echo back text\n\
                  - generate_uuid: generate a random UUID v4\n\
                  - hash_sha256: compute SHA256 hash of text\n\
                  - generate_password: generate a random password (configurable length, optional symbols)\n\
                  - string_stats: count characters, words, lines in text\n\
                  - json_format: format and validate JSON\n\
                  - convert_temperature: convert between C/F/K\n\
                  - url_encode: URL-encode or URL-decode text\n\
                  Use tools when they are helpful to answer the user's question." in
    let agent = make_agent_config "default-agent" prompt provider_tag model_val temp max_iter tools in
    (match Runtime.register_agent rt agent with
     | Error e -> die (error_to_json e)
     | Ok () ->
       let json_str =
         let ic = open_in wf_path in
         let n = in_channel_length ic in
         let s = Bytes.create n in
         really_input ic s 0 n;
         close_in ic;
         Bytes.to_string s
       in
       let json = Yojson.Safe.from_string json_str in
       let workflow : Types.workflow = {
         id = (match Yojson.Safe.Util.(json |> member "id" |> to_string_option) with
               | Some s -> s | None -> Types.Task_id.to_string (Types.Task_id.create ()));
         name = (match Yojson.Safe.Util.(json |> member "name" |> to_string_option) with
                 | Some s -> s | None -> "unnamed");
         version = (match Yojson.Safe.Util.(json |> member "version" |> to_int_option) with
                    | Some v -> v | None -> 1);
         steps = (match Types.workflow_step_of_yojson
                        (Yojson.Safe.Util.member "steps" json) with
                  | Ok s -> s | Error _ -> Types.Sequential []);
         variables = [];
         failure_policy = Types.Fail_fast;
         parallel_limit = 5;
         timeout = 300.0;
         on_complete = None;
       } in
       (match Runtime.submit_workflow rt workflow with
        | Error e -> die (error_to_json e)
        | Ok run_id ->
          print_json (`Assoc [ ("run_id", `String (Types.Workflow_run_id.to_string run_id)) ]);
          ignore (Runtime.close rt)))

let term_workflow_submit =
  let open Cmdliner.Term in
  const cmd_workflow_submit
  $ persistence_arg $ db_path $ db_uri $ provider_arg
  $ api_key $ api_base $ model_name $ temperature $ max_iterations
  $ workflow_file

let info_workflow_submit = Cmdliner.Cmd.info "submit" ~doc:"Submit a workflow from a JSON file"

(* -------------------------------------------------------------------------- *)
(* 'par workflow status' subcommand                                           *)
(* -------------------------------------------------------------------------- *)

let cmd_workflow_status persistence_val db_path_val db_uri_val rid =
  let pers = make_persistence_service persistence_val db_path_val db_uri_val in
  let persistence_config = resolve_persistence_config persistence_val db_path_val db_uri_val in
  let config = make_runtime_config persistence_config in
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun switch ->
  match Runtime.create ~persistence:pers ~config switch with
  | Error e -> die (error_to_json e)
  | Ok rt ->
    (match Runtime.get_workflow_status rt rid with
     | Error e -> die (error_to_json e)
     | Ok status ->
       print_json (Types.workflow_status_to_yojson status);
       ignore (Runtime.close rt))

let term_workflow_status =
  let open Cmdliner.Term in
  const (fun p db u rid_s ->
    let rid = Types.Workflow_run_id.of_string rid_s in
    cmd_workflow_status p db u rid)
  $ persistence_arg $ db_path $ db_uri $ run_id_arg

let info_workflow_status = Cmdliner.Cmd.info "status" ~doc:"Get workflow run status"

(* -------------------------------------------------------------------------- *)
(* 'par workflow cancel' subcommand                                           *)
(* -------------------------------------------------------------------------- *)

let cmd_workflow_cancel persistence_val db_path_val db_uri_val rid =
  let pers = make_persistence_service persistence_val db_path_val db_uri_val in
  let persistence_config = resolve_persistence_config persistence_val db_path_val db_uri_val in
  let config = make_runtime_config persistence_config in
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun switch ->
  match Runtime.create ~persistence:pers ~config switch with
  | Error e -> die (error_to_json e)
  | Ok rt ->
    (match Runtime.cancel_workflow rt rid with
     | Error e -> die (error_to_json e)
     | Ok () ->
       print_json (`Assoc [ ("result", `String "cancelled") ]);
       ignore (Runtime.close rt))

let term_workflow_cancel =
  let open Cmdliner.Term in
  const (fun p db u rid_s ->
    let rid = Types.Workflow_run_id.of_string rid_s in
    cmd_workflow_cancel p db u rid)
  $ persistence_arg $ db_path $ db_uri $ run_id_arg

let info_workflow_cancel = Cmdliner.Cmd.info "cancel" ~doc:"Cancel a workflow run"

(* -------------------------------------------------------------------------- *)
(* 'par workflow' group                                                       *)
(* -------------------------------------------------------------------------- *)

let cmd_workflow =
  let open Cmdliner.Cmd in
  group (info "workflow" ~doc:"Workflow management") [
    v info_workflow_submit term_workflow_submit;
    v info_workflow_status term_workflow_status;
    v info_workflow_cancel term_workflow_cancel;
  ]

(* -------------------------------------------------------------------------- *)
(* Root command                                                               *)
(* -------------------------------------------------------------------------- *)

let cmd =
  let open Cmdliner.Cmd in
  group
    (info "par" ~version:"0.1.0"
       ~doc:"P-A-R: Programmable Agent Runtime"
       ~man:[
         `S "DESCRIPTION";
         `P "P-A-R is a Programmable Agent Runtime for building AI agent systems.";
         `P "Use subcommands to interact with the runtime.";
       ])
    [
      v info_run term_run;
      v info_invoke term_invoke;
      cmd_task;
      cmd_workflow;
    ]

let () =
  exit (Cmdliner.Cmd.eval cmd)
