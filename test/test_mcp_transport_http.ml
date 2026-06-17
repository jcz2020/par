open Par

let () =
  Alcotest.run "mcp_transport_http" [
    "request_id_matching", [
      Alcotest.test_case "int_id_match" `Quick (fun () ->
        Alcotest.(check bool) "same int ids match"
          true (Mcp_types.request_id_matches (Mcp_types.Int_id 42) (Mcp_types.Int_id 42)));

      Alcotest.test_case "int_id_mismatch" `Quick (fun () ->
        Alcotest.(check bool) "different int ids don't match"
          false (Mcp_types.request_id_matches (Mcp_types.Int_id 1) (Mcp_types.Int_id 2)));

      Alcotest.test_case "string_id_match" `Quick (fun () ->
        Alcotest.(check bool) "same string ids match"
          true (Mcp_types.request_id_matches (Mcp_types.String_id "abc") (Mcp_types.String_id "abc")));

      Alcotest.test_case "string_vs_int_mismatch" `Quick (fun () ->
        Alcotest.(check bool) "string vs int don't match"
          false (Mcp_types.request_id_matches (Mcp_types.String_id "1") (Mcp_types.Int_id 1)));
    ];

    "server_config_variants", [
      Alcotest.test_case "stdio_server_config" `Quick (fun () ->
        let cfg = Mcp_types.Stdio_server {
          name = "test-stdio";
          command = "echo"; args = []; env = []; cwd = None; startup_timeout = 5.0
        } in
        Alcotest.(check string) "name accessor" "test-stdio" (Mcp_types.server_name cfg));

      Alcotest.test_case "http_server_config" `Quick (fun () ->
        let cfg = Mcp_types.Http_server {
          name = "test-http"; url = "https://example.com/mcp";
          headers = []; startup_timeout = 10.0
        } in
        Alcotest.(check string) "name accessor" "test-http" (Mcp_types.server_name cfg);
        Alcotest.(check (float 0.001)) "timeout" 10.0 (Mcp_types.server_startup_timeout cfg));

      Alcotest.test_case "http_server_yojson_roundtrip" `Quick (fun () ->
        let cfg = Mcp_types.Http_server {
          name = "rt"; url = "https://mcp.example.com/endpoint";
          headers = [("Authorization", "Bearer xyz")]; startup_timeout = 30.0
        } in
        let json = Mcp_types.server_config_to_yojson cfg in
        (match Mcp_types.server_config_of_yojson json with
         | Ok (Mcp_types.Http_server parsed) ->
           Alcotest.(check string) "url roundtrip" "https://mcp.example.com/endpoint" parsed.url
         | _ -> Alcotest.fail "expected Http_server after roundtrip"));
    ];
  ]
