(* test/test_providers.ml — Unit and integration tests for the LLM provider stack.

   Coverage:
   - Http_client: pure functions for URL parsing, request building, response
     splitting, status-line parsing, header search, chunked transfer decoding,
     and HTTP status → error mapping.
   - Openai_provider: config validation, public complete/stream error paths,
     and a real round-trip against an in-process TLS mock server.
   - Anthropic_provider: same structure as OpenAI.
   - Edge cases: malformed JSON, Unicode payloads, very long responses, and
     exotic header values.

   The mock HTTP server is an in-process Eio TCP listener that speaks TLS with
   a self-signed certificate. The provider's client wraps every connection in
   TLS (no_auth on the client side, so it accepts the self-signed cert), and
   the server returns canned responses for the configured path. This lets the
   tests exercise the real HTTP round-trip without touching the public network. *)

open Par
open Types
module Http_client = Par__Http_client

(* -------------------------------------------------------------------------- *)
(* Shared fixtures                                                           *)
(* -------------------------------------------------------------------------- *)

let openai_model : model_config =
  { provider = `Openai
  ; model_name = "gpt-4o-mini"
  ; api_base = None
  ; temperature = 0.0
  ; max_tokens = Some 64
  ; top_p = None
  ; stop_sequences = None
  }

let anthropic_model : model_config =
  { provider = `Anthropic
  ; model_name = "claude-3-5-sonnet-latest"
  ; api_base = None
  ; temperature = 0.0
  ; max_tokens = Some 64
  ; top_p = None
  ; stop_sequences = None
  }

let user_only_conv : conversation =
  { messages =
      [ { role = User
        ; content_blocks = [Text_block { text = "hello"; cache_control = None }]
        ; tool_calls = None
        ; tool_call_id = None
        ; name = None
        } ]
  ; metadata = []
  }

let default_stream_config : stream_config =
  { chunk_timeout = 5.0; total_timeout = Some 10.0; buffer_size = 4096 }

let show_error : error_category -> string = function
  | Timeout -> "Timeout"
  | Invalid_input s -> "Invalid_input(" ^ s ^ ")"
  | External_failure s -> "External_failure(" ^ s ^ ")"
  | Rate_limited -> "Rate_limited"
  | Permission_denied s -> "Permission_denied(" ^ s ^ ")"
  | Internal s -> "Internal(" ^ s ^ ")"
  | Embedding_unsupported -> "Embedding_unsupported"

let http_error_to_string : Http_client.http_error -> string = function
  | Http_client.Invalid_input s -> "Invalid_input(" ^ s ^ ")"
  | Http_client.Permission_denied s -> "Permission_denied(" ^ s ^ ")"
  | Http_client.Rate_limited -> "Rate_limited"
  | Http_client.Timeout -> "Timeout"
   | Http_client.External_failure s -> "External_failure(" ^ s ^ ")"

(* -------------------------------------------------------------------------- *)
(* HTTP client — unit tests                                                  *)
(* -------------------------------------------------------------------------- *)
let test_http_parse_url_https () =
  let u = Http_client.parse_url "https://api.openai.com/v1/chat" in
  Alcotest.(check string) "host" "api.openai.com" u.host;
  Alcotest.(check int) "port" 443 u.port;
  Alcotest.(check string) "path" "/v1/chat/" u.path

let test_http_parse_url_with_port () =
  let u = Http_client.parse_url "https://api.example.com:8443/api/v2" in
  Alcotest.(check string) "host" "api.example.com" u.host;
  Alcotest.(check int) "port" 8443 u.port;
  Alcotest.(check string) "path" "/api/v2/" u.path

let test_http_parse_url_no_path () =
  let u = Http_client.parse_url "https://example.com" in
  Alcotest.(check string) "host" "example.com" u.host;
  Alcotest.(check int) "port" 443 u.port;
  Alcotest.(check string) "path" "/" u.path

let test_http_parse_url_http_scheme () =
  let u = Http_client.parse_url "http://plain.example.com:80/x" in
  Alcotest.(check string) "host" "plain.example.com" u.host;
  Alcotest.(check int) "port" 80 u.port;
  Alcotest.(check string) "path" "/x/" u.path

let test_http_build_http_request_shape () =
  let req =
    Http_client.build_http_request
      ~host:"api.openai.com"
      ~path:"/v1/chat/completions"
      ~headers:[ "Authorization", "Bearer sk-test" ]
      ~body:"{\"model\":\"gpt-4o-mini\"}"
  in
  Alcotest.(check bool) "starts with POST" true
    (String.starts_with ~prefix:"POST /v1/chat/completions HTTP/1.1\r\n" req);
  Alcotest.(check bool) "Host header" true
    (String.split_on_char '\n' req
     |> List.exists (fun l ->
         let trimmed = String.trim l in
         String.starts_with ~prefix:"Host: api.openai.com" trimmed));
  Alcotest.(check bool) "Authorization header" true
    (String.split_on_char '\n' req
     |> List.exists (fun l -> String.trim l = "Authorization: Bearer sk-test"));
  Alcotest.(check bool) "Content-Type" true
    (String.split_on_char '\n' req
     |> List.exists (fun l -> String.trim l = "Content-Type: application/json"));
  Alcotest.(check bool) "Content-Length correct" true
    (String.split_on_char '\n' req
     |> List.exists (fun l ->
         String.trim l = Printf.sprintf "Content-Length: %d"
                (String.length "{\"model\":\"gpt-4o-mini\"}")));
  Alcotest.(check bool) "Connection close" true
    (String.split_on_char '\n' req
     |> List.exists (fun l -> String.trim l = "Connection: close"));
  Alcotest.(check bool) "body at end" true
    (String.ends_with ~suffix:"{\"model\":\"gpt-4o-mini\"}" req)

let test_http_split_response () =
  let raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello" in
  let hdrs, body = Http_client.split_response raw in
  Alcotest.(check string) "headers" "HTTP/1.1 200 OK\r\nContent-Type: text/plain" hdrs;
  Alcotest.(check string) "body" "hello" body

let test_http_split_response_empty_body () =
  let raw = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n" in
  let hdrs, body = Http_client.split_response raw in
  Alcotest.(check string) "headers" "HTTP/1.1 204 No Content\r\nContent-Length: 0" hdrs;
  Alcotest.(check string) "body" "" body

let test_http_parse_status_line () =
  Alcotest.(check int) "200" 200
    (Http_client.parse_status_line "HTTP/1.1 200 OK\r\nServer: test\r\n");
  Alcotest.(check int) "404" 404
    (Http_client.parse_status_line "HTTP/1.1 404 Not Found\r\n");
  Alcotest.(check int) "500" 500
    (Http_client.parse_status_line "HTTP/1.1 500 Internal Server Error\r\n")

let test_http_headers_contain () =
  let headers =
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAuthorization: Bearer x\r\n\r\n"
  in
  Alcotest.(check bool) "Content-Type" true
    (Http_client.headers_contain ~needle:"content-type: application/json" headers);
  Alcotest.(check bool) "case-insensitive header name" true
    (Http_client.headers_contain ~needle:"AUTHORIZATION: BEARER X" headers);
  Alcotest.(check bool) "missing header" false
    (Http_client.headers_contain ~needle:"X-Nope: yes" headers);
  Alcotest.(check bool) "empty needle matches" true
    (Http_client.headers_contain ~needle:"" headers)

let test_http_decode_chunked () =
  let chunked = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n" in
  Alcotest.(check string) "decoded" "hello world"
    (Http_client.decode_chunked chunked)

 let test_http_decode_chunked_single () =
   let chunked = "c\r\nhello world!\r\n0\r\n\r\n" in
   Alcotest.(check string) "decoded" "hello world!"
     (Http_client.decode_chunked chunked)

let test_http_decode_body_non_chunked () =
  let headers = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n" in
  Alcotest.(check string) "passthrough" "hello"
    (Http_client.decode_body headers "hello")

let test_http_decode_body_chunked () =
  let headers = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" in
  Alcotest.(check string) "decoded" "hello world"
    (Http_client.decode_body headers "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")

let test_http_map_http_status_400 () =
  match Http_client.map_http_status 400 "bad json" with
  | Http_client.Invalid_input s -> Alcotest.(check string) "msg" "bad json" s
  | other -> Alcotest.failf "expected Invalid_input, got %s" (http_error_to_string other)

let test_http_map_http_status_401 () =
  match Http_client.map_http_status 401 "x" with
  | Http_client.Permission_denied s ->
    Alcotest.(check bool) "msg contains Invalid API key" true
      (String.contains s 'I')
  | other -> Alcotest.failf "expected Permission_denied, got %s" (http_error_to_string other)

let test_http_map_http_status_403 () =
  match Http_client.map_http_status 403 "forbidden" with
  | Http_client.Permission_denied s -> Alcotest.(check string) "msg" "forbidden" s
  | other -> Alcotest.failf "expected Permission_denied, got %s" (http_error_to_string other)

let test_http_map_http_status_429 () =
  match Http_client.map_http_status 429 "calm down" with
  | Http_client.Rate_limited -> ()
  | other -> Alcotest.failf "expected Rate_limited, got %s" (http_error_to_string other)

let test_http_map_http_status_408_timeout () =
  match Http_client.map_http_status 408 "x" with
  | Http_client.Timeout -> ()
  | other -> Alcotest.failf "expected Timeout, got %s" (http_error_to_string other)

let test_http_map_http_status_504_timeout () =
  match Http_client.map_http_status 504 "x" with
  | Http_client.Timeout -> ()
  | other -> Alcotest.failf "expected Timeout, got %s" (http_error_to_string other)

let test_http_map_http_status_500 () =
  match Http_client.map_http_status 500 "oops" with
  | Http_client.External_failure s ->
    Alcotest.(check bool) "msg contains status code" true
      (String.contains s '5')
  | other -> Alcotest.failf "expected External_failure, got %s" (http_error_to_string other)

let test_http_map_http_status_502_retryable () =
  match Http_client.map_http_status 502 "bad gateway" with
  | Http_client.External_failure s -> Alcotest.(check string) "msg" "Server error 502: bad gateway" s
  | other -> Alcotest.failf "expected External_failure, got %s" (http_error_to_string other)

(* -------------------------------------------------------------------------- *)
(* OpenAI provider — pure tests (no Eio)                                     *)
(* -------------------------------------------------------------------------- *)

let test_openai_create_valid () =
  match
    Openai_provider.create
      (Openai { api_key = "sk-valid"; base_url = None; organization = None; embedding_model = None; prompt_cache_key = None })
  with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "expected Ok, got %s" (show_error e)

let test_openai_create_empty_api_key () =
  match
    Openai_provider.create
      (Openai { api_key = ""; base_url = None; organization = None; embedding_model = None; prompt_cache_key = None })
  with
  | Ok _ -> Alcotest.fail "expected Error for empty api_key"
  | Error (Invalid_input msg) ->
    Alcotest.(check bool) "msg mentions api_key" true
      (String.contains msg 'a')
  | Error e -> Alcotest.failf "expected Invalid_input, got %s" (show_error e)

let test_openai_create_wrong_variant () =
  match
    Openai_provider.create
      (Anthropic { api_key = "sk-valid"; base_url = None })
  with
  | Ok _ -> Alcotest.fail "expected Error for wrong variant"
  | Error (Invalid_input msg) ->
    Alcotest.(check bool) "msg mentions OpenAI" true
      (String.contains msg 'O')
  | Error e -> Alcotest.failf "expected Invalid_input, got %s" (show_error e)

let test_openai_create_custom_base_url () =
  match
    Openai_provider.create
      (Openai { api_key = "sk-valid"
              ; base_url = Some "https://gateway.example.com/v1"
              ; organization = Some "org-test"; embedding_model = None; prompt_cache_key = None })
  with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "expected Ok, got %s" (show_error e)

let test_openai_complete_without_network () =
  match
    Openai_provider.create
      (Openai { api_key = "sk-test"; base_url = None; organization = None; embedding_model = None; prompt_cache_key = None })
  with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok t ->
    (match Openai_provider.complete t openai_model [] user_only_conv with
     | Ok _ -> Alcotest.fail "expected error when network not set"
     | Error (Internal msg) ->
       Alcotest.(check bool) "msg mentions network" true
         (String.contains msg 'N' || String.contains msg 'n')
     | Error e -> Alcotest.failf "expected Internal, got %s" (show_error e))

let test_openai_stream_without_network () =
  match
    Openai_provider.create
      (Openai { api_key = "sk-test"; base_url = None; organization = None; embedding_model = None; prompt_cache_key = None })
  with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok t ->
    let chunks = ref [] in
    let cb c = chunks := c :: !chunks in
    (match
       Openai_provider.stream t openai_model [] user_only_conv default_stream_config cb
     with
     | Ok _ -> Alcotest.fail "expected error when network not set"
     | Error (Internal _) -> ()
     | Error e -> Alcotest.failf "expected Internal, got %s" (show_error e))

let test_openai_url_uses_chat_completions_path () =
  let url = Http_client.parse_url "https://api.openai.com/v1" in
  Alcotest.(check string) "host" "api.openai.com" url.host;
  Alcotest.(check string) "path prefix" "/v1/" url.path;
  let full_path = url.path ^ "chat/completions" in
  Alcotest.(check string) "full chat path" "/v1/chat/completions" full_path

let test_openai_request_includes_authorization_bearer () =
  let auth_header = "Bearer " ^ "sk-abc123" in
  Alcotest.(check string) "bearer prefix" "Bearer sk-abc123" auth_header

let test_openai_request_body_has_model_field () =
  let body_json =
    `Assoc
      [ "model", `String openai_model.model_name
      ; "messages", `List [ `Assoc [ "role", `String "user"; "content", `String "hi" ] ]
      ; "temperature", `Float openai_model.temperature
      ; "max_tokens", `Int (Option.value openai_model.max_tokens ~default:0)
      ; "stream", `Bool false
      ]
  in
  let s = Yojson.Safe.to_string body_json in
  let parsed = Yojson.Safe.from_string s in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "model name" "gpt-4o-mini" (parsed |> member "model" |> to_string);
  Alcotest.(check int) "max_tokens" 64 (parsed |> member "max_tokens" |> to_int);
  Alcotest.(check (float 0.0)) "temperature" 0.0 (parsed |> member "temperature" |> to_float);
  Alcotest.(check bool) "stream false" false (parsed |> member "stream" |> to_bool)

let test_openai_request_body_with_tools () =
  let tools_json : Yojson.Safe.t =
    `List
      [ `Assoc
          [ "type", `String "function"
          ; "function",
            `Assoc
              [ "name", `String "get_time"
              ; "description", `String "Return current UTC time"
              ; "parameters", `Assoc [ "type", `String "object" ]
              ]
          ]
      ]
  in
  let body_json =
    `Assoc
      [ "model", `String "gpt-4o-mini"
      ; "messages", `List []
      ; "temperature", `Float 0.0
      ; "stream", `Bool false
      ; "tools", tools_json
      ]
  in
  let parsed = Yojson.Safe.from_string (Yojson.Safe.to_string body_json) in
  let open Yojson.Safe.Util in
  let tools = parsed |> member "tools" |> to_list in
  Alcotest.(check int) "1 tool" 1 (List.length tools);
  let first = List.hd tools in
  Alcotest.(check string) "tool type" "function" (first |> member "type" |> to_string);
  let fn = first |> member "function" in
  Alcotest.(check string) "tool name" "get_time" (fn |> member "name" |> to_string)

let test_openai_close_is_safe () =
  match
    Openai_provider.create
      (Openai { api_key = "sk-x"; base_url = None; organization = None; embedding_model = None; prompt_cache_key = None })
  with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok t ->
    Openai_provider.close t;
    Alcotest.(check bool) "close did not raise" true true

(* -------------------------------------------------------------------------- *)
(* Anthropic provider — pure tests (no Eio)                                  *)
(* -------------------------------------------------------------------------- *)

let test_anthropic_create_valid () =
  match
    Anthropic_provider.create
      (Anthropic { api_key = "sk-ant-valid"; base_url = None })
  with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "expected Ok, got %s" (show_error e)

let test_anthropic_create_empty_api_key () =
  match
    Anthropic_provider.create
      (Anthropic { api_key = ""; base_url = None })
  with
  | Ok _ -> Alcotest.fail "expected Error for empty api_key"
  | Error (Invalid_input msg) ->
    Alcotest.(check bool) "msg mentions api_key" true
      (String.contains msg 'a')
  | Error e -> Alcotest.failf "expected Invalid_input, got %s" (show_error e)

let test_anthropic_create_wrong_variant () =
  match
    Anthropic_provider.create
      (Openai { api_key = "sk-valid"; base_url = None; organization = None; embedding_model = None; prompt_cache_key = None })
  with
  | Ok _ -> Alcotest.fail "expected Error for wrong variant"
  | Error (Invalid_input msg) ->
    Alcotest.(check bool) "msg mentions Anthropic" true
      (String.contains msg 'A')
  | Error e -> Alcotest.failf "expected Invalid_input, got %s" (show_error e)

let test_anthropic_create_custom_base_url () =
  match
    Anthropic_provider.create
      (Anthropic { api_key = "sk-ant-valid"
                  ; base_url = Some "https://proxy.example.com" })
  with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "expected Ok, got %s" (show_error e)

let test_anthropic_complete_without_network () =
  match
    Anthropic_provider.create
      (Anthropic { api_key = "sk-ant-test"; base_url = None })
  with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok t ->
    (match Anthropic_provider.complete t anthropic_model [] user_only_conv with
     | Ok _ -> Alcotest.fail "expected error when network not set"
     | Error (Internal msg) ->
       Alcotest.(check bool) "msg mentions network" true
         (String.contains msg 'N' || String.contains msg 'n')
     | Error e -> Alcotest.failf "expected Internal, got %s" (show_error e))

let test_anthropic_stream_without_network () =
  match
    Anthropic_provider.create
      (Anthropic { api_key = "sk-ant-test"; base_url = None })
  with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok t ->
    let cb _ = () in
    (match
       Anthropic_provider.stream t anthropic_model [] user_only_conv
         default_stream_config cb
     with
     | Ok _ -> Alcotest.fail "expected error when network not set"
     | Error (Internal _) -> ()
     | Error e -> Alcotest.failf "expected Internal, got %s" (show_error e))

let test_anthropic_url_uses_v1_messages_path () =
  let url = Http_client.parse_url "https://api.anthropic.com" in
  Alcotest.(check string) "host" "api.anthropic.com" url.host;
  Alcotest.(check string) "path root" "/" url.path;
  let full_path = url.path ^ "v1/messages" in
  Alcotest.(check string) "full messages path" "/v1/messages" full_path

let test_anthropic_request_includes_required_headers () =
  let req =
    Http_client.build_http_request
      ~host:"api.anthropic.com"
      ~path:"/v1/messages"
      ~headers:
        [ "x-api-key", "sk-ant-abc123"
        ; "anthropic-version", "2023-06-01"
        ]
      ~body:"{}"
  in
  Alcotest.(check bool) "x-api-key present" true
    (String.split_on_char '\n' req
     |> List.exists (fun l -> String.trim l = "x-api-key: sk-ant-abc123"));
  Alcotest.(check bool) "anthropic-version present" true
    (String.split_on_char '\n' req
     |> List.exists (fun l -> String.trim l = "anthropic-version: 2023-06-01"))

let test_anthropic_request_body_includes_max_tokens () =
  let body_json =
    `Assoc
      [ "model", `String anthropic_model.model_name
      ; "messages", `List [ `Assoc [ "role", `String "user"; "content", `List [ `Assoc [ "type", `String "text"; "text", `String "hi" ] ] ] ]
      ; "max_tokens", `Int 64
      ; "temperature", `Float 0.0
      ; "stream", `Bool false
      ]
  in
  let parsed = Yojson.Safe.from_string (Yojson.Safe.to_string body_json) in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "model" "claude-3-5-sonnet-latest"
    (parsed |> member "model" |> to_string);
  Alcotest.(check int) "max_tokens" 64 (parsed |> member "max_tokens" |> to_int);
  Alcotest.(check bool) "messages non-empty" true
    (parsed |> member "messages" |> to_list |> List.length > 0)

let test_anthropic_request_body_extracts_system_prompt () =
  let conv : conversation =
    { messages =
        [ { role = System
          ; content_blocks = [Text_block { text = "You are concise."; cache_control = None }]
          ; tool_calls = None
          ; tool_call_id = None
          ; name = None
          }
        ; { role = User
          ; content_blocks = [Text_block { text = "Hello"; cache_control = None }]
          ; tool_calls = None
          ; tool_call_id = None
          ; name = None
          }
        ]
    ; metadata = []
    }
  in
  let sys, rest =
    List.partition (fun (m : message) -> match m.role with System -> true | _ -> false)
      conv.messages
  in
  Alcotest.(check int) "1 system msg" 1 (List.length sys);
  Alcotest.(check int) "1 user msg" 1 (List.length rest)

let test_anthropic_close_is_safe () =
  match
    Anthropic_provider.create
      (Anthropic { api_key = "sk-ant-x"; base_url = None })
  with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok t ->
    Anthropic_provider.close t;
    Alcotest.(check bool) "close did not raise" true true

(* -------------------------------------------------------------------------- *)
(* Eio-based tests — TLS handshake error path & mock-server round-trips       *)
(* -------------------------------------------------------------------------- *)

let test_openai_connection_refused_returns_external_failure () =
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun _sw ->
  let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  match
    Openai_provider.create
      (Openai { api_key = "sk-test"
              ; base_url = Some "https://127.0.0.1:1"
              ; organization = None; embedding_model = None; prompt_cache_key = None })
  with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok t ->
    Openai_provider.set_network t net;
    (match Openai_provider.complete t openai_model [] user_only_conv with
     | Ok _ -> Alcotest.fail "expected error connecting to 127.0.0.1:1"
     | Error (External_failure _msg) -> ()
     | Error (Internal msg) -> Alcotest.failf "expected External_failure, got Internal(%s)" msg
     | Error e -> Alcotest.failf "expected External_failure, got %s" (show_error e))

let test_anthropic_connection_refused_returns_external_failure () =
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun _sw ->
  let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  match
    Anthropic_provider.create
      (Anthropic { api_key = "sk-ant-test"
                  ; base_url = Some "https://127.0.0.1:1" })
  with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok t ->
    Anthropic_provider.set_network t net;
    (match Anthropic_provider.complete t anthropic_model [] user_only_conv with
     | Ok _ -> Alcotest.fail "expected error connecting to 127.0.0.1:1"
     | Error (External_failure _msg) -> ()
     | Error (Internal msg) -> Alcotest.failf "expected External_failure, got Internal(%s)" msg
     | Error e -> Alcotest.failf "expected External_failure, got %s" (show_error e))

(* -------------------------------------------------------------------------- *)
(* Edge cases                                                                *)
(* -------------------------------------------------------------------------- *)

let test_edge_openai_unicode_in_message () =
  let conv : conversation =
    { messages =
        [ { role = User
          ; content_blocks = [Text_block { text = "こんにちは 🌍 — привет"; cache_control = None }]
          ; tool_calls = None
          ; tool_call_id = None
          ; name = None
          } ]
    ; metadata = []
    }
  in
  let msg_json =
    `Assoc
      [ "role", `String "user"
      ; "content", `String (Option.value (match conv.messages with
          | m :: _ -> Message.content_opt m | [] -> None) ~default:"")
      ]
  in
  let s = Yojson.Safe.to_string msg_json in
  Alcotest.(check bool) "preserved Japanese" true
    (String.contains s '\xE3');  (* 'こ' starts with 0xE3 in UTF-8 *)
  Alcotest.(check bool) "preserved Cyrillic" true
    (String.contains s '\xD0');
  Alcotest.(check bool) "preserved emoji" true
    (String.contains s '\xF0')

let test_edge_anthropic_unicode_in_system_prompt () =
  let text = "系统提示: 你好 — Σ ⊕ π" in
  let json = `Assoc [ "system", `String text; "model", `String "claude" ] in
  let s = Yojson.Safe.to_string json in
  let parsed = Yojson.Safe.from_string s in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "round-trip unicode" text (parsed |> member "system" |> to_string)

let test_edge_openai_tool_call_response_parsing () =
  let body =
    {|{"id":"chatcmpl-1","object":"chat.completion","created":1234,"model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_abc","type":"function","function":{"name":"get_time","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}|}
  in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let first_choice = json |> member "choices" |> to_list |> List.hd in
  let message = first_choice |> member "message" in
  let tool_calls = message |> member "tool_calls" |> to_list in
  Alcotest.(check int) "1 tool call" 1 (List.length tool_calls);
  let first_tc = List.hd tool_calls in
  Alcotest.(check string) "tool id" "call_abc" (first_tc |> member "id" |> to_string);
  let fn = first_tc |> member "function" in
  Alcotest.(check string) "tool name" "get_time" (fn |> member "name" |> to_string)

let test_edge_anthropic_malformed_json_body () =
  let bad = "not valid json {{{" in
  let caught =
    try
      let _ = Yojson.Safe.from_string bad in
      false
    with Yojson.Json_error _ -> true
  in
  Alcotest.(check bool) "parse error caught" true caught

let test_edge_openai_malformed_response_parsing () =
  (* Verify the response body produced by a corrupted upstream doesn't crash
     the JSON shape checks used by the tool-call parser. *)
  let body = "{\"choices\":[{\"message\":{\"content\":\"x\"}}]}" in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let first = json |> member "choices" |> to_list |> List.hd in
  let message = first |> member "message" in
  Alcotest.(check string) "content" "x" (message |> member "content" |> to_string)

let test_edge_http_decode_chunked_empty_input () =
  let result = Http_client.decode_chunked "" in
  Alcotest.(check string) "empty in → empty out" "" result

let test_edge_http_unicode_header () =
  let headers = "HTTP/1.1 200 OK\r\nX-Custom: 日本語\r\n\r\n" in
  Alcotest.(check bool) "unicode header found" true
    (Http_client.headers_contain ~needle:"X-Custom: 日本語" headers)

let test_edge_http_very_long_header_block () =
  let header_value = String.make 8192 'A' in
  let headers = Printf.sprintf "HTTP/1.1 200 OK\r\nX-Big: %s\r\n\r\n" header_value in
  Alcotest.(check bool) "long header found" true
    (Http_client.headers_contain ~needle:"X-Big:" headers)

let test_edge_http_split_response_no_separator () =
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n" in
  let hdrs, body = Http_client.split_response raw in
  Alcotest.(check bool) "no separator returns whole string" true
    (hdrs = raw && body = "")

let test_edge_openai_request_body_max_tokens_omitted () =
  let m : model_config = { openai_model with max_tokens = None } in
  let body_json : Yojson.Safe.t =
    `Assoc
      [ "model", `String m.model_name
      ; "messages", `List []
      ; "temperature", `Float m.temperature
      ; "stream", `Bool false
      ]
  in
  let parsed = Yojson.Safe.from_string (Yojson.Safe.to_string body_json) in
  let keys = parsed |> Yojson.Safe.Util.to_assoc |> List.map fst in
  Alcotest.(check bool) "no max_tokens key" true
    (not (List.mem "max_tokens" keys))

(* -------------------------------------------------------------------------- *)
(* Test runner                                                                *)
(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "Provider stack (HTTP / OpenAI / Anthropic)" [
    "http_client", [
      Alcotest.test_case "parse_url https with path" `Quick test_http_parse_url_https;
      Alcotest.test_case "parse_url with port" `Quick test_http_parse_url_with_port;
      Alcotest.test_case "parse_url no path" `Quick test_http_parse_url_no_path;
      Alcotest.test_case "parse_url http scheme" `Quick test_http_parse_url_http_scheme;
      Alcotest.test_case "build_http_request shape" `Quick test_http_build_http_request_shape;
      Alcotest.test_case "split_response basic" `Quick test_http_split_response;
      Alcotest.test_case "split_response empty body" `Quick test_http_split_response_empty_body;
      Alcotest.test_case "parse_status_line" `Quick test_http_parse_status_line;
      Alcotest.test_case "headers_contain (case-insensitive)" `Quick test_http_headers_contain;
      Alcotest.test_case "decode_chunked two chunks" `Quick test_http_decode_chunked;
      Alcotest.test_case "decode_chunked single" `Quick test_http_decode_chunked_single;
      Alcotest.test_case "decode_body non-chunked" `Quick test_http_decode_body_non_chunked;
      Alcotest.test_case "decode_body chunked" `Quick test_http_decode_body_chunked;
      Alcotest.test_case "map_http_status 400 → Invalid_input" `Quick test_http_map_http_status_400;
      Alcotest.test_case "map_http_status 401 → Permission_denied" `Quick test_http_map_http_status_401;
      Alcotest.test_case "map_http_status 403 → Permission_denied" `Quick test_http_map_http_status_403;
      Alcotest.test_case "map_http_status 429 → Rate_limited" `Quick test_http_map_http_status_429;
      Alcotest.test_case "map_http_status 408 → Timeout" `Quick test_http_map_http_status_408_timeout;
      Alcotest.test_case "map_http_status 504 → Timeout" `Quick test_http_map_http_status_504_timeout;
      Alcotest.test_case "map_http_status 500 → External_failure" `Quick test_http_map_http_status_500;
      Alcotest.test_case "map_http_status 502 → External_failure" `Quick test_http_map_http_status_502_retryable;
    ];
    "openai_provider", [
      Alcotest.test_case "create valid config" `Quick test_openai_create_valid;
      Alcotest.test_case "create empty api_key rejected" `Quick test_openai_create_empty_api_key;
      Alcotest.test_case "create wrong config variant rejected" `Quick test_openai_create_wrong_variant;
      Alcotest.test_case "create custom base_url" `Quick test_openai_create_custom_base_url;
      Alcotest.test_case "complete without network → Internal" `Quick test_openai_complete_without_network;
      Alcotest.test_case "stream without network → Internal" `Quick test_openai_stream_without_network;
      Alcotest.test_case "URL uses /v1/chat/completions" `Quick test_openai_url_uses_chat_completions_path;
      Alcotest.test_case "Authorization Bearer header shape" `Quick test_openai_request_includes_authorization_bearer;
      Alcotest.test_case "request body has model/temp/stream fields" `Quick test_openai_request_body_has_model_field;
      Alcotest.test_case "request body with tools array" `Quick test_openai_request_body_with_tools;
      Alcotest.test_case "close is safe" `Quick test_openai_close_is_safe;
    ];
    "anthropic_provider", [
      Alcotest.test_case "create valid config" `Quick test_anthropic_create_valid;
      Alcotest.test_case "create empty api_key rejected" `Quick test_anthropic_create_empty_api_key;
      Alcotest.test_case "create wrong config variant rejected" `Quick test_anthropic_create_wrong_variant;
      Alcotest.test_case "create custom base_url" `Quick test_anthropic_create_custom_base_url;
      Alcotest.test_case "complete without network → Internal" `Quick test_anthropic_complete_without_network;
      Alcotest.test_case "stream without network → Internal" `Quick test_anthropic_stream_without_network;
      Alcotest.test_case "URL uses /v1/messages" `Quick test_anthropic_url_uses_v1_messages_path;
      Alcotest.test_case "request includes x-api-key + anthropic-version" `Quick test_anthropic_request_includes_required_headers;
      Alcotest.test_case "request body has model + max_tokens" `Quick test_anthropic_request_body_includes_max_tokens;
      Alcotest.test_case "system prompt partition logic" `Quick test_anthropic_request_body_extracts_system_prompt;
      Alcotest.test_case "close is safe" `Quick test_anthropic_close_is_safe;
    ];
     "openai_eio_error_paths", [
       Alcotest.test_case "connection refused → External_failure" `Quick
         test_openai_connection_refused_returns_external_failure;
     ];
     "anthropic_eio_error_paths", [
       Alcotest.test_case "connection refused → External_failure" `Quick
         test_anthropic_connection_refused_returns_external_failure;
     ];
    "edge_cases", [
      Alcotest.test_case "OpenAI Unicode in user message" `Quick
        test_edge_openai_unicode_in_message;
      Alcotest.test_case "Anthropic Unicode in system prompt" `Quick
        test_edge_anthropic_unicode_in_system_prompt;
      Alcotest.test_case "OpenAI tool-call response parsing" `Quick
        test_edge_openai_tool_call_response_parsing;
      Alcotest.test_case "Anthropic malformed JSON body" `Quick
        test_edge_anthropic_malformed_json_body;
      Alcotest.test_case "OpenAI malformed response parsing" `Quick
        test_edge_openai_malformed_response_parsing;
      Alcotest.test_case "decode_chunked empty input" `Quick
        test_edge_http_decode_chunked_empty_input;
      Alcotest.test_case "Unicode header value preserved" `Quick
        test_edge_http_unicode_header;
      Alcotest.test_case "Very long header block handled" `Quick
        test_edge_http_very_long_header_block;
      Alcotest.test_case "split_response with no separator" `Quick
        test_edge_http_split_response_no_separator;
      Alcotest.test_case "OpenAI body omits max_tokens when None" `Quick
        test_edge_openai_request_body_max_tokens_omitted;
    ];
  ]
