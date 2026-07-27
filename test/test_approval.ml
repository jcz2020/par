open Par

let test_approved_roundtrip () =
  let json = Approval.outcome_to_json Approval.Approved in
  match Approval.outcome_of_json json with
  | Error msg -> Alcotest.fail msg
  | Ok Approval.Approved -> ()
  | Ok _ -> Alcotest.fail "expected Approved"

let test_rejected_roundtrip () =
  let outcome = Approval.Rejected { reason = "denied by policy" } in
  let json = Approval.outcome_to_json outcome in
  match Approval.outcome_of_json json with
  | Error msg -> Alcotest.fail msg
  | Ok (Approval.Rejected { reason }) ->
    Alcotest.(check string) "reason" "denied by policy" reason
  | Ok _ -> Alcotest.fail "expected Rejected"

let test_modified_roundtrip () =
  let new_input = `Assoc [("key", `String "value"); ("count", `Int 42)] in
  let outcome = Approval.Modified { new_input } in
  let json = Approval.outcome_to_json outcome in
  match Approval.outcome_of_json json with
  | Error msg -> Alcotest.fail msg
  | Ok (Approval.Modified { new_input = ni }) ->
    Alcotest.(check string) "json preserved"
      (Yojson.Safe.to_string new_input)
      (Yojson.Safe.to_string ni)
  | Ok _ -> Alcotest.fail "expected Modified"

let test_escalated_roundtrip () =
  let outcome = Approval.Escalated { target = "senior-approver" } in
  let json = Approval.outcome_to_json outcome in
  match Approval.outcome_of_json json with
  | Error msg -> Alcotest.fail msg
  | Ok (Approval.Escalated { target }) ->
    Alcotest.(check string) "target" "senior-approver" target
  | Ok _ -> Alcotest.fail "expected Escalated"

let test_timeout_roundtrip () =
  let json = Approval.outcome_to_json Approval.Timeout in
  match Approval.outcome_of_json json with
  | Error msg -> Alcotest.fail msg
  | Ok Approval.Timeout -> ()
  | Ok _ -> Alcotest.fail "expected Timeout"

let test_invalid_shape_returns_error () =
  match Approval.outcome_of_json (`Int 42) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error for invalid shape"

let test_unknown_tag_returns_error () =
  match Approval.outcome_of_json (`Assoc [("tag", `String "Unknown")]) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error for unknown tag"

let test_missing_reason_field () =
  match Approval.outcome_of_json (`Assoc [("tag", `String "Rejected")]) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error for missing reason"

let test_sync_local_handler_dispatch () =
  let handler : unit Approval.approval_handler =
    Approval.Sync_local (fun () -> Approval.Approved)
  in
  match handler with
  | Approval.Sync_local f ->
    let result = f () in
    (match result with
     | Approval.Approved -> ()
     | _ -> Alcotest.fail "Sync_local returned wrong outcome")
  | _ -> Alcotest.fail "expected Sync_local"

let test_async_callback_returns_promise () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun _sw ->
      let resolved = ref false in
      let p, r = Eio.Promise.create () in
      let handler : unit Approval.approval_handler =
        Approval.Async_callback (fun () ->
          resolved := true;
          p)
      in
      Eio.Promise.resolve r Approval.Approved;
      (match handler with
       | Approval.Async_callback f ->
         let result_p = f () in
         (match Eio.Promise.await result_p with
          | Approval.Approved ->
            Alcotest.(check bool) "callback was invoked" true !resolved
          | _ -> Alcotest.fail "expected Approved from Async_callback")
       | _ -> Alcotest.fail "expected Async_callback")))

let test_webhook_handler_config () =
  let handler : unit Approval.approval_handler =
    Approval.Webhook {
      url = "https://example.com/approve";
      secret = "hmac-sha256-secret";
      timeout_sec = 120.0;
    }
  in
  match handler with
  | Approval.Webhook { url; secret; timeout_sec } ->
    Alcotest.(check string) "url" "https://example.com/approve" url;
    Alcotest.(check string) "secret" "hmac-sha256-secret" secret;
    Alcotest.(check (float 1e-6)) "timeout_sec" 120.0 timeout_sec
  | _ -> Alcotest.fail "expected Webhook"

let test_default_timeout_is_300 () =
  Alcotest.(check (float 1e-6)) "default_timeout = 300.0"
    300.0 Approval.default_timeout

let test_two_approved_structurally_equal () =
  let ja = Approval.outcome_to_json Approval.Approved in
  let jb = Approval.outcome_to_json Approval.Approved in
  Alcotest.(check string) "Approved = Approved"
    (Yojson.Safe.to_string ja) (Yojson.Safe.to_string jb)

let test_approval_context_construction () =
  let ctx : Types.approval_context = {
    agent_id = "test-agent";
    tool_name = "write_file";
    tool_input = `Assoc [("path", `String "/tmp/test.txt")];
    conversation = { messages = []; metadata = [] };
    pending_action = `String "write";
    metadata = [("risk_level", `String "high"); ("source", `String "user")];
  } in
  Alcotest.(check string) "agent_id" "test-agent" ctx.agent_id;
  Alcotest.(check string) "tool_name" "write_file" ctx.tool_name;
  Alcotest.(check int) "metadata count" 2 (List.length ctx.metadata)

let test_metadata_list_roundtrips () =
  let metadata = [
    ("priority", `String "high");
    ("tags", `List [`String "a"; `String "b"]);
    ("score", `Float 3.14);
  ] in
  let ctx : Types.approval_context = {
    agent_id = "agent";
    tool_name = "tool";
    tool_input = `Null;
    conversation = { messages = []; metadata = [] };
    pending_action = `Null;
    metadata;
  } in
  Alcotest.(check int) "metadata preserved" 3 (List.length ctx.metadata);
  match List.assoc_opt "priority" ctx.metadata with
  | Some (`String s) -> Alcotest.(check string) "priority" "high" s
  | _ -> Alcotest.fail "priority not found or wrong type"

let test_modified_complex_json_preserves () =
  let complex = `Assoc [
    ("nested", `Assoc [("deep", `List [`String "a"; `Int 1])]);
    ("array", `List [`Bool true; `Null]);
    ("number", `Float 2.718);
  ] in
  let outcome = Approval.Modified { new_input = complex } in
  let json = Approval.outcome_to_json outcome in
  match Approval.outcome_of_json json with
  | Error msg -> Alcotest.fail msg
  | Ok (Approval.Modified { new_input }) ->
    Alcotest.(check string) "complex json preserved"
      (Yojson.Safe.to_string complex)
      (Yojson.Safe.to_string new_input)
  | Ok _ -> Alcotest.fail "expected Modified"

let () =
  Alcotest.run "approval" [
    "outcome_roundtrip", [
      Alcotest.test_case "Approved roundtrip" `Quick test_approved_roundtrip;
      Alcotest.test_case "Rejected roundtrip" `Quick test_rejected_roundtrip;
      Alcotest.test_case "Modified roundtrip" `Quick test_modified_roundtrip;
      Alcotest.test_case "Escalated roundtrip" `Quick test_escalated_roundtrip;
      Alcotest.test_case "Timeout roundtrip" `Quick test_timeout_roundtrip;
    ];
    "outcome_error", [
      Alcotest.test_case "invalid shape → Error" `Quick test_invalid_shape_returns_error;
      Alcotest.test_case "unknown tag → Error" `Quick test_unknown_tag_returns_error;
      Alcotest.test_case "missing reason → Error" `Quick test_missing_reason_field;
    ];
    "handler", [
      Alcotest.test_case "Sync_local dispatch" `Quick test_sync_local_handler_dispatch;
      Alcotest.test_case "Async_callback promise" `Quick test_async_callback_returns_promise;
      Alcotest.test_case "Webhook config fields" `Quick test_webhook_handler_config;
    ];
    "constants", [
      Alcotest.test_case "default_timeout = 300.0" `Quick test_default_timeout_is_300;
    ];
    "equality", [
      Alcotest.test_case "two Approved structurally equal" `Quick
        test_two_approved_structurally_equal;
    ];
    "context", [
      Alcotest.test_case "approval_context construction" `Quick
        test_approval_context_construction;
      Alcotest.test_case "metadata list roundtrip" `Quick test_metadata_list_roundtrips;
      Alcotest.test_case "complex JSON preserved" `Quick test_modified_complex_json_preserves;
    ];
  ]
