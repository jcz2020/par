open Types

let hmac_sha256_hex ~(secret : string) (body : string) : string =
  let state = Digestif.SHA256.hmac_init ~key:secret in
  let state = Digestif.SHA256.hmac_feed_string state body in
  let digest = Digestif.SHA256.hmac_get state in
  Digestif.SHA256.to_hex digest

let send_webhook_approval
    ~(net : _ Eio.Net.t)
    ~(url : string)
    ~(secret : string)
    ~(timeout_sec : float)
    ~(ctx : approval_context)
  : Approval.approval_outcome =
  let body_json = `Assoc [
    ("agent_id", `String ctx.agent_id);
    ("tool_name", `String ctx.tool_name);
    ("tool_input", ctx.tool_input);
    ("pending_action", ctx.pending_action);
  ] in
  let body_str = Yojson.Safe.to_string body_json in
  let signature = hmac_sha256_hex ~secret body_str in
  let uri = Uri.of_string url in
  try
    let parsed = Http_client.parsed_url_of_uri uri in
    let request =
      Http_client.build_http_request ~host:parsed.Http_client.host
        ~path:parsed.Http_client.path
        ~headers:[("X-PAR-Signature", Printf.sprintf "sha256=%s" signature)]
        ~body:body_str
    in
    let response =
      Http_client.do_request_to_buffer
        (net :> [ `Generic ] Eio.Net.ty Eio.Net.t)
        parsed request ~timeout:timeout_sec
    in
    let status_code = response.Http_client.status in
    let resp_str = response.Http_client.body in
    if String.length resp_str > 1024 * 1024 then begin
      Logs.warn (fun m -> m "[webhook] response body exceeds 1 MB");
      Approval.Timeout
    end else if status_code = 200 then
      (try
         let json = Yojson.Safe.from_string resp_str in
         match Approval.outcome_of_json json with
         | Ok outcome -> outcome
         | Error msg ->
           Logs.warn (fun m -> m "[webhook] invalid outcome JSON: %s" msg);
           Approval.Timeout
       with _ ->
         Logs.warn (fun m -> m "[webhook] non-JSON 200 response");
         Approval.Timeout)
    else
      Approval.Rejected {
        reason = Printf.sprintf "webhook returned HTTP %d" status_code;
      }
  with
  | Failure msg when
      (try ignore (Str.search_forward (Str.regexp "timed out") msg 0); true
       with Not_found -> false) ->
    Approval.Timeout
  | Eio.Exn.Io _ as exn ->
    Approval.Rejected {
      reason = Printf.sprintf "webhook I/O error: %s"
        (Printexc.to_string exn);
    }
  | exn ->
    Approval.Rejected {
      reason = Printf.sprintf "webhook error: %s"
        (Printexc.to_string exn);
    }
