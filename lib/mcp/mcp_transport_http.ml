(* lib/mcp/mcp_transport_http.ml
   v0.4.4 W1 — MCP HTTP/SSE transport (MCP spec §4.1, 2025-06-18).

   POSTs JSON-RPC messages to a single endpoint URL.  The server may reply with
   a direct JSON response or an SSE stream; both are handled.  Session ids are
   captured from the [Mcp-Session-Id] response header and echoed back on later
   requests.

   v0.18 / PAR-9km: runs on the owned-socket transport in [Http_client], so a
   cancelled invoke also interrupts a stalled MCP read. *)

[@@@warning "-32-34-37-69"]

let max_body_size = 10 * 1024 * 1024
let session_id_header = "mcp-session-id"

type t = {
  uri : Uri.t;
  url : Http_client.parsed_url;
  net : [ `Generic ] Eio.Net.ty Eio.Net.t;
  session_id : string option ref;
  sw : Eio.Switch.t;
  mutable closed : bool;
  sampling_handler : (Yojson.Safe.t -> (Yojson.Safe.t, Types.error_category) result) option ref;
}

let parsed_url_of_uri uri =
  let use_tls = match Uri.scheme uri with Some "https" -> true | _ -> false in
  let port = match Uri.port uri with
    | Some port -> port
    | None -> if use_tls then 443 else 80
  in
  let path =
    match Uri.path_and_query uri with path when path <> "" -> path | _ -> "/"
  in
  { Http_client.host = Option.value (Uri.host uri) ~default:"";
    port; path; use_tls }

let create ~url ~net ~sw =
  let uri = Uri.of_string url in
  { uri;
    url = parsed_url_of_uri uri;
    net = (net :> [ `Generic ] Eio.Net.ty Eio.Net.t);
    session_id = ref None;
    sw;
    closed = false;
    sampling_handler = ref None;
  }

let base_headers () =
  Tracing.outgoing_headers () @ [
    "Accept", "application/json, text/event-stream";
  ]

let build_headers t extra =
  let headers = base_headers () @ extra in
  match !(t.session_id) with
  | None -> headers
  | Some sid -> (session_id_header, sid) :: headers

let header_value headers name =
  let name = String.lowercase_ascii name in
  List.find_map (fun (k, v) ->
    if String.lowercase_ascii k = name then Some v else None) headers

let capture_session_id t headers =
  match header_value headers session_id_header with
  | Some sid -> t.session_id := Some sid
  | None -> ()

let content_type_is headers prefix =
  match header_value headers "content-type" with
  | None -> false
  | Some ct ->
    let ct = String.lowercase_ascii ct in
    String.length ct >= String.length prefix
    && String.sub ct 0 (String.length prefix) = prefix

let content_type_is_json headers =
  match header_value headers "content-type" with
  | None -> false
  | Some ct ->
    let ct = String.lowercase_ascii ct in
    (try ignore (Str.search_forward (Str.regexp_string "application/json") ct 0); true
     with Not_found -> false)

let set_sampling_handler t handler =
  t.sampling_handler := Some handler

let request_body t req =
  let body = Yojson.Safe.to_string (Mcp_types.request_to_yojson req) in
  let headers = build_headers t [] in
  Http_client.build_http_request ~host:t.url.Http_client.host
    ~path:t.url.Http_client.path ~headers ~body

let notify_body t notif =
  let body = Yojson.Safe.to_string (Mcp_types.notification_to_yojson notif) in
  let headers = build_headers t [] in
  Http_client.build_http_request ~host:t.url.Http_client.host
    ~path:t.url.Http_client.path ~headers ~body

let post_sampling_response t request_id result_json =
  let resp_body = `Assoc [
    "jsonrpc", `String "2.0";
    "id", (match request_id with
           | Mcp_types.Int_id n -> `Int n
           | Mcp_types.String_id s -> `String s);
    "result", result_json;
  ] in
  let body = Yojson.Safe.to_string resp_body in
  let headers = build_headers t [] in
  let request = Http_client.build_http_request ~host:t.url.Http_client.host
      ~path:t.url.Http_client.path ~headers ~body in
  (try
     let response =
       Http_client.do_request_to_buffer t.net t.url request ~timeout:30.0
     in
     capture_session_id t response.Http_client.headers
   with _ -> ())

let parse_response_json s =
  match Yojson.Safe.from_string s with
  | exception Yojson.Json_error msg ->
    Error (Types.Invalid_input ("MCP HTTP response is not valid JSON: " ^ msg))
  | json ->
    (match Mcp_types.response_of_yojson json with
     | Ok r -> Ok r
     | Error e -> Error (Types.Invalid_input ("MCP HTTP response is not JSON-RPC: " ^ e)))

let parse_sse_lines t ~target_id read_line =
  let rec read_events () =
    match read_line () with
    | None -> Error (Types.Internal "MCP HTTP SSE stream ended without response")
    | Some line ->
      let line = String.trim line in
      if line = "" then read_events ()
      else if String.length line > 5 && String.sub line 0 5 = "data:" then
        let data = String.trim (String.sub line 5 (String.length line - 5)) in
        if data = "" then read_events ()
        else
          match Yojson.Safe.from_string data with
          | exception Yojson.Json_error msg ->
            Logs.debug (fun m ->
              m "mcp_transport_http: skipping non-JSON SSE data: %s" msg);
            read_events ()
          | json ->
            (match Mcp_types.response_of_yojson json with
             | Ok r when Mcp_types.request_id_matches r.Mcp_types.id (Mcp_types.Int_id target_id) ->
               Ok r
             | Ok _ -> read_events ()
             | Error _ ->
               (match Mcp_types.jsonrpc_request_of_yojson json with
                | Ok req when req.Mcp_types.method_ = Mcp_types.method_sampling_create ->
                  (match !(t.sampling_handler) with
                   | Some handler ->
                     let params = Option.value req.Mcp_types.params ~default:`Null in
                     (match handler params with
                      | Ok result_json -> post_sampling_response t req.Mcp_types.id result_json
                      | Error _ -> ());
                     read_events ()
                   | None -> read_events ())
                | Ok _ -> read_events ()
                | Error _ ->
                  (match Mcp_types.notification_of_yojson json with
                   | Ok _ -> read_events ()
                   | Error e ->
                     Logs.debug (fun m ->
                       m "mcp_transport_http: skipping unknown SSE message: %s" e);
                     read_events ())))
      else read_events ()
  in
  read_events ()

let read_all_lines read_line =
  let buf = Buffer.create 1024 in
  let rec loop () =
    match read_line () with
    | None -> Buffer.contents buf
    | Some line ->
      Buffer.add_string buf line;
      Buffer.add_char buf '\n';
      loop ()
  in
  loop ()

let request_response t req =
  if t.closed then Error (Types.Internal "transport closed")
  else
    let request = request_body t req in
    let timeout_error msg =
      try ignore (Str.search_forward (Str.regexp "timed out") msg 0); true
      with Not_found -> false
    in
    try
      Http_client.do_stream t.net t.url request ~idle_timeout:30.0
        (fun ~status ~headers ~read_line ->
           capture_session_id t headers;
           if status >= 400 then
             Error (Types.Internal (Printf.sprintf "MCP HTTP error status %d" status))
           else if status = 202 then
             Error (Types.Internal "MCP HTTP request received 202 (expected response)")
           else if content_type_is_json headers then
             match parse_response_json (read_all_lines read_line) with
             | Error _ as e -> e
             | Ok r ->
               if Mcp_types.request_id_matches r.Mcp_types.id req.Mcp_types.id
               then Ok r
               else Error (Types.Internal "MCP HTTP response id mismatch")
           else if content_type_is headers "text/event-stream" then
             (match req.Mcp_types.id with
              | Mcp_types.Int_id target_id ->
                parse_sse_lines t ~target_id read_line
              | Mcp_types.String_id _ ->
                Error (Types.Invalid_input
                         "MCP HTTP SSE response matching requires int id"))
           else
             Error (Types.Internal "MCP HTTP unexpected response content-type"))
    with
    | Failure msg when timeout_error msg -> Error Types.Timeout
    | ex ->
      Error
        (Types.Internal
           (Printf.sprintf "MCP HTTP POST failed: %s" (Printexc.to_string ex)))

let notify t notif =
  if t.closed then Error (Types.Internal "transport closed")
  else
    let request = notify_body t notif in
    try
      let response =
        Http_client.do_request_to_buffer t.net t.url request ~timeout:30.0
      in
      capture_session_id t response.Http_client.headers;
      if response.Http_client.status >= 400 then
        Error (Types.Internal
                 (Printf.sprintf "MCP HTTP notification error status %d"
                    response.Http_client.status))
      else Ok ()
    with
    | Failure msg when
        (try ignore (Str.search_forward (Str.regexp "timed out") msg 0); true
         with Not_found -> false) ->
      Error Types.Timeout
    | ex ->
      Error
        (Types.Internal
           (Printf.sprintf "MCP HTTP POST failed: %s" (Printexc.to_string ex)))

let close t = t.closed <- true

let to_transport (t : t) : Mcp_transport.t = {
  request_response = request_response t;
  notify = notify t;
  close = (fun () -> close t);
  set_sampling_handler = (fun handler -> set_sampling_handler t handler);
}
