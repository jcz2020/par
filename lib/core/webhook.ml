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
    let clock = Http_timeout.get_clock () in
    let result =
      Eio.Fiber.first
        (fun () ->
          `Ok (Eio.Switch.run (fun sw ->
            let client = Cohttp_eio.Client.make ~https:None net in
            let headers = Cohttp.Header.of_list [
              ("Content-Type", "application/json");
              ("X-PAR-Signature", Printf.sprintf "sha256=%s" signature);
              ("Content-Length", string_of_int (String.length body_str));
            ] in
            let body = Cohttp_eio.Body.of_string body_str in
            let resp, resp_body = Cohttp_eio.Client.call ~sw
              ~headers ~body client `POST uri in
            let status_code = Cohttp.Code.code_of_status
              (Http.Response.status resp) in
            let resp_str =
              Eio.Buf_read.parse_exn ~max_size:(1024 * 1024)
                Eio.Buf_read.take_all resp_body in
            (status_code, resp_str))))
        (fun () ->
          Eio.Time.sleep clock timeout_sec;
          `Timeout)
    in
    match result with
    | `Timeout -> Approval.Timeout
    | `Ok (status_code, resp_str) ->
      if status_code = 200 then
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
