(* test/test_mcp_transport_stdio.ml — v0.3.1 W2 Mcp_transport_stdio unit tests.
   Tests use [T.Test.pair] for in-memory duplex pipes (no real process spawn).
   Frame injection via [T.Test.write_raw] simulates server-side writes.

   IMPORTANT: The transport's [recv_message] returns [`Response | `Notification]
   only — it does NOT return [`Request]. So tests that simulate a client
   sending a request must NOT try to recv_message on the server side.
   Instead, tests inject server-side frames via [write_raw] and recv_message
   on the client. This matches the v0.3.1 design (no bidirectional RPC). *)

open Par
module T = Par__Mcp_transport_stdio
module MT = Par__Mcp_types

let () = Logs.set_level (Some Logs.Warning) |> ignore

let string_of_error_category (ec : Types.error_category) =
  match ec with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid_input(%s)" s
  | Types.External_failure s -> Printf.sprintf "External_failure(%s)" s
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission_denied(%s)" s
  | Types.Internal s -> Printf.sprintf "Internal(%s)" s
  | Types.Embedding_unsupported -> "Embedding_unsupported"

let error_category_pp fmt ec =
  Format.pp_print_string fmt (string_of_error_category ec)

let error_category_testable = Alcotest.testable error_category_pp (=)

(* ---------- Fixture data ---------- *)

let req_int : MT.jsonrpc_request = {
  id = MT.Int_id 1;
  method_ = "tools/list";
  params = None;
}

let req_str : MT.jsonrpc_request = {
  id = MT.String_id "abc";
  method_ = "tools/list";
  params = Some (`Assoc []);
}

let notif_cancelled : MT.jsonrpc_notification = {
  method_ = MT.method_cancelled;
  params = Some (`Assoc ["requestId", `Int 99]);
}

let response_ok : MT.jsonrpc_response = {
  id = MT.Int_id 1;
  result = Ok (`Assoc ["tools", `List []]);
}

let response_err : MT.jsonrpc_response = {
  id = MT.String_id "x";
  result = Error { code = -32601; message = "Method not found"; data = None };
}

let notification_progress : MT.jsonrpc_notification = {
  method_ = MT.method_progress;
  params = Some (`Assoc ["progress", `Int 50; "total", `Int 100]);
}

let response_to_json r = Yojson.Safe.to_string (MT.jsonrpc_response_to_yojson r)
let notif_to_json n = Yojson.Safe.to_string (MT.notification_to_yojson n)

(* ---------- Substring helper ---------- *)

let contains_substring ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then true
  else if nlen > hlen then false
  else
    let rec loop i =
      if i > hlen - nlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

(* ============================================================ *)
(* SEND tests (5) — verify sending doesn't error                  *)
(* ============================================================ *)

let test_send_request_int_id_ok () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, _server = T.Test.pair ~sw ~mgr () in
  Alcotest.(check (result unit error_category_testable))
    "send int_id request" (Ok ()) (T.send_request client req_int)

let test_send_request_string_id_ok () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, _ = T.Test.pair ~sw ~mgr () in
  Alcotest.(check (result unit error_category_testable))
    "send string_id request" (Ok ()) (T.send_request client req_str)

let test_send_notification_ok () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, _ = T.Test.pair ~sw ~mgr () in
  Alcotest.(check (result unit error_category_testable))
    "send notification" (Ok ()) (T.send_notification client notif_cancelled)

let test_send_two_distinct_ids_ok () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, _ = T.Test.pair ~sw ~mgr () in
  Alcotest.(check (result unit error_category_testable))
    "send 1" (Ok ()) (T.send_request client req_int);
  Alcotest.(check (result unit error_category_testable))
    "send 2" (Ok ()) (T.send_request client req_str)

let test_send_large_payload_ok () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, _ = T.Test.pair ~sw ~mgr () in
  let big_str = String.make 10_000 'A' in
  let big : MT.jsonrpc_request = {
    id = MT.Int_id 99;
    method_ = "test/big";
    params = Some (`Assoc ["data", `String big_str]);
  } in
  Alcotest.(check (result unit error_category_testable))
    "send large" (Ok ()) (T.send_request client big)

(* ============================================================ *)
(* RECV tests (4) — use write_raw to inject server-side frames   *)
(* Note: write_raw on side X writes to X's sink; recv on side Y  *)
(* reads from Y's source. For Test.pair, write_raw server + recv  *)
(* client (or vice versa) routes data correctly.                  *)
(* ============================================================ *)

let test_recv_response_with_result_ok () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server ((response_to_json response_ok) ^ "\n");
  match T.recv_message client with
  | Ok (`Response r) ->
    (match r.id with MT.Int_id 1 -> () | _ -> Alcotest.fail "expected Int_id 1");
    (match r.result with Ok _ -> () | Error _ -> Alcotest.fail "expected Ok result")
  | Ok `Notification _ -> Alcotest.fail "expected Response, got Notification"
  | Error e -> Alcotest.failf "recv failed: %s" (string_of_error_category e)

let test_recv_response_with_error () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server ((response_to_json response_err) ^ "\n");
  match T.recv_message client with
  | Ok (`Response r) ->
    (match r.id with MT.String_id "x" -> () | _ -> Alcotest.fail "expected String_id x");
    (match r.result with
     | Ok _ -> Alcotest.fail "expected Error result"
     | Error err -> Alcotest.(check int) "code" (-32601) err.code)
  | _ -> Alcotest.fail "expected Response"

let test_recv_notification () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server ((notif_to_json notif_cancelled) ^ "\n");
  match T.recv_message client with
  | Ok (`Notification n) ->
    Alcotest.(check string) "method" MT.method_cancelled n.method_
  | _ -> Alcotest.fail "expected Notification"

let test_recv_progress_notification () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server ((notif_to_json notification_progress) ^ "\n");
  match T.recv_message client with
  | Ok (`Notification n) ->
    Alcotest.(check string) "method" MT.method_progress n.method_
  | _ -> Alcotest.fail "expected Notification"

(* ============================================================ *)
(* FRAME-SKIP tests (5) — verify non-JSON / comment lines skipped *)
(* ============================================================ *)

let test_skips_comment_line () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server "# this is a comment\n";
  T.Test.write_raw server ((response_to_json response_ok) ^ "\n");
  match T.recv_message client with
  | Ok (`Response _) -> ()
  | _ -> Alcotest.fail "expected Response after comment line"

let test_skips_garbage_line () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server "not json at all\n";
  T.Test.write_raw server ((response_to_json response_ok) ^ "\n");
  match T.recv_message client with
  | Ok (`Response _) -> ()
  | _ -> Alcotest.fail "expected Response after garbage line"

let test_skips_missing_method () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server "{\"missing\":\"id\"}\n";
  T.Test.write_raw server ((notif_to_json notif_cancelled) ^ "\n");
  match T.recv_message client with
  | Ok (`Notification _) -> ()
  | _ -> Alcotest.fail "expected Notification after missing-fields line"

let test_skips_multiple_garbage_lines () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server "not json\n";
  T.Test.write_raw server "# comment\n";
  T.Test.write_raw server "{\"id\":1}\n";
  T.Test.write_raw server ((response_to_json response_ok) ^ "\n");
  match T.recv_message client with
  | Ok (`Response _) -> ()
  | _ -> Alcotest.fail "expected Response after multi-garbage"

let test_rejects_request_from_server () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server "{\"id\":99,\"method\":\"sampling/createMessage\"}\n";
  T.Test.write_raw server ((response_to_json response_ok) ^ "\n");
  match T.recv_message client with
  | Ok (`Response _) -> ()
  | _ -> Alcotest.fail "expected Response after unsupported request"

(* ============================================================ *)
(* \r stripping tests (2)                                          *)
(* ============================================================ *)

let test_cr_lf_terminator () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server ((response_to_json response_ok) ^ "\r\n");
  match T.recv_message client with
  | Ok (`Response _) -> ()
  | _ -> Alcotest.fail "expected Response with CRLF terminator"

let test_mixed_crlf_and_lf () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw server ((notif_to_json notif_cancelled) ^ "\r\n");
  T.Test.write_raw server ((response_to_json response_ok) ^ "\n");
  let _ = T.recv_message client in
  match T.recv_message client with
  | Ok (`Response _) -> ()
  | _ -> Alcotest.fail "expected second message (LF) after CRLF message"

(* ============================================================ *)
(* CONCURRENT SEND tests (2)                                       *)
(* ============================================================ *)

let test_concurrent_sends_100 () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, _ = T.Test.pair ~sw ~mgr () in
  List.iter (fun i ->
    let r : MT.jsonrpc_request = { id = MT.Int_id i; method_ = "test"; params = None } in
    Eio.Fiber.fork ~sw (fun () ->
      match T.send_request client r with
      | Ok () -> ()
      | Error _ -> Alcotest.failf "concurrent send %d failed" i)
  ) (List.init 100 Fun.id)

let test_concurrent_mixed_request_notification () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, _ = T.Test.pair ~sw ~mgr () in
  List.iter (fun i ->
    let r : MT.jsonrpc_request = { id = MT.Int_id i; method_ = "test"; params = None } in
    Eio.Fiber.fork ~sw (fun () ->
      match T.send_request client r with Ok () -> () | Error _ -> Alcotest.fail "request failed")
  ) (List.init 50 Fun.id);
  List.iter (fun _ ->
    Eio.Fiber.fork ~sw (fun () ->
      match T.send_notification client notif_cancelled with
      | Ok () -> () | Error _ -> Alcotest.fail "notif failed")
  ) (List.init 50 Fun.id)

(* ============================================================ *)
(* MAX SIZE tests (2)                                               *)
(* ============================================================ *)

let test_oversized_rejected () =
  Eio_main.run @@ fun _env ->
  let mgr = Eio.Stdenv.process_mgr _env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  Eio.Fiber.fork ~sw (fun () -> let _ = T.recv_message client in ());
  let too_big = String.make 1_048_577 'A' in
  T.Test.write_raw server too_big;
  T.Test.write_raw server "\n"

let test_exact_1mb_succeeds () =
  Eio_main.run @@ fun _env ->
  let mgr = Eio.Stdenv.process_mgr _env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  Eio.Fiber.fork ~sw (fun () -> let _ = T.recv_message client in ());
  let exact = String.make 1_048_576 'A' in
  T.Test.write_raw server exact;
  T.Test.write_raw server "\n"

(* ============================================================ *)
(* CLOSE semantics tests (2)                                       *)
(* ============================================================ *)

let test_send_after_close_errors () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, _ = T.Test.pair ~sw ~mgr () in
  T.close client;
  match T.send_request client req_int with
  | Error (Types.External_failure s) ->
    if not (contains_substring ~needle:"closed" s) then
      Alcotest.failf "expected 'closed' in: %s" s
  | _ -> Alcotest.fail "expected External_failure after close"

let test_double_close_idempotent () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, _ = T.Test.pair ~sw ~mgr () in
  T.close client;
  T.close client

(* ============================================================ *)
(* EOF tests (2)                                                    *)
(* ============================================================ *)

let test_eof_when_write_end_closed () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.close client;
  match T.recv_message server with
  | Error (Types.External_failure s) ->
    if not (contains_substring ~needle:"closed connection" s) then
      Alcotest.failf "expected 'closed connection' in: %s" s
  | Error e ->
    Alcotest.failf "expected External_failure, got %s" (string_of_error_category e)
  | Ok _ -> Alcotest.fail "expected EOF error"

let test_eof_after_partial_line () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  Eio.Switch.run @@ fun sw ->
  let client, server = T.Test.pair ~sw ~mgr () in
  T.Test.write_raw client "{\"id\":1";
  T.close client;
  match T.recv_message server with
  | Error (Types.External_failure _) -> ()
  | Error e ->
    Alcotest.failf "expected External_failure, got %s" (string_of_error_category e)
  | Ok _ -> Alcotest.fail "expected EOF error"

(* ============================================================ *)
(* default_child_env tests (2)                                     *)
(* ============================================================ *)

let test_default_env_keys_in_whitelist () =
  let env = T.default_child_env () in
  let names = List.map fst env in
  List.iter (fun name ->
    let allowed = List.mem name ["HOME"; "LOGNAME"; "PATH"; "SHELL"; "TERM"; "USER"] in
    Alcotest.(check bool) (Printf.sprintf "key %s in whitelist" name) true allowed)
    names

let test_default_env_excludes_secrets () =
  let env = T.default_child_env () in
  let names = List.map fst env in
  let forbidden = ["AWS_SECRET_KEY"; "AWS_ACCESS_KEY_ID"; "GITHUB_TOKEN"; "API_KEY"] in
  List.iter (fun name ->
    List.iter (fun f ->
      Alcotest.(check bool) (Printf.sprintf "no %s" f) false (String.equal name f))
      forbidden)
    names

(* ============================================================ *)
(* Main                                                             *)
(* ============================================================ *)

let () =
  let open Alcotest in
  run "mcp_transport_stdio" [
    "send", [
      test_case "request int_id"        `Quick test_send_request_int_id_ok;
      test_case "request string_id"     `Quick test_send_request_string_id_ok;
      test_case "notification"          `Quick test_send_notification_ok;
      test_case "two distinct ids"      `Quick test_send_two_distinct_ids_ok;
      test_case "large payload"         `Quick test_send_large_payload_ok;
    ];
    "recv", [
      test_case "response Ok"           `Quick test_recv_response_with_result_ok;
      test_case "response Error"        `Quick test_recv_response_with_error;
      test_case "notification"          `Quick test_recv_notification;
      test_case "progress notification" `Quick test_recv_progress_notification;
    ];
    "frame_skip", [
      test_case "skips # comment"       `Quick test_skips_comment_line;
      test_case "skips garbage"         `Quick test_skips_garbage_line;
      test_case "skips missing fields"  `Quick test_skips_missing_method;
      test_case "multi-garbage mix"     `Quick test_skips_multiple_garbage_lines;
      test_case "rejects server req"    `Quick test_rejects_request_from_server;
    ];
    "cr_stripping", [
      test_case "single CRLF"           `Quick test_cr_lf_terminator;
      test_case "mixed CRLF and LF"     `Quick test_mixed_crlf_and_lf;
    ];
    "concurrent_send", [
      test_case "100 fibers"            `Quick test_concurrent_sends_100;
      test_case "50 req + 50 notif"     `Quick test_concurrent_mixed_request_notification;
    ];
    "max_size", [
      test_case "1MB+1 rejected"        `Quick test_oversized_rejected;
      test_case "1MB exact"             `Quick test_exact_1mb_succeeds;
    ];
    "close_semantics", [
      test_case "send after close"      `Quick test_send_after_close_errors;
      test_case "double close"          `Quick test_double_close_idempotent;
    ];
    "eof", [
      test_case "EOF when closed"       `Quick test_eof_when_write_end_closed;
      test_case "partial line + close"  `Quick test_eof_after_partial_line;
    ];
    "default_child_env", [
      test_case "keys in whitelist"     `Quick test_default_env_keys_in_whitelist;
      test_case "excludes secrets"      `Quick test_default_env_excludes_secrets;
    ];
  ]
