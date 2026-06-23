(* test/test_http_timeout.ml — verifies Http_client.with_timeout_for cancels
   stuck HTTP requests in MCP transport and fetch_url builtin tool.

   Strategy: bind a TCP listener on a random local port that accepts the
   connection but never sends a response. The client side (MCP transport /
   fetch_url) should hit its configured timeout and surface [Types.Timeout]
   (or "timed out" in the error message for fetch_url) within the timeout
   window plus a small grace period. *)

open Par
open Types

let show_ec (ec : Types.error_category) = match ec with
  | Timeout -> "Timeout"
  | Invalid_input s -> "Invalid_input(" ^ s ^ ")"
  | External_failure s -> "External_failure(" ^ s ^ ")"
  | Rate_limited -> "Rate_limited"
  | Permission_denied s -> "Permission_denied(" ^ s ^ ")"
  | Internal s -> "Internal(" ^ s ^ ")"
  | Embedding_unsupported -> "Embedding_unsupported"


(* -------------------------------------------------------------------------- *)
(* Hanging server: accepts a connection, then idles until the client times out.
   Bound to 127.0.0.1:0 so we get a free port. *)
(* -------------------------------------------------------------------------- *)

let with_hanging_server env f =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  let server = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:5 addr in
  let port =
    match Eio.Net.listening_addr server with
    | `Tcp (_, p) -> p
    | _ -> failwith "expected TCP listening address"
  in
  let url = Printf.sprintf "http://127.0.0.1:%d/" port in
  Eio.Fiber.fork ~sw (fun () ->
    try
      while true do
        let _flow =
          Eio.Net.accept server
        in
        (* Deliberately do nothing — keep the connection open without
           sending a response so the client hits its timeout. *)
        Eio.Time.sleep (Eio.Stdenv.clock env) 60.0
      done
    with _ -> ());
  f url

(* -------------------------------------------------------------------------- *)
(* fetch_url: assert it returns an error containing "timed out" within the
   configured 15s + 2s grace. *)
(* -------------------------------------------------------------------------- *)

let test_fetch_url_times_out () =
  Eio_main.run @@ fun env ->
  Http_client.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun _sw ->
  with_hanging_server env (fun url ->
    let tools : Types.tool_binding list =
      Builtin_tools.builtin_tools ~switch:(Eio.Switch.run @@ fun sw -> sw) ~net:(Eio.Stdenv.net env)
    in
    let token = Eio.Switch.run @@ fun sw -> Cancellation.create_token sw in
    let find_tool name (tools : Types.tool_binding list) =
      List.find (fun (tb : Types.tool_binding) -> tb.descriptor.name = name) tools
    in
    let t0 = Unix.gettimeofday () in
    let tool = find_tool "fetch_url" tools in
    let result = tool.handler (`Assoc [("url", `String url)]) token in
    let elapsed = Unix.gettimeofday () -. t0 in
    match result with
    | Error { message; _ } ->
      let ok_message = String.contains message 't' && String.contains message 'i'
                        && String.contains message 'm' && String.contains message 'e'
                        && String.contains message 'd'
      in
      if not ok_message then
        Alcotest.failf
          "fetch_url did not produce a 'timed out' error; got: %s"
          message
      else if elapsed > 17.0 then
        Alcotest.failf
          "fetch_url took %.2fs — expected <= 17s (15s timeout + 2s grace)"
          elapsed
      else
        Alcotest.(check bool) "error category or message" true true
    | Success _ ->
      Alcotest.fail "fetch_url succeeded against a hanging server"
    | Handoff _ ->
      Alcotest.fail "fetch_url returned Handoff against a hanging server")

(* -------------------------------------------------------------------------- *)
(* MCP HTTP transport: assert request_response returns Types.Timeout against
   a hanging server, within 30s + 2s grace. *)
(* -------------------------------------------------------------------------- *)

let test_mcp_transport_request_times_out () =
  Eio_main.run @@ fun env ->
  Http_client.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  with_hanging_server env (fun url ->
    let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
    let transport = Mcp_transport_http.create ~url ~net ~sw in
    let req : Mcp_types.jsonrpc_request =
      { id = Mcp_types.Int_id 1
      ; method_ = "tools/list"
      ; params = Some (`Assoc [])
      }
    in
    let t0 = Unix.gettimeofday () in
    let result = Mcp_transport_http.request_response transport req in
    let elapsed = Unix.gettimeofday () -. t0 in
    match result with
    | Error Timeout ->
      if elapsed > 32.0 then
        Alcotest.failf
          "MCP request_response took %.2fs — expected <= 32s (30s timeout + 2s grace)"
          elapsed
      else
        Alcotest.(check bool) "is Timeout" true true
    | Error other ->
      Alcotest.failf
        "expected Error Timeout, got %s"
        (show_ec other)
    | Ok _ ->
      Alcotest.fail "MCP request_response succeeded against a hanging server")

(* -------------------------------------------------------------------------- *)
(* MCP HTTP transport: assert notify returns Types.Timeout against a hanging
   server. *)
(* -------------------------------------------------------------------------- *)

let test_mcp_transport_notify_times_out () =
  Eio_main.run @@ fun env ->
  Http_client.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  with_hanging_server env (fun url ->
    let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
    let transport = Mcp_transport_http.create ~url ~net ~sw in
    let notif : Mcp_types.jsonrpc_notification =
      { method_ = "notifications/initialized"
      ; params = Some (`Assoc [])
      }
    in
    let t0 = Unix.gettimeofday () in
    let result = Mcp_transport_http.notify transport notif in
    let elapsed = Unix.gettimeofday () -. t0 in
    match result with
    | Error Timeout ->
      if elapsed > 32.0 then
        Alcotest.failf
          "MCP notify took %.2fs — expected <= 32s (30s timeout + 2s grace)"
          elapsed
      else
        Alcotest.(check bool) "is Timeout" true true
    | Error other ->
      Alcotest.failf
        "expected Error Timeout, got %s"
        (show_ec other)
    | Ok () ->
      Alcotest.fail "MCP notify succeeded against a hanging server")

let () =
  Logs.set_level (Some Logs.Warning) |> ignore;
  Alcotest.run "HTTP timeout (MCP + fetch_url)" [
    "fetch_url", [
      Alcotest.test_case "15s timeout fires against hanging server"
        `Slow
        test_fetch_url_times_out;
    ];
    "mcp_transport_http", [
      Alcotest.test_case "request_response 30s timeout fires"
        `Slow
        test_mcp_transport_request_times_out;
      Alcotest.test_case "notify 30s timeout fires"
        `Slow
        test_mcp_transport_notify_times_out;
    ];
  ]
