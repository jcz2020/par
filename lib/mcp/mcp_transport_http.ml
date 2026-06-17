(* lib/mcp/mcp_transport_http.ml
   v0.4.4 W1 — MCP HTTP/SSE transport (MCP spec §4.1, 2025-06-18).

   POSTs JSON-RPC messages to a single endpoint URL.  The server may reply with
   a direct JSON response or an SSE stream; both are handled.  Session ids are
   captured from the [Mcp-Session-Id] response header and echoed back on later
   requests. *)

[@@@warning "-32-34-37"]

let max_body_size = 10 * 1024 * 1024
let session_id_header = "mcp-session-id"

type t = {
  uri : Uri.t;
  session_id : string option ref;
  client : Cohttp_eio.Client.t;
  sw : Eio.Switch.t;
  mutable closed : bool;
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

let tls_host_of_string host =
  match Domain_name.of_string host with
  | Error _ -> None
  | Ok dn -> (match Domain_name.host dn with Ok h -> Some h | Error _ -> None)

let upgrade_https uri flow =
  let cfg = Lazy.force tls_config_lazy in
  match Uri.host uri with
  | Some h ->
    (match tls_host_of_string h with
     | Some dh -> Tls_eio.client_of_flow cfg ~host:dh flow
     | None -> failwith ("Cannot parse hostname for TLS SNI: " ^ h))
  | None -> failwith "No host in URL for TLS connection"

let create ~url ~net ~sw =
  let uri = Uri.of_string url in
  let client = Cohttp_eio.Client.make ~https:(Some upgrade_https) net in
  { uri; session_id = ref None; client; sw; closed = false }

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

let http_status resp = Cohttp.Code.code_of_status resp.Http.Response.status

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

let parse_sse_response _t ~target_id body =
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
               (match Mcp_types.notification_of_yojson json with
                | Ok _ -> read_events ()
                | Error e ->
                  Logs.debug (fun m ->
                    m "mcp_transport_http: skipping unknown SSE message: %s" e);
                  read_events ()))
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
    let body = Cohttp_eio.Body.of_string body_str in
    let headers = build_headers t [] in
    try
      let resp, resp_body =
        Cohttp_eio.Client.post t.client ~sw:t.sw ~headers ~body t.uri
      in
      capture_session_id t resp;
      let status = http_status resp in
      if Cohttp.Code.is_error status then
        Error (Types.Internal (Printf.sprintf "MCP HTTP error status %d" status))
      else if status = 202 then
        Error (Types.Internal "MCP HTTP request received 202 (expected response)")
      else if content_type_is resp "application/json" then
        match read_body_string resp_body with
        | Error _ as e -> e
        | Ok s ->
          (match parse_response_json s with
           | Error _ as e -> e
           | Ok r ->
             if Mcp_types.request_id_matches r.Mcp_types.id req.Mcp_types.id then Ok r
             else Error (Types.Internal "MCP HTTP response id mismatch"))
      else if content_type_is resp "text/event-stream" then
        (match req.Mcp_types.id with
         | Mcp_types.Int_id target_id -> parse_sse_response t ~target_id resp_body
         | Mcp_types.String_id _ ->
           Error (Types.Invalid_input "MCP HTTP SSE response matching requires int id"))
      else
        Error (Types.Internal "MCP HTTP unexpected response content-type")
    with ex ->
      Error
        (Types.Internal
           (Printf.sprintf "MCP HTTP POST failed: %s" (Printexc.to_string ex)))

let drain_body body =
  try
    ignore
      (Eio.Buf_read.parse_exn ~max_size:max_body_size Eio.Buf_read.take_all body)
  with _ -> ()

let notify t notif =
  if t.closed then Error (Types.Internal "transport closed")
  else
    let body_str = Yojson.Safe.to_string (Mcp_types.notification_to_yojson notif) in
    let body = Cohttp_eio.Body.of_string body_str in
    let headers = build_headers t [] in
    try
      let resp, resp_body =
        Cohttp_eio.Client.post t.client ~sw:t.sw ~headers ~body t.uri
      in
      capture_session_id t resp;
      let status = http_status resp in
      drain_body resp_body;
      if Cohttp.Code.is_error status then
        Error (Types.Internal (Printf.sprintf "MCP HTTP notification error status %d" status))
      else
        Ok ()
    with ex ->
      Error
        (Types.Internal
           (Printf.sprintf "MCP HTTP POST failed: %s" (Printexc.to_string ex)))

let close t = t.closed <- true

let to_transport (t : t) : Mcp_transport.t = {
  request_response = request_response t;
  notify = notify t;
  close = (fun () -> close t);
}
