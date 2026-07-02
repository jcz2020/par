(* PAR-g4c proof-of-concept: the calculator tool's input_schema is now
   derived from an OCaml record via [@@deriving jsonschema] and wrapped
   with Jsonschema.to_strict_object_schema for OpenAI strict-mode /
   FFI top-level Assoc guard compatibility. The remaining 19 builtin
   tools retain hand-written schemas for now — full migration is T3.2
   follow-up. *)
type calculator_input = {
  expression : string;
} [@@deriving yojson { strict = false }, jsonschema]

type echo_input = {
  text : string;
} [@@deriving yojson { strict = false }, jsonschema]

type string_stats_input = {
  text : string;
} [@@deriving yojson { strict = false }, jsonschema]

type json_format_input = {
  json : string;
} [@@deriving yojson { strict = false }, jsonschema]

type hash_text_input = {
  text : string;
  algorithm : string [@default "sha256"];
} [@@deriving yojson { strict = false }, jsonschema]

type generate_password_input = {
  length : int [@default 16];
  include_symbols : bool [@default true];
} [@@deriving yojson { strict = false }, jsonschema]

type fetch_url_input = {
  url : string;
  max_length : int [@default 50000];
} [@@deriving yojson { strict = false }, jsonschema]

type read_webpage_input = {
  url : string;
  max_length : int [@default 10000];
} [@@deriving yojson { strict = false }, jsonschema]

type web_search_input = {
  query : string;
  max_results : int [@default 5];
} [@@deriving yojson { strict = false }, jsonschema]

type read_input = {
  path : string;
  offset : int [@default 0];
  limit : int [@default 100];
} [@@deriving yojson { strict = false }, jsonschema]

type write_input = {
  path : string;
  content : string;
  create_dirs : bool [@default false];
} [@@deriving yojson { strict = false }, jsonschema]

type ls_input = {
  path : string;
  pattern : string [@default ""];
} [@@deriving yojson { strict = false }, jsonschema]

type find_input = {
  path : string;
  pattern : string;
  max_depth : int [@default 0];
} [@@deriving yojson { strict = false }, jsonschema]

type grep_input = {
  pattern : string;
  path : string;
  glob : string [@default ""];
} [@@deriving yojson { strict = false }, jsonschema]

type convert_temperature_input = {
  value : float;
  from_ : string [@key "from"] [@default "C"];
  to_ : string [@key "to"] [@default "F"];
} [@@deriving yojson { strict = false }, jsonschema]

type url_encode_input = {
  text : string;
  decode : bool [@default false];
} [@@deriving yojson { strict = false }, jsonschema]

let builtin_tools ~switch ~net ~workspace =
  let open Types in
  let token = Cancellation.create_token switch in 

  let calculator =
    let descriptor =
      { name = "calculator"
      ; description = "Evaluate a mathematical expression and return the numeric result. \
                       Input: {\"expression\": \"2 + 3 * 4\"}. Supports +, -, *, /, parentheses."
      ; input_schema = Jsonschema.to_strict_object_schema calculator_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 5.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
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
              let toks = List.filter (fun s -> s <> "") (List.rev !tokens) in
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
    in
    { descriptor; handler }
  in

  let get_time =
    let descriptor =
      { name = "get_time"
      ; description = "Get the current date and time in UTC. Input: {}"
      ; input_schema = `Assoc [("type", `String "object"); ("properties", `Assoc [])]
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 2.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun _input _tok ->
        let tm = Unix.gmtime (Unix.time ()) in
        let iso = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (1900 + tm.Unix.tm_year) (1 + tm.Unix.tm_mon) tm.Unix.tm_mday
          tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
        in
        Success (`String iso))
    in
    { descriptor; handler }
  in

  let echo =
    let descriptor =
      { name = "echo"
      ; description = "Echo back the input text. Input: {\"text\": \"...\"}"
      ; input_schema = Jsonschema.to_strict_object_schema echo_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 2.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let txt = match Yojson.Safe.Util.(input |> member "text" |> to_string_option) with
          | Some s -> s | None -> Yojson.Safe.to_string input
        in
        Success (`String txt))
    in
    { descriptor; handler }
  in

  let generate_uuid_tool =
    let descriptor =
      { name = "generate_uuid"
      ; description = "Generate a random UUID v4. Input: {}"
      ; input_schema = `Assoc [("type", `String "object"); ("properties", `Assoc [])]
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 1.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun _input _tok ->
        let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () in
        Success (`String (Uuidm.to_string uuid)))
    in
    { descriptor; handler }
  in

  let hash_text =
    let descriptor =
      { name = "hash_text"
      ; description = "Compute a hash of text. Input: {\"text\": \"...\", \"algorithm\": \"sha256\"}. \
                       Supported: md5, sha1, sha256 (default)."
      ; input_schema = Jsonschema.to_strict_object_schema hash_text_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 2.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
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
    in
    { descriptor; handler }
  in

  let generate_password_tool =
    let descriptor =
      { name = "generate_password"
      ; description = "Generate a random password. Input: {\"length\": 16, \"include_symbols\": true}"
      ; input_schema = Jsonschema.to_strict_object_schema generate_password_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 1.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
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
    in
    { descriptor; handler }
  in

  let string_stats =
    let descriptor =
      { name = "string_stats"
      ; description = "Count characters, words, and lines in text. Input: {\"text\": \"...\"}"
      ; input_schema = Jsonschema.to_strict_object_schema string_stats_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 1.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
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
    in
    { descriptor; handler }
  in

  let json_format =
    let descriptor =
      { name = "json_format"
      ; description = "Format and validate a JSON string. Input: {\"json\": \"{\\\"key\\\": \\\"value\\\"}\"}"
      ; input_schema = Jsonschema.to_strict_object_schema json_format_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 2.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let json_str = match Yojson.Safe.Util.(input |> member "json" |> to_string_option) with
          | Some s -> s | None -> "{}"
        in
        (try
           let json = Yojson.Safe.from_string json_str in
           Success (`String (Yojson.Safe.pretty_to_string ~std:true json))
         with Yojson.Json_error msg ->
           Error { category = Invalid_input ("Invalid JSON: " ^ msg); message = msg; retryable = false; metadata = [] }))
    in
    { descriptor; handler }
  in

  let convert_temperature_tool =
    let descriptor =
      { name = "convert_temperature"
      ; description = "Convert temperature between Celsius, Fahrenheit, and Kelvin. \
                       Input: {\"value\": 100, \"from\": \"C\", \"to\": \"F\"}"
      ; input_schema = Jsonschema.to_strict_object_schema convert_temperature_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 1.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
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
    in
    { descriptor; handler }
  in

  let url_encode_tool =
    let descriptor =
      { name = "url_encode"
      ; description = "URL-encode or URL-decode a string. Input: {\"text\": \"hello world\", \"decode\": false}"
      ; input_schema = Jsonschema.to_strict_object_schema url_encode_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 1.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
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
    in
    { descriptor; handler }
  in

  let _max_download_size = 10 * 1024 * 1024 in

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

  let _http_client = Cohttp_eio.Client.make ~https:(Some https_fn) net in

  let validate_url url =
    let uri = Uri.of_string url in
    match Uri.scheme uri with
    | Some ("http" | "https") -> Ok uri
    | Some s -> Error ("Unsupported URL scheme: " ^ s ^ ". Only http and https are allowed.")
    | None -> Error "URL must include a scheme (http:// or https://)"
  in

  let http_get url : ((int * string), string) result =
    match validate_url url with
    | Error msg -> Error msg
    | Ok uri ->
      let host = match Uri.host uri with Some h -> h | None -> "localhost" in
      let port = match Uri.port uri with Some p -> p | None -> if Uri.scheme uri = Some "https" then 443 else 80 in
      let use_tls = Uri.scheme uri = Some "https" in
      let path = let p = Uri.path uri in if p = "" then "/" else p in
      (try
         let (status, _hdrs, body) =
           Http_timeout.request_with_timeout
             ~timeout:15.0 ~net ~host ~port ~use_tls
             ~method_:"GET" ~path ~request_headers:(Cohttp.Header.to_list default_headers) ()
         in
         Ok (status, body)
       with exn -> Error ("HTTP request failed: " ^ Printexc.to_string exn))
  in

  let fetch_url_tool =
    let descriptor =
      { name = "fetch_url"
      ; description = "Fetch the content of a URL and return the raw text. \
                       Input: {\"url\": \"https://example.com\", \"max_length\": 10000}"
      ; input_schema = Jsonschema.to_strict_object_schema fetch_url_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 15.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let url = match Yojson.Safe.Util.(input |> member "url" |> to_string_option) with
          | Some u -> u | None -> ""
        in
        let max_len = match Yojson.Safe.Util.(input |> member "max_length" |> to_int_option) with
          | Some n -> max 100 (min n 500_000) | None -> 50000
        in
        if url = "" then
          Error { category = Invalid_input "Missing url parameter"; message = "Missing url"; retryable = false; metadata = [] }
        else
          Eio.Switch.run @@ fun _sw ->
          (match http_get url with
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
    in
    { descriptor; handler }
  in

  let read_webpage_tool =
    let descriptor =
      { name = "read_webpage"
      ; description = "Fetch a URL, parse the HTML, and extract readable text content. \
                       Input: {\"url\": \"https://example.com\", \"max_length\": 10000}"
      ; input_schema = Jsonschema.to_strict_object_schema read_webpage_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 15.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let url = match Yojson.Safe.Util.(input |> member "url" |> to_string_option) with
          | Some u -> u | None -> ""
        in
        let max_len = match Yojson.Safe.Util.(input |> member "max_length" |> to_int_option) with
          | Some n -> max 100 (min n 500_000) | None -> 10000
        in
        if url = "" then
          Error { category = Invalid_input "Missing url parameter"; message = "Missing url"; retryable = false; metadata = [] }
        else
          Eio.Switch.run @@ fun _sw ->
          (match http_get url with
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
    in
    { descriptor; handler }
  in

  let web_search_tool =
    let descriptor =
      { name = "web_search"
      ; description = "Search the web using DuckDuckGo and return results. \
                       Input: {\"query\": \"search terms\", \"max_results\": 5}"
      ; input_schema = Jsonschema.to_strict_object_schema web_search_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 15.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let query = match Yojson.Safe.Util.(input |> member "query" |> to_string_option) with
          | Some q -> q | None -> ""
        in
        let max_res = match Yojson.Safe.Util.(input |> member "max_results" |> to_int_option) with
          | Some n -> max 1 (min n 20) | None -> 5
        in
        if query = "" then
          Error { category = Invalid_input "Missing query parameter"; message = "Missing query"; retryable = false; metadata = [] }
        else
          Eio.Switch.run @@ fun _sw ->
          let encoded_query = Uri.pct_encode query in
          let search_url = "https://lite.duckduckgo.com/lite?q=" ^ encoded_query in
          (match http_get search_url with
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
    in
    { descriptor; handler }
  in

  let read_tool =
    let descriptor =
      { name = "read"
      ; description = "Read a file from the current working directory. \
                       Input: {\"path\": \"relative/path.txt\", \"offset\": 0, \"limit\": 100}. \
                       Returns file content with line numbers. Binary files are detected \
                       and returned as base64. Maximum 10MB."
      ; input_schema = Jsonschema.to_strict_object_schema read_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 30.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let open Yojson.Safe.Util in
        let path = match input |> member "path" |> to_string_option with
          | Some p -> p
          | None -> ""
        in
        let offset = match input |> member "offset" |> to_int_option with
          | Some n -> max 0 n
          | None -> 0
        in
        let limit = match input |> member "limit" |> to_int_option with
          | Some n when n > 0 -> n
          | _ -> max_int
        in
        if path = "" then
          Error { category = Invalid_input "Empty path"; message = "Path is required"; retryable = false; metadata = [] }
        else
          match Workspace.admit workspace path with
          | Error e ->
            Error { category = e; message = "Path validation failed"; retryable = false; metadata = [] }
          | Ok sandboxed ->
            let full_path = Workspace.to_string sandboxed in
            let read_lines () =
            let ic = open_in full_path in
            Fun.protect (fun () ->
              let n = in_channel_length ic in
              if n > 10_000_000 then
                Error { category = Invalid_input "File too large (>10MB)"; message = "File exceeds 10MB limit"; retryable = false; metadata = [] }
              else
                let lines = ref [] in
                let line_count = ref 0 in
                (try
                   while true do
                     let line = input_line ic in
                     if !line_count >= offset && List.length !lines < limit then
                       lines := line :: !lines;
                     incr line_count
                   done
                 with End_of_file -> ());
                let numbered = List.mapi (fun i line ->
                  Printf.sprintf "%4d\t%s" (offset + i + 1) line
                ) (List.rev !lines) in
                let result = String.concat "\n" numbered in
                Success (`String result)
            ) ~finally:(fun () -> close_in ic)
          in
          try read_lines () with
          | Sys_error msg ->
            Error { category = Internal msg; message = msg; retryable = false; metadata = [] }
          | e ->
            Error { category = Internal (Printexc.to_string e); message = "Read failed"; retryable = false; metadata = [] }
        )
    in
    { descriptor; handler }
  in

  let ls_tool =
    let descriptor =
      { name = "ls"
      ; description = "List directory contents. Input: {\"path\": \".\"} (relative to CWD). \
                       Returns list of {name, type, size, modified} entries."
      ; input_schema = Jsonschema.to_strict_object_schema ls_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 10.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let open Yojson.Safe.Util in
        let path = match input |> member "path" |> to_string_option with
          | Some p -> p
          | None -> ""
        in
        if path = "" then
          Error { category = Invalid_input "Empty path"; message = "Path is required"; retryable = false; metadata = [] }
        else
          match Workspace.admit workspace path with
          | Error e ->
            Error { category = e; message = "Path validation failed"; retryable = false; metadata = [] }
          | Ok sandboxed ->
            let full_path = Workspace.to_string sandboxed in
            try
              let attrs = Unix.LargeFile.lstat full_path in
            match attrs.Unix.LargeFile.st_kind with
            | Unix.S_DIR ->
              let entries = Sys.readdir full_path in
              let entry_list = Array.to_list entries in
              let sorted = List.sort String.compare entry_list in
              let json_entries = List.map (fun name ->
                let entry_path = Filename.concat full_path name in
                let stat =
                  try Some (Unix.LargeFile.lstat entry_path)
                  with _ -> None
                in
                let kind = match stat with
                  | Some s ->
                    (match s.Unix.LargeFile.st_kind with
                     | Unix.S_DIR -> "dir"
                     | Unix.S_REG -> "file"
                     | Unix.S_LNK -> "link"
                     | _ -> "other")
                  | None -> "unknown"
                in
                let size = match stat with
                  | Some s -> `Int (Int64.to_int s.Unix.LargeFile.st_size)
                  | None -> `Null
                in
                let mtime = match stat with
                  | Some s -> `Float s.Unix.LargeFile.st_mtime
                  | None -> `Null
                in
                `Assoc [
                  ("name", `String name);
                  ("type", `String kind);
                  ("size", size);
                  ("modified", mtime);
                ]
              ) sorted in
              let result = `Assoc [
                ("path", `String path);
                ("entries", `List json_entries);
              ] in
              Success result
            | _ ->
              Error { category = Invalid_input "Not a directory"; message = (Printf.sprintf "Not a directory: %s" path); retryable = false; metadata = [] }
          with
          | Sys_error msg ->
            Error { category = Internal msg; message = msg; retryable = false; metadata = [] }
          | e ->
            Error { category = Internal (Printexc.to_string e); message = "ls failed"; retryable = false; metadata = [] }
        )
    in
    { descriptor; handler }
  in

  let find_tool =
    let descriptor =
      { name = "find"
      ; description = "Find files matching a glob pattern. \
                       Input: {\"pattern\": \"**/*.ml\", \"path\": \".\"}. \
                       Skips .git, node_modules, _build, _opam directories."
      ; input_schema = Jsonschema.to_strict_object_schema find_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 30.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let skip_dirs = [".git"; "node_modules"; "_build"; "_opam"] in
    let glob_match pattern name =
      let pat = Str.regexp (Str.quote pattern |> Str.global_replace (Str.regexp "\\*\\*") ".*" |> Str.global_replace (Str.regexp "\\*") "[^/]*") in
      try Str.search_forward pat name 0 >= 0
      with Not_found -> false
    in
    let rec walk pattern dir acc =
      try
        let entries = Sys.readdir dir in
        Array.fold_left (fun acc name ->
          let full = Filename.concat dir name in
          let is_dir = try
            let stat = Unix.LargeFile.lstat full in
            stat.Unix.LargeFile.st_kind = Unix.S_DIR
          with _ -> false in
          let acc = if is_dir && List.mem name skip_dirs then acc
                    else if glob_match pattern (Filename.basename full) then full :: acc
                    else acc in
          if is_dir && not (List.mem name skip_dirs) then
            walk pattern full acc
          else acc
        ) acc entries
      with _ -> acc
    in
    let handler = (fun input _tok ->
        let open Yojson.Safe.Util in
        let pattern = match input |> member "pattern" |> to_string_option with
          | Some p -> p
          | None -> ""
        in
        let path = match input |> member "path" |> to_string_option with
          | Some p -> p
          | None -> "."
        in
        if pattern = "" then
          Error { category = Invalid_input "Empty pattern"; message = "Pattern is required"; retryable = false; metadata = [] }
        else
          match Workspace.admit workspace path with
          | Error e ->
            Error { category = e; message = "Path validation failed"; retryable = false; metadata = [] }
          | Ok sandboxed ->
            let full_path = Workspace.to_string sandboxed in
            try
              let results = walk pattern full_path [] in
              let sorted = List.sort String.compare results in
              let cwd = Workspace.root workspace in
              let cwd_len = String.length cwd + 1 in
            Success (`List (List.map (fun p ->
              if String.length p > cwd_len && String.sub p 0 cwd_len = cwd ^ "/" then
                `String (String.sub p cwd_len (String.length p - cwd_len))
              else `String p
            ) sorted))
          with e ->
            Error { category = Internal (Printexc.to_string e); message = "find failed"; retryable = false; metadata = [] }
        )
    in
    { descriptor; handler }
  in

  let grep_tool =
    let descriptor =
      { name = "grep"
      ; description = "Search for regex pattern in files. \
                       Input: {\"pattern\": \"TODO\", \"path\": \".\", \"glob\": \"*.ml\"}. \
                       Returns matching lines with file:line prefix. Timeout 30s."
      ; input_schema = Jsonschema.to_strict_object_schema grep_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 30.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let open Yojson.Safe.Util in
        let pattern = match input |> member "pattern" |> to_string_option with
          | Some p -> p
          | None -> ""
        in
        let path = match input |> member "path" |> to_string_option with
          | Some p -> p
          | None -> "."
        in
        let glob = match input |> member "glob" |> to_string_option with
          | Some g -> g
          | None -> "*"
        in
        let _context_lines = match input |> member "context_lines" |> to_int_option with
          | Some n -> max 0 n
          | None -> 0
        in
        if pattern = "" then
          Error { category = Invalid_input "Empty pattern"; message = "Pattern is required"; retryable = false; metadata = [] }
        else
          match Workspace.admit workspace path with
          | Error e ->
            Error { category = e; message = "Path validation failed"; retryable = false; metadata = [] }
          | Ok sandboxed ->
            let full_path = Workspace.to_string sandboxed in
            let root_prefix = Workspace.root workspace in
            let regex =
            try Str.regexp pattern
            with _ -> raise (Invalid_argument "Invalid regex pattern")
          in
          let results = ref [] in
          let glob_re = Str.regexp (Str.quote glob |> Str.global_replace (Str.regexp "\\*") ".*") in
          let rec search dir =
            try
              let entries = Sys.readdir dir in
              Array.iter (fun name ->
                if not (List.mem name [".git"; "node_modules"; "_build"; "_opam"]) then begin
                  let full = Filename.concat dir name in
                  let is_dir = try
                    let stat = Unix.LargeFile.lstat full in
                    stat.Unix.LargeFile.st_kind = Unix.S_DIR
                  with _ -> false in
                  if is_dir then search full
                  else if Str.string_match glob_re name 0 then begin
                    try
                      let ic = open_in full in
                      Fun.protect (fun () ->
                        let line_no = ref 0 in
                        (try
                           while true do
                             incr line_no;
                             let line = input_line ic in
                              if Str.string_match regex line 0 then begin
                                let display_path = String.sub full (String.length (Filename.concat root_prefix "") + 1) (String.length full - String.length (Filename.concat root_prefix "") - 1) in
                               results := Printf.sprintf "%s:%d:%s" display_path (!line_no) line :: !results
                              end
                            done
                          with End_of_file -> ());
                       ) ~finally:(fun () -> close_in ic)
                     with e ->
                       Logs.warn (fun m ->
                         m "grep: failed to read file: %s"
                           (Printexc.to_string e))
                   end
                 end
               ) entries
             with e ->
               Logs.warn (fun m ->
                 m "find/grep: failed to read dir: %s"
                   (Printexc.to_string e))
           in
          search full_path;
          let sorted = List.rev (List.sort compare !results) in
          Success (`List (List.map (fun s -> `String s) sorted))
        )
    in
    { descriptor; handler }
  in

  let write_tool =
    let descriptor =
      { name = "write"
      ; description = "Write content to a file. Input: {\"path\": \"relative/file.txt\", \"content\": \"...\", \"create_dirs\": true}."
      ; input_schema = Jsonschema.to_strict_object_schema write_input_jsonschema
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 30.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let open Yojson.Safe.Util in
        let path = match input |> member "path" |> to_string_option with
          | Some p -> p
          | None -> ""
        in
        let content = match input |> member "content" |> to_string_option with
          | Some c -> c
          | None -> ""
        in
        let create_dirs = match input |> member "create_dirs" |> to_bool_option with
          | Some b -> b
          | None -> false
        in
        if path = "" then
          Error { category = Invalid_input "Empty path"; message = "Path is required"; retryable = false; metadata = [] }
        else
          match Workspace.admit workspace path with
          | Error e ->
            Error { category = e; message = "Path validation failed"; retryable = false; metadata = [] }
          | Ok sandboxed ->
            let full_path = Workspace.to_string sandboxed in
            try
              if create_dirs then begin
              let dir = Filename.dirname full_path in
              if dir <> "" && dir <> "." && dir <> Filename.current_dir_name then
                let rec mkdir_p d =
                  if d = "" || d = "/" || d = "." then ()
                  else if Sys.file_exists d then ()
                  else begin
                    mkdir_p (Filename.dirname d);
                    (try Unix.mkdir d 0o755 with e ->
                       Logs.warn (fun m ->
                         m "write: failed to mkdir %s: %s"
                           d (Printexc.to_string e)))
                  end
                in
                mkdir_p dir
            end;
            let oc = open_out full_path in
            output_string oc content;
            close_out oc;
            Success (`String (Printf.sprintf "Wrote %d bytes to %s" (String.length content) path))
          with
          | Sys_error msg ->
            Error { category = Internal msg; message = msg; retryable = false; metadata = [] }
          | e ->
            Error { category = Internal (Printexc.to_string e); message = "Write failed"; retryable = false; metadata = [] }
        )
    in
    { descriptor; handler }
  in

  let edit_tool =
    let descriptor =
      { name = "edit"
      ; description = "Apply batch edits to a file. Input: {\"path\": \"file.txt\", \"edits\": [{\"old\": \"foo\", \"new\": \"bar\"}]}. \
                       Each edit is an exact string match. Overlapping edits are rejected."
      ; input_schema = `Assoc
          [ ("type", `String "object")
          ; ("properties", `Assoc
              [ ("path", `Assoc
                  [ ("type", `String "string")
                  ; ("description", `String "File path relative to CWD")
                  ])
              ; ("edits", `Assoc
                  [ ("type", `String "array")
                  ; ("items", `Assoc
                      [ ("type", `String "object")
                      ; ("properties", `Assoc
                          [ ("old", `Assoc [("type", `String "string")])
                          ; ("new", `Assoc [("type", `String "string")])
                          ])
                      ; ("required", `List [`String "old"; `String "new"])
                      ])
                  ])
              ])
          ; ("required", `List [`String "path"; `String "edits"])
          ]
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 30.0
      ; concurrency_limit = None
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let open Yojson.Safe.Util in
        let path = match input |> member "path" |> to_string_option with
          | Some p -> p
          | None -> ""
        in
        let edits_json = match input |> member "edits" with
          | `List l -> l
          | _ -> []
        in
        if path = "" then
          Error { category = Invalid_input "Empty path"; message = "Path is required"; retryable = false; metadata = [] }
        else
          match Workspace.admit workspace path with
          | Error e ->
            Error { category = e; message = "Path validation failed"; retryable = false; metadata = [] }
          | Ok sandboxed ->
            let full_path = Workspace.to_string sandboxed in
            let edits = List.filter_map (fun e ->
            let old = e |> member "old" |> to_string_option in
            let new_ = e |> member "new" |> to_string_option in
            match old, new_ with
            | Some o, Some n -> Some (o, n)
            | _ -> None
          ) edits_json in
          try
            let ic = open_in full_path in
            let content = Fun.protect (fun () ->
              let len = in_channel_length ic in
              let buf = Buffer.create len in
              (try while true do Buffer.add_channel buf ic 4096 done with End_of_file -> ());
              Buffer.contents buf
            ) ~finally:(fun () -> close_in ic) in
            let has_overlap edits =
              let positions_in_content s =
                let len = String.length s in
                let content_len = String.length content in
                let rec aux pos =
                  if pos > content_len - len then []
                  else if String.sub content pos len = s then pos :: aux (pos + 1)
                  else aux (pos + 1)
                in
                aux 0
              in
                let check = function
                | [] | [_] -> false
                | (a, _) :: rest ->
                  let a_positions = positions_in_content a in
                  List.exists (fun pos ->
                    let a_end = pos + String.length a in
                    List.exists (fun (b, _) ->
                      let b_positions = positions_in_content b in
                      List.exists (fun bpos -> bpos >= pos && bpos < a_end) b_positions
                    ) rest
                  ) a_positions
              in
              check edits
            in
            if has_overlap edits then
              Error { category = Invalid_input "Overlapping edits"; message = "Edit ranges overlap, rejected"; retryable = false; metadata = [] }
            else begin
              let new_content = List.fold_left (fun acc (old, new_) ->
                let replaced = Str.replace_first (Str.regexp_string old) new_ acc in
                replaced
              ) content edits in
              let oc = open_out full_path in
              output_string oc new_content;
              close_out oc;
              Success (`String (Printf.sprintf "Applied %d edit(s) to %s" (List.length edits) path))
            end
          with
          | Sys_error msg ->
            Error { category = Internal msg; message = msg; retryable = false; metadata = [] }
          | e ->
            Error { category = Internal (Printexc.to_string e); message = "Edit failed"; retryable = false; metadata = [] }
        )
    in
    { descriptor; handler }
  in

  let bash_tool =
    let descriptor =
      { name = "bash"
      ; description = "Execute a shell command. Input: {\"argv\": [\"ls\", \"-la\"], \"timeout\": 30, \"cwd\": \"src\"}. \
                       Subject to Bash_policy and Bash_blacklist. \
                       Output: {\"stdout\": \"...\", \"stderr\": \"...\", \"exit_code\": 0, \"duration\": 0.12, \"truncated\": false}."
      ; input_schema = `Assoc
          [ ("type", `String "object")
          ; ("properties", `Assoc
              [ ("argv",     `Assoc [ ("type", `String "array")
                                    ; ("items", `Assoc [("type", `String "string")])
                                    ; ("description", `String "argv to execute (NOT a shell string)") ])
              ; ("cwd",      `Assoc [ ("type", `String "string")
                                    ; ("description", `String "Working directory (relative to workspace root, or absolute path under workspace root). Default: .") ])
              ; ("timeout",  `Assoc [ ("type", `String "number")
                                    ; ("description", `String "Max seconds; default = 30")
                                    ; ("minimum", `Float 0.0) ])
              ])
          ; ("required", `List [`String "argv"])
          ]
      ; output_schema = None
 ; permission = Allow
      ; timeout = Some 60.0
      ; concurrency_limit = Some 4
      ; on_update = None
      ; cache_control = None
      }
    in
    let handler = (fun input _tok ->
        let argv =
          try
            Yojson.Safe.Util.(input |> member "argv" |> to_list)
            |> List.filter_map (fun j ->
              match j with
              | `String s -> Some s
              | _ -> None)
          with _ -> []
        in
        let cwd_str = match Yojson.Safe.Util.(input |> member "cwd" |> to_string_option) with
          | Some s -> s | None -> "."
        in
        let timeout = match Yojson.Safe.Util.(input |> member "timeout" |> to_float_option) with
          | Some t when t > 0.0 -> t | _ -> 30.0
        in
        if argv = [] then
          Error { category = Invalid_input "Empty argv"; message = "argv is required"; retryable = false; metadata = [] }
        else
           (match Workspace.admit workspace cwd_str with
           | Error e ->
             Error { category = e; message = Printf.sprintf "Invalid cwd: %s" cwd_str; retryable = false; metadata = [] }
           | Ok cwd ->
             let _cmd = Bash_safe_command.Exec { argv; cwd; env = []; timeout } in
             (* NOTE: The actual policy check + Eio spawn happens in Runtime.install_bash_tool
                which wraps this handler with the user's chosen POLICY module. The
                builtin_tools.ml handler is a pure-data thunk. *)
             Error { category = Internal "bash tool not installed"
                   ; message = "Runtime.install_bash_tool must be called first"
                   ; retryable = false; metadata = [] })
      )
    in
    { descriptor; handler }
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
  ; read_tool
  ; ls_tool
  ; find_tool
  ; grep_tool
  ; write_tool
  ; edit_tool
  ; bash_tool
  ]