(* End-to-end HTTP transport tests — GitHub #37 / v0.16.3 hotfix.

   The raw-socket Http_timeout path sent a malformed request (headers after a
   premature CRLF, no Content-Length, body dropped), rejected TLS, and never
   parsed SSE. MCP HTTP and the web builtins were moved back to cohttp-eio;
   these cases lock the wire format and the content-type split with a local
   server. *)

open Par
open Types

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"
  | Cancelled _ -> "cancelled"

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let lowercase = String.lowercase_ascii

let header_value headers name =
  List.find_map (fun line ->
    let lower = lowercase line in
    if starts_with ~prefix:(name ^ ":") lower then
      Some (String.trim
              (String.sub line (String.length name + 1)
                 (String.length line - String.length name - 1)))
    else None) headers

let jsonrpc_method body =
  try
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      (match List.assoc_opt "method" fields with
       | Some (`String m) -> Some m
       | _ -> None)
    | _ -> None
  with _ -> None

let jsonrpc_response ~id result =
  Yojson.Safe.to_string (`Assoc [
    "jsonrpc", `String "2.0";
    "id", id;
    "result", result;
  ])

let jsonrpc_member body =
  try
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      (match List.assoc_opt "jsonrpc" fields with
       | Some (`String v) -> Some v
       | _ -> None)
    | _ -> None
  with _ -> None

let response_for_body ~sse body =
  match jsonrpc_method body with
  (* GitHub #38: a spec-compliant streamable-HTTP server rejects a message
     that omits "jsonrpc":"2.0" with 400. Model that instead of tolerating it
     so the wire format cannot regress. *)
  | Some _ when jsonrpc_member body <> Some "2.0" ->
    (400, "text/plain", "missing jsonrpc 2.0")
  | Some "initialize" ->
    let json = jsonrpc_response ~id:(`Int 0) (`Assoc [
      "protocolVersion", `String Mcp_types.protocol_version;
      "capabilities", `Assoc [("tools", `Assoc [])];
      "serverInfo", `Assoc [("name", `String "local"); ("version", `String "1")];
    ]) in
    if sse then (200, "text/event-stream", "data: " ^ json ^ "\n\n")
    else (200, "application/json", json)
  | Some "tools/list" ->
    let json = jsonrpc_response ~id:(`Int 1) (`Assoc [
      "tools", `List [
        `Assoc [
          "name", `String "echo";
          "description", `String "Echoes";
          "inputSchema", `Assoc [("type", `String "object")];
        ];
      ];
    ]) in
    if sse then (200, "text/event-stream", "data: " ^ json ^ "\n\n")
    else (200, "application/json", json)
  | Some _ -> (200, "application/json", "{}")   (* notifications/initialized *)
  | None -> (200, "text/plain", "hello-from-fetch")

let with_server env ~sse f =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let server =
    Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:5
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr server with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP listening address"
  in
  let requests = ref [] in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Net.accept_fork server ~sw ~on_error:(fun _ -> ())
        (fun flow _addr ->
          try
            let buf = Eio.Buf_read.of_flow flow
                ~initial_size:4096 ~max_size:(1024 * 1024) in
            let request_line = Eio.Buf_read.line buf in
            let headers = ref [] in
            let rec read_headers () =
              let line = Eio.Buf_read.line buf in
              if String.trim line = "" then ()
              else begin
                headers := line :: !headers;
                read_headers ()
              end
            in
            read_headers ();
            let content_length =
              match header_value !headers "content-length" with
              | Some v -> (try int_of_string v with _ -> 0)
              | None -> 0
            in
            let body =
              if content_length > 0 then Eio.Buf_read.take content_length buf
              else ""
            in
            requests := (request_line, !headers, body) :: !requests;
            let status, ctype, resp_body = response_for_body ~sse body in
            let response = Printf.sprintf
                "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                status (if status = 400 then "Bad Request" else "OK")
                ctype (String.length resp_body) resp_body in
            Eio.Flow.copy (Eio.Flow.string_source response) flow
          with _ -> ())
    done);
  f port requests

let mcp_config port : Mcp_types.server_config =
  Mcp_types.Http_server {
    name = "local-http";
    url = Printf.sprintf "http://127.0.0.1:%d/mcp" port;
    headers = [];
    startup_timeout = 5.0;
  }

let create_runtime env sw ?(mcp_servers = []) () =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let config : runtime_config =
    { persistence = `Sqlite ":memory:";
      event_bus = Runtime.default_event_bus_config;
      default_quota = Runtime.default_quota;
      shutdown = Runtime.default_shutdown_config;
      llm_providers = [];
      mcp_sampling = Disabled;
      eval_limits = { max_depth = 10; max_node_visits = 1000 };
      parallel_tool_execution = true;
      bash_confirm = Runtime.default_bash_confirm;
      event_retention_seconds = 604800.0;
      max_tool_schema_tokens = None;
      max_tool_result_chars = 100_000 }
  in
  match Runtime.create ~config ~mcp_servers
          ~mcp_net:net ~mcp_clock:clock sw with
  | Ok rt -> rt
  | Error e -> Alcotest.failf "Runtime.create: %s" (error_to_string e)

let descriptor_names rt =
  List.map (fun (d : tool_descriptor) -> d.name)
    (Runtime.mcp_tool_descriptors rt)

let with_runtime env port f =
  Eio.Switch.run (fun sw ->
    let rt = create_runtime env sw ~mcp_servers:[mcp_config port] () in
    Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () -> f rt))

let test_mcp_http_json () =
  Eio_main.run (fun env ->
    with_server env ~sse:false (fun port requests ->
      with_runtime env port (fun rt ->
        Alcotest.(check (list string)) "one tool" ["echo"]
          (descriptor_names rt);
        let initialize =
          List.find_opt (fun (_line, _headers, body) ->
            jsonrpc_method body = Some "initialize") !requests
        in
        match initialize with
        | None -> Alcotest.fail "initialize never reached the server"
        | Some (_line, headers, body) ->
          Alcotest.(check bool) "content-type header sent" true
            (Option.is_some (header_value headers "content-type"));
          Alcotest.(check bool) "content-length sent" true
            (Option.is_some (header_value headers "content-length"));
          Alcotest.(check (option string)) "jsonrpc 2.0 member sent" (Some "2.0")
            (jsonrpc_member body);
          Alcotest.(check bool) "initialize params sent" true
            (try
               ignore (Str.search_forward
                         (Str.regexp_string "protocolVersion") body 0);
               true
             with Not_found -> false))))

let test_mcp_http_sse () =
  Eio_main.run (fun env ->
    with_server env ~sse:true (fun port requests ->
      with_runtime env port (fun rt ->
        Alcotest.(check (list string)) "SSE response parsed" ["echo"]
          (descriptor_names rt);
        Alcotest.(check bool) "tools/list reached the server" true
          (List.exists (fun (_line, _headers, body) ->
             jsonrpc_method body = Some "tools/list") !requests))))

let test_fetch_url_sends_headers () =
  Eio_main.run (fun env ->
    with_server env ~sse:false (fun port requests ->
      Eio.Switch.run (fun sw ->
        let net = Eio.Stdenv.net env in
        let workspace =
          match Workspace.of_cwd () with
          | Ok w -> w
          | Error e -> Alcotest.failf "workspace: %s" (error_to_string e)
        in
        let tools = Builtin_tools.builtin_tools ~switch:sw ~net ~workspace in
        let handler =
          match List.find_opt (fun (tb : tool_binding) ->
              tb.descriptor.name = "fetch_url") tools with
          | Some tb -> tb.handler
          | None -> Alcotest.fail "fetch_url tool missing"
        in
        let url = Printf.sprintf "http://127.0.0.1:%d/page" port in
        (match handler (`Assoc [("url", `String url)]) (Cancellation.create_token sw) with
         | Success json ->
           let content =
             match json |> Yojson.Safe.Util.member "content" with
             | `String s -> s
             | _ -> Alcotest.failf "unexpected success shape: %s"
                      (Yojson.Safe.to_string json)
           in
           Alcotest.(check bool) "body returned" true
             (starts_with ~prefix:"hello-from-fetch" content)
         | Error { message; _ } -> Alcotest.failf "fetch_url failed: %s" message
         | _ -> Alcotest.fail "unexpected handler result");
        Alcotest.(check bool) "user-agent header sent" true
          (List.exists (fun (_line, headers, _body) ->
             Option.is_some (header_value headers "user-agent")) !requests))))

let () =
  Alcotest.run "http_transport_e2e" [
    ("http_transport_e2e", [
      Alcotest.test_case "MCP HTTP JSON response" `Quick test_mcp_http_json;
      Alcotest.test_case "MCP HTTP SSE response" `Quick test_mcp_http_sse;
      Alcotest.test_case "fetch_url sends headers and returns a body" `Quick
        test_fetch_url_sends_headers;
    ]);
  ]
