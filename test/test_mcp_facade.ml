let () =
  Alcotest.run "MCP Facade" [
    "mcp_types accessible", [Alcotest.test_case "Par.Mcp_types exists" `Quick (fun () ->
      let _ = Par.Mcp_types.protocol_version in
      ())];
    "mcp_server accessible", [Alcotest.test_case "Par.Mcp_server exists" `Quick (fun () ->
      let module M = Par.Mcp_server in
      ())];
    "mcp_client accessible", [Alcotest.test_case "Par.Mcp_client exists" `Quick (fun () ->
      let module M = Par.Mcp_client in
      ())];
  ]
