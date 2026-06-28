(* lib/mcp/mcp_transport_http.ml
   v0.4.4 W1 — MCP HTTP/SSE transport (MCP spec §4.1, 2025-06-18).

   POSTs JSON-RPC messages to a single endpoint URL.  The server may reply with
   a direct JSON response or an SSE stream; both are handled.  Session ids are
   captured from the [Mcp-Session-Id] response header and echoed back on later
   requests. *)

[@@@warning "-32-34-37-69"]

let max_body_size = 10 * 1024 * 1024
let session_id_header = "mcp-session-id"

type t = {
  uri : Uri.t;
  session_id : string option ref;
  client : Cohttp_eio.Client.t;
  net_obj : Obj.t;
  sw : Eio.Switch.t;
  mutable closed : bool;
  sampling_handler : (Yojson.Safe.t -> (Yojson.Safe.t, Types.error_category) result) option ref;
}

let tls_config_lazy : Tls.Config.client Lazy.t =
  lazy
    (let authenticator =
       match Ca_certs.authenticator () with
       | Ok auth -> auth
       | Error (`Msg msg) ->
         Logs.warn (fun m ->
           m "mcp_transport_http: failed to load CA certs: %s; TLS validation disabled" msg);
         (fun ?ip:_ ~host:_ _certs -> Ok None)
     in
     match Tls.Config.client ~authenticator () with
     | Ok cfg -> cfg
     | Result.Error (`Msg msg) -> failwith ("TLS configuration error: " ^ msg))

let tls_hosts_of_string host =
  match Domain_name.of_string host with
  | Error _ -> None
  | Ok dn -> (match Domain_name.host dn with Ok h -> Some h | Error _ -> None)

let upgrade_https uri flow =
  let cfg = Lazy.force tls_config_lazy in
  match Uri.host uri with
  | Some h ->
    (match tls_hosts_of_string h with
     | Some dh -> Tls_eio.client_of_flow cfg ~host:dh flow
     | None -> failwith ("Cannot parse hostname for TLS SNI: " ^ h))
  | None -> failwith "No host in URL for TLS connection"

let create ~url ~net ~sw =
  let uri = Uri.of_string url in
  let client = Cohttp_eio.Client.make ~https:(Some upgrade_https) net in
  { uri; session_id = ref None; client; net_obj = Obj.repr net; sw; closed = false; sampling_handler = ref None }

let base_headers () =
  Http.Header.of_list [
    "Content-Type", "application/json";
    "Accept", "application/json, text/event-stream";
  ]

let build_headers t extra =
  let h = Http.Header.add_list (base_headers ()) extra in
  match !(t.session_id) with
  | None -> h
  | Some sid -> Http.Header.add h session_id_header sid

let capture_session_id t resp =
  match Http.Header.get resp.Http.Response.headers session_id_header with
  | Some sid -> t.session_id := Some sid
  | None -> ()

let capture_session_id_from_str t hdr_str =
  String.split_on_char '\n' hdr_str
  |> List.map String.lowercase_ascii
  |> List.iter (fun line ->
    if String.length line > String.length session_id_header + 1
       && String.sub line 0 (String.length session_id_header) = session_id_header
    then begin
      let sid_pos = String.length session_id_header + 1 in
      t.session_id := Some (String.trim (String.sub line sid_pos (String.length line - sid_pos)))
    end)

let raw_post t body_str =
  let host = match Uri.host t.uri with Some h -> h | None -> "localhost" in
  let port = match Uri.port t.uri with
    | Some p -> p
    | None -> if Uri.scheme t.uri = Some "https" then 443 else 80 in
  let use_tls = Uri.scheme t.uri = Some "https" in
  let path = let p = Uri.path t.uri in if p = "" then "/" else p in
  let headers = Cohttp.Header.to_list (build_headers t []) in
  Http_timeout.request_with_timeout ~timeout:30.0 ~net:(Obj.obj t.net_obj) ~host ~port ~use_tls
    ~method_:"POST" ~path ~request_headers:headers ~request_body:body_str ()

let http_status resp = Cohttp.Code.code_of_status resp.Http.Response.status

let drain_body body =
  try
    ignore
      (Eio.Buf_read.parse_exn ~max_size:max_body_size Eio.Buf_read.take_all body)
  with _ -> ()

let set_sampling_handler t handler =
  t.sampling_handler := Some handler

let post_sampling_response t request_id result_json =
  let resp_body = `Assoc [
    "jsonrpc", `String "2.0";
    "id", (match request_id with
           | Mcp_types.Int_id n -> `Int n
           | Mcp_types.String_id s -> `String s);
    "result", result_json;
  ] in
  let body_str = Yojson.Safe.to_string resp_body in
  let headers = build_headers t [] in
  let _ = (headers, body_str) in
  (try
     let (_status, resp_hdrs, _resp_body) = raw_post t body_str in
     capture_session_id_from_str t resp_hdrs
   with _ -> ())

let read_body_string body : (string, Types.error_category) result =
  try
    let s =
      Eio.Buf_read.parse_exn ~max_size:max_body_size Eio.Buf_read.take_all body
    in
    Ok s
  with ex ->
    Error
      (Types.Internal
         (Printf.sprintf "MCP HTTP body read failed: %s" (Printexc.to_string ex)))

let parse_response_json s =
  match Yojson.Safe.from_string s with
  | exception Yojson.Json_error msg ->
    Error (Types.Invalid_input ("MCP HTTP response is not valid JSON: " ^ msg))
  | json ->
    (match Mcp_types.response_of_yojson json with
     | Ok r -> Ok r
     | Error e -> Error (Types.Invalid_input ("MCP HTTP response is not JSON-RPC: " ^ e)))

let content_type_is resp prefix =
  match Http.Header.get resp.Http.Response.headers "content-type" with
  | None -> false
  | Some ct ->
    let ct = String.lowercase_ascii ct in
    String.length ct >= String.length prefix
    && String.sub ct 0 (String.length prefix) = prefix

let parse_sse_response t ~target_id body =
  let src = (body :> [> Eio.Flow.source_ty ] Eio.Resource.t) in
  let reader = Eio.Buf_read.of_flow ~initial_size:4096 ~max_size:max_body_size src in
  let rec read_events () =
    match Eio.Buf_read.line reader with
    | line ->
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
                     let params = Option.value req.Mcp_types.params ~default:`Null in                     let result = handler params in
                     (match result with
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
    | exception End_of_file ->
      Error (Types.Internal "MCP HTTP SSE stream ended without response")
    | exception Eio.Buf_read.Buffer_limit_exceeded ->
      Error (Types.Invalid_input "MCP HTTP SSE message exceeds size limit")
    | exception ex ->
      Error
        (Types.Internal
           (Printf.sprintf "MCP HTTP SSE read failed: %s" (Printexc.to_string ex)))
  in
  read_events ()

let request_response t req =
  if t.closed then Error (Types.Internal "transport closed")
  else
    let body_str = Yojson.Safe.to_string (Mcp_types.request_to_yojson req) in
    try
      let (status, resp_hdrs, resp_body_str) = raw_post t body_str in
      capture_session_id_from_str t resp_hdrs;
      if status >= 400 then
        Error (Types.Internal (Printf.sprintf "MCP HTTP error status %d" status))
      else if status = 202 then
        Error (Types.Internal "MCP HTTP request received 202 (expected response)")
      else
        match parse_response_json resp_body_str with
        | Error _ as e -> e
        | Ok r ->
          if Mcp_types.request_id_matches r.Mcp_types.id req.Mcp_types.id then Ok r
          else Error (Types.Internal "MCP HTTP response id mismatch")
    with
    | Failure msg when
        (try Str.search_forward (Str.regexp "timed out") msg 0 >= 0 with _ -> false) ->
      Error Types.Timeout
    | ex ->
      Error
        (Types.Internal
           (Printf.sprintf "MCP HTTP POST failed: %s" (Printexc.to_string ex)))

let notify t notif =
  if t.closed then Error (Types.Internal "transport closed")
  else
    let body_str = Yojson.Safe.to_string (Mcp_types.notification_to_yojson notif) in
    try
      let (status, resp_hdrs, _body) = raw_post t body_str in
      capture_session_id_from_str t resp_hdrs;
      if status >= 400 then
        Error (Types.Internal (Printf.sprintf "MCP HTTP notification error status %d" status))
      else
        Ok ()
    with
    | Failure msg when
        (try Str.search_forward (Str.regexp "timed out") msg 0 >= 0 with _ -> false) ->
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
}
