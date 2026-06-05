open Par
open Types

let check_event_roundtrip (label : string) (ev : event) =
  let json = event_to_yojson ev in
  match event_of_yojson json with
  | Ok ev' ->
    let json' = event_to_yojson ev' in
    Alcotest.check Alcotest.bool label true (Yojson.Safe.equal json json')
  | Error msg ->
    Alcotest.check Alcotest.bool label false true;
    Printf.eprintf "Round-trip failed for %s: %s\n" label msg

let () =
  Alcotest.run "MCP Events" [
    "mcp_server_started", [Alcotest.test_case "roundtrip" `Quick (fun () ->
      check_event_roundtrip "Mcp_server_started"
        (Mcp_server_started { server_id = "srv1"; server_name = "alpha" }))];
    "mcp_server_failed", [Alcotest.test_case "roundtrip" `Quick (fun () ->
      check_event_roundtrip "Mcp_server_failed"
        (Mcp_server_failed { server_id = "srv2"; error = Timeout }))];
    "mcp_server_stopped", [Alcotest.test_case "roundtrip" `Quick (fun () ->
      check_event_roundtrip "Mcp_server_stopped"
        (Mcp_server_stopped { server_id = "srv1" }))];
    "mcp_tool_invoked", [Alcotest.test_case "roundtrip" `Quick (fun () ->
      check_event_roundtrip "Mcp_tool_invoked"
        (Mcp_tool_invoked { server_id = "srv1"; tool_name = "echo" }))];
    "mcp_tool_completed", [Alcotest.test_case "roundtrip" `Quick (fun () ->
      check_event_roundtrip "Mcp_tool_completed"
        (Mcp_tool_completed { server_id = "srv1"; tool_name = "echo"; duration_ms = 42.5 }))];
    "mcp_resource_read", [Alcotest.test_case "roundtrip" `Quick (fun () ->
      check_event_roundtrip "Mcp_resource_read"
        (Mcp_resource_read { server_id = "srv1"; uri = "file:///tmp/a.txt" }))];
    "mcp_prompt_rendered", [Alcotest.test_case "roundtrip" `Quick (fun () ->
      check_event_roundtrip "Mcp_prompt_rendered"
        (Mcp_prompt_rendered { server_id = "srv1"; prompt_name = "greeting" }))];
  ]
