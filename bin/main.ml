open Par_core

(* -------------------------------------------------------------------------- *)
(* Shared CLI argument definitions                                            *)
(* -------------------------------------------------------------------------- *)

let persistence_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "persistence" ] ~docv:"BACKEND" ~doc:"Storage backend: sqlite|postgres (default: sqlite)")

let db_uri =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "db-uri" ] ~docv:"URI" ~doc:"PostgreSQL connection URI")

let provider_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "provider" ] ~docv:"PROVIDER" ~doc:"LLM provider: openai|anthropic (default: openai)")

let api_key_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "api-key" ] ~docv:"KEY" ~doc:"API key for LLM provider (overrides config)")

let api_base =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "api-base" ] ~docv:"URL" ~doc:"Custom API base URL (overrides config)")

let model_name =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "model" ] ~docv:"NAME" ~doc:"Model name (overrides config)")

let system_prompt =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "system-prompt" ] ~docv:"PROMPT" ~doc:"Agent system prompt (overrides config)")

let max_iterations =
  let open Cmdliner in
  Arg.(value & opt int 10 &
    info [ "max-iterations" ] ~docv:"N" ~doc:"Max ReAct iterations (default: 10)")

let temperature_arg =
  let open Cmdliner in
  Arg.(value & opt (some float) None &
    info [ "temperature" ] ~docv:"FLOAT" ~doc:"Temperature (overrides config)")

let question_arg =
  let open Cmdliner in
  Arg.(required & pos 0 (some string) None &
    info [] ~docv:"QUESTION" ~doc:"Question to ask")

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

let make_postgres_persistence conninfo =
  match Par_postgres.Postgres_persistence.create conninfo with
  | Error e ->
    Printf.eprintf "Error connecting to PostgreSQL: %s\n" (error_category_to_string e);
    exit 1
  | Ok t ->
    { Types.
      save_events_fn = (fun events -> Par_postgres.Postgres_persistence.save_events t events);
      load_events_fn = (fun task_id -> Par_postgres.Postgres_persistence.load_events t task_id);
      save_task_state_fn = (fun ts -> Par_postgres.Postgres_persistence.save_task_state t ts);
      load_task_state_fn = (fun task_id -> Par_postgres.Postgres_persistence.load_task_state t task_id);
      close_fn = (fun () -> Par_postgres.Postgres_persistence.close t);
    }

let make_persistence_service persistence _backend db_uri_val =
  match String.lowercase_ascii persistence with
  | "postgres" ->
    let conninfo = match db_uri_val with Some u -> u | None -> "postgresql://localhost/par" in
    make_postgres_persistence conninfo
  | _ ->
    let path = "par.db" in
    make_sqlite_persistence path

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

let builtin_tools ~switch ~net =
  let open Types in
  let token = Cancellation.create_token switch in

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

  let max_download_size = 10 * 1024 * 1024 in

  let default_headers = Http.Header.of_list [("user-agent", "P-A-R/0.1 (OCaml agent runtime)")] in

  let tls_config =
    lazy
      (let authenticator =
         match Ca_certs.authenticator () with
         | Ok auth -> auth
         | Error (`Msg msg) ->
           Printf.eprintf "Warning: failed to load system CA certs: %s, using no-auth\n" msg;
           (fun ?ip:_ ~host:_ _certs -> Ok None)
       in
       match Tls.Config.client ~authenticator () with
       | Ok cfg -> cfg
       | Result.Error (`Msg msg) -> failwith ("TLS configuration error: " ^ msg))
  in

  let tls_host_of_string host =
    match Domain_name.of_string host with
    | Error _ -> None
    | Ok dn -> (match Domain_name.host dn with Ok h -> Some h | Error _ -> None)
  in

  let https_fn uri flow =
    let cfg = Lazy.force tls_config in
    let host = Uri.host uri in
    (match host with
     | Some h ->
       (match tls_host_of_string h with
        | Some dh -> Tls_eio.client_of_flow cfg ~host:dh flow
        | None -> failwith ("Cannot parse hostname for TLS SNI: " ^ h))
     | None -> failwith "No host in URL for TLS connection")
  in

  let http_client = Cohttp_eio.Client.make ~https:(Some https_fn) net in

  let validate_url url =
    let uri = Uri.of_string url in
    match Uri.scheme uri with
    | Some ("http" | "https") -> Ok uri
    | Some s -> Error ("Unsupported URL scheme: " ^ s ^ ". Only http and https are allowed.")
    | None -> Error "URL must include a scheme (http:// or https://)"
  in

  let http_get url sw : ((int * string), string) result =
    match validate_url url with
    | Error msg -> Error msg
    | Ok uri ->
      (try
         let resp, body = Cohttp_eio.Client.get http_client ~sw ~headers:default_headers uri in
         let status = (resp.Http.Response.status :> Cohttp.Code.status_code) |> Cohttp.Code.code_of_status in
         let body_str =
           Eio.Buf_read.parse_exn ~max_size:max_download_size Eio.Buf_read.take_all body
         in
         Ok (status, body_str)
       with exn ->
         Error ("HTTP request failed: " ^ Printexc.to_string exn))
  in

  let fetch_url_tool =
    { name = "fetch_url"
    ; description = "Fetch the content of a URL and return the raw text. \
                     Input: {\"url\": \"https://example.com\", \"max_length\": 10000}"
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc
            [ ("url", `Assoc [("type", `String "string"); ("description", `String "URL to fetch")])
            ; ("max_length", `Assoc [("type", `String "integer"); ("description", `String "Max response length (default 50000)")])
            ])
        ; ("required", `List [`String "url"])
        ]
    ; handler = (fun input _tok ->
        let url = match Yojson.Safe.Util.(input |> member "url" |> to_string_option) with
          | Some u -> u | None -> ""
        in
        let max_len = match Yojson.Safe.Util.(input |> member "max_length" |> to_int_option) with
          | Some n -> max 100 (min n 500_000) | None -> 50000
        in
        if url = "" then
          Error { category = Invalid_input "Missing url parameter"; message = "Missing url"; retryable = false; metadata = [] }
        else
          Eio.Switch.run @@ fun sw ->
          (match http_get url sw with
           | Error msg ->
             Error { category = External_failure msg; message = msg; retryable = true; metadata = [] }
           | Ok (status, body) ->
             let truncated = String.length body > max_len in
             let result = if truncated then String.sub body 0 max_len else body in
             Success (`Assoc [
               ("url", `String url);
               ("status", `Int status);
               ("content", `String result);
                ("content_length", `Int (String.length result));
                 ("truncated", `Bool truncated);
               ]))
    )
    ; permission = Allow
    ; timeout = Some 15.0
    ; concurrency_limit = None
    }
  in

  let read_webpage_tool =
    { name = "read_webpage"
    ; description = "Fetch a URL, parse the HTML, and extract readable text content. \
                     Input: {\"url\": \"https://example.com\", \"max_length\": 10000}"
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc
            [ ("url", `Assoc [("type", `String "string"); ("description", `String "URL to fetch")])
            ; ("max_length", `Assoc [("type", `String "integer"); ("description", `String "Max text length (default 10000)")])
            ])
        ; ("required", `List [`String "url"])
        ]
    ; handler = (fun input _tok ->
        let url = match Yojson.Safe.Util.(input |> member "url" |> to_string_option) with
          | Some u -> u | None -> ""
        in
        let max_len = match Yojson.Safe.Util.(input |> member "max_length" |> to_int_option) with
          | Some n -> max 100 (min n 500_000) | None -> 10000
        in
        if url = "" then
          Error { category = Invalid_input "Missing url parameter"; message = "Missing url"; retryable = false; metadata = [] }
        else
          Eio.Switch.run @@ fun sw ->
          (match http_get url sw with
           | Error msg ->
             Error { category = External_failure msg; message = msg; retryable = true; metadata = [] }
           | Ok (status, html) ->
             if status < 200 || status >= 300 then
               Error { category = External_failure (Printf.sprintf "HTTP %d" status);
                       message = Printf.sprintf "HTTP %d fetching %s" status url;
                       retryable = (status >= 500 || status = 429); metadata = [] }
             else
               let soup = Soup.parse html in
               Soup.iter Soup.delete (Soup.select "script" soup);
               Soup.iter Soup.delete (Soup.select "style" soup);
               Soup.iter Soup.delete (Soup.select "noscript" soup);
               let title =
                 match Soup.select_one "title" soup with
                 | Some el -> (match Soup.leaf_text el with Some t -> t | None -> "")
                 | None -> ""
               in
               let text_parts = Soup.trimmed_texts soup in
               let full_text = String.concat " " text_parts in
               let truncated = String.length full_text > max_len in
               let result = if truncated then String.sub full_text 0 max_len else full_text in
               Success (`Assoc [
                 ("url", `String url);
                 ("title", `String title);
                 ("text", `String result);
                 ("text_length", `Int (String.length result));
                  ("truncated", `Bool truncated);
                 ]))
    )
    ; permission = Allow
    ; timeout = Some 15.0
    ; concurrency_limit = None
    }
  in

  let web_search_tool =
    { name = "web_search"
    ; description = "Search the web using DuckDuckGo and return results. \
                     Input: {\"query\": \"search terms\", \"max_results\": 5}"
    ; input_schema = `Assoc
        [ ("type", `String "object")
        ; ("properties", `Assoc
            [ ("query", `Assoc [("type", `String "string"); ("description", `String "Search query")])
            ; ("max_results", `Assoc [("type", `String "integer"); ("description", `String "Max number of results (default 5)")])
            ])
        ; ("required", `List [`String "query"])
        ]
    ; handler = (fun input _tok ->
        let query = match Yojson.Safe.Util.(input |> member "query" |> to_string_option) with
          | Some q -> q | None -> ""
        in
        let max_res = match Yojson.Safe.Util.(input |> member "max_results" |> to_int_option) with
          | Some n -> max 1 (min n 20) | None -> 5
        in
        if query = "" then
          Error { category = Invalid_input "Missing query parameter"; message = "Missing query"; retryable = false; metadata = [] }
        else
          Eio.Switch.run @@ fun sw ->
          let encoded_query = Uri.pct_encode query in
          let search_url = "https://lite.duckduckgo.com/lite?q=" ^ encoded_query in
          (match http_get search_url sw with
           | Error msg ->
             Error { category = External_failure msg; message = msg; retryable = true; metadata = [] }
           | Ok (_status, html) ->
             let soup = Soup.parse html in
             let results =
               let result_links = Soup.select "a.result-link" soup in
               let result_snippets = Soup.select "td.result-snippet" soup in
               let links =
                 Soup.fold (fun acc el ->
                   let title = match Soup.leaf_text el with Some t -> t | None -> "" in
                   let href = match Soup.attribute "href" el with Some h -> h | None -> "" in
                   (title, href) :: acc
                 ) [] result_links |> List.rev
               in
               let snippets =
                 Soup.fold (fun acc el ->
                   let text = String.concat " " (Soup.trimmed_texts el) in
                   text :: acc
                 ) [] result_snippets |> List.rev
               in
               let combine links snippets =
                 let rec go acc = function
                 | [], _ | _, [] -> List.rev acc
                 | (t, u) :: ls, s :: ss ->
                   go ((t, u, s) :: acc) (ls, ss)
                 in
                 go [] (links, snippets)
               in
               combine links snippets
             in
             let json_results =
               results
               |> List.filteri (fun i _ -> i < max_res)
               |> List.map (fun (title, url, snippet) ->
                 `Assoc [("title", `String title); ("url", `String url); ("snippet", `String snippet)])
             in
             Success (`Assoc [
               ("query", `String query);
               ("results", `List json_results);
                ("result_count", `Int (List.length json_results));
               ]))
    )
    ; permission = Allow
    ; timeout = Some 15.0
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
  ; fetch_url_tool
  ; read_webpage_tool
  ; web_search_tool
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

let print_json json =
  Printf.printf "%s\n" (Yojson.Safe.pretty_to_string ~std:true json)

(* -------------------------------------------------------------------------- *)
(* Config merge: CLI overrides on top of file config                          *)
(* -------------------------------------------------------------------------- *)

let merge_config
    (cfg : Par_config.config)
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt =
  { Par_config.
    provider = (match provider_opt with Some p -> p | None -> cfg.provider);
    api_key = (match api_key_opt with Some k -> k | None -> cfg.api_key);
    api_base = (match api_base_opt with Some b -> Some b | None -> cfg.api_base);
    model = (match model_opt with Some m -> m | None -> cfg.model);
    persistence = (match persistence_opt with Some p -> p | None -> cfg.persistence);
    db_uri = (match db_uri_opt with Some u -> Some u | None -> cfg.db_uri);
    temperature = (match temp_opt with Some t -> t | None -> cfg.temperature);
    system_prompt = (match prompt_opt with Some p -> p | None -> cfg.system_prompt);
  }

let require_config () =
  match Par_config.load () with
  | Some cfg -> cfg
  | None ->
    Printf.eprintf "未找到配置文件。请先运行 `par config` 进行配置。\n";
    exit 1

let ensure_rng () =
  Mirage_crypto_rng_unix.use_default ()

let setup_runtime cfg ~f =
  ensure_rng ();
  let pers = make_persistence_service cfg.Par_config.persistence
               (Par_config.resolve_persistence cfg) cfg.Par_config.db_uri in
  let persistence_config = Par_config.to_persistence_config cfg in
  let provider_tag = Par_config.to_provider_tag cfg in
  let config = make_runtime_config persistence_config in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun switch ->
  let net = Eio.Stdenv.net env in
  let llm = make_llm_service provider_tag cfg.Par_config.api_key cfg.Par_config.api_base net in
  match Runtime.create ~persistence:pers ~llm ~config switch with
  | Error e ->
    Printf.eprintf "Error creating runtime: %s\n" (error_category_to_string e);
    exit 1
  | Ok rt ->
    let tools = builtin_tools ~switch ~net in
    let agent = make_agent_config "default-agent" cfg.Par_config.system_prompt
                  provider_tag cfg.Par_config.model cfg.Par_config.temperature 10 tools in
    (match Runtime.register_agent rt agent with
     | Error e ->
       Printf.eprintf "Error registering agent: %s\n" (error_category_to_string e);
       exit 1
     | Ok () ->
       f rt;
       ignore (Runtime.close rt))

(* -------------------------------------------------------------------------- *)
(* REPL loop                                                                  *)
(* -------------------------------------------------------------------------- *)

let repl rt agent_id_val =
  Printf.printf "输入消息开始对话（Ctrl+D 退出）\n";
  let rec loop () =
    Printf.printf "> ";
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
     with End_of_file -> Printf.printf "\n再见！\n")
  in
  loop ()

(* -------------------------------------------------------------------------- *)
(* 'par' default command — REPL                                               *)
(* -------------------------------------------------------------------------- *)

let cmd_chat
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt _max_iter =
  let cfg = require_config () in
  let cfg = merge_config cfg provider_opt api_key_opt api_base_opt model_opt
              persistence_opt db_uri_opt temp_opt prompt_opt in
  setup_runtime cfg ~f:(fun rt -> repl rt "default-agent")

let term_chat =
  let open Cmdliner.Term in
  const cmd_chat
  $ provider_arg $ api_key_arg $ api_base $ model_name
  $ persistence_arg $ db_uri $ temperature_arg $ system_prompt $ max_iterations

(* -------------------------------------------------------------------------- *)
(* 'par config' command — interactive wizard                                  *)
(* -------------------------------------------------------------------------- *)

let cmd_config () =
  Par_config.run_wizard ()

let term_config =
  let open Cmdliner.Term in
  const (fun () -> cmd_config ()) $ const ()

let info_config = Cmdliner.Cmd.info "config"
  ~doc:"Configure provider and model settings"

(* -------------------------------------------------------------------------- *)
(* 'par ask' command — single-shot Q&A                                        *)
(* -------------------------------------------------------------------------- *)

let cmd_ask
    question
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt _max_iter =
  let cfg = require_config () in
  let cfg = merge_config cfg provider_opt api_key_opt api_base_opt model_opt
              persistence_opt db_uri_opt temp_opt prompt_opt in
  setup_runtime cfg ~f:(fun rt ->
    match Runtime.invoke rt ~agent_id:"default-agent" ~message:question () with
    | Error e ->
      Printf.eprintf "Error: %s\n" (error_category_to_string e);
      exit 1
    | Ok resp ->
      (match resp.Types.text with
       | Some txt -> Printf.printf "%s\n" txt
       | None -> print_json (Types.llm_response_to_yojson resp));
      flush stdout)

let term_ask =
  let open Cmdliner.Term in
  const cmd_ask
  $ question_arg
  $ provider_arg $ api_key_arg $ api_base $ model_name
  $ persistence_arg $ db_uri $ temperature_arg $ system_prompt $ max_iterations

let info_ask = Cmdliner.Cmd.info "ask"
  ~doc:"Ask a single question and print the answer"

(* -------------------------------------------------------------------------- *)
(* Root command                                                               *)
(* -------------------------------------------------------------------------- *)

let cmd =
  let open Cmdliner.Cmd in
  group ~default:term_chat
    (info "par" ~version:"0.1.0"
       ~doc:"P-A-R: Programmable Agent Runtime"
       ~man:[
         `S "DESCRIPTION";
         `P "P-A-R is a Programmable Agent Runtime for building AI agent systems.";
         `P "Run 'par' to start a REPL, 'par config' to configure, or 'par ask \"question\"' for one-shot.";
       ])
    [
      v info_config term_config;
      v info_ask term_ask;
    ]

let () =
  exit (Cmdliner.Cmd.eval cmd)
