open Par

let () =
  Alcotest.run "mcp_sampling" [
    "sampling_constants", [
      Alcotest.test_case "method_sampling_create_name" `Quick (fun () ->
        Alcotest.(check string) "method name"
          "sampling/createMessage" Mcp_types.method_sampling_create);
    ];

    "sampling_request_roundtrip", [
      Alcotest.test_case "full_sampling_request_parses" `Quick (fun () ->
        let json = `Assoc [
          ("jsonrpc", `String "2.0");
          ("id", `Int 99);
          ("method", `String Mcp_types.method_sampling_create);
          ("params", `Assoc [
            ("messages", `List [
              `Assoc [("role", `String "user");
                      ("content", `Assoc [("type", `String "text"); ("text", `String "Summarize this")])];
            ]);
            ("maxTokens", `Int 500);
            ("systemPrompt", `String "You are a helpful assistant");
            ("temperature", `Float 0.7);
          ])
        ] in
        (match Mcp_types.jsonrpc_request_of_yojson json with
         | Ok req ->
           Alcotest.(check string) "method" Mcp_types.method_sampling_create req.Mcp_types.method_;
           Alcotest.(check bool) "has params" true (Option.is_some req.Mcp_types.params);
           (match req.Mcp_types.params with
            | Some (`Assoc params) ->
              (match List.assoc_opt "maxTokens" params with
               | Some (`Int 500) -> ()
               | _ -> Alcotest.fail "maxTokens not parsed correctly");
              (match List.assoc_opt "temperature" params with
               | Some (`Float f) -> Alcotest.(check (float 0.001)) "temperature" 0.7 f
               | _ -> Alcotest.fail "temperature not parsed")
            | _ -> Alcotest.fail "params not an object")
         | Error e -> Alcotest.fail ("parse failed: " ^ e)));

      Alcotest.test_case "sampling_request_serializes" `Quick (fun () ->
        let req : Mcp_types.jsonrpc_request = {
          id = Mcp_types.Int_id 7;
          method_ = Mcp_types.method_sampling_create;
          params = Some (`Assoc [
            ("maxTokens", `Int 100);
            ("messages", `List []);
          ]);
        } in
        let json = Mcp_types.request_to_yojson req in
        (match Mcp_types.jsonrpc_request_of_yojson json with
         | Ok parsed ->
           Alcotest.(check string) "roundtrip method"
             Mcp_types.method_sampling_create parsed.Mcp_types.method_
         | Error e -> Alcotest.fail ("roundtrip failed: " ^ e)));
    ];

    "sampling_response", [
      Alcotest.test_case "sampling_response_roundtrip" `Quick (fun () ->
        let resp : Mcp_types.jsonrpc_response = {
          id = Mcp_types.Int_id 7;
          result = Ok (`Assoc [
            ("role", `String "assistant");
            ("content", `Assoc [("type", `String "text"); ("text", `String "Generated text")]);
            ("model", `String "gpt-4");
            ("stopReason", `String "endTurn");
          ]);
        } in
        let json = Mcp_types.jsonrpc_response_to_yojson resp in
        (match Mcp_types.response_of_yojson json with
         | Ok parsed ->
           (match parsed.result with
            | Ok (`Assoc fields) ->
              (match List.assoc_opt "role" fields with
               | Some (`String "assistant") -> ()
               | _ -> Alcotest.fail "role field missing or wrong");
              (match List.assoc_opt "stopReason" fields with
               | Some (`String "endTurn") -> ()
               | _ -> Alcotest.fail "stopReason field missing or wrong")
            | _ -> Alcotest.fail "result not an object")
         | Error e -> Alcotest.fail ("response roundtrip failed: " ^ e)));

      Alcotest.test_case "sampling_error_response" `Quick (fun () ->
        let resp : Mcp_types.jsonrpc_response = {
          id = Mcp_types.String_id "err-1";
          result = Error { code = -32601; message = "Method not found"; data = None };
        } in
        let json = Mcp_types.jsonrpc_response_to_yojson resp in
        (match Mcp_types.response_of_yojson json with
         | Ok parsed ->
           (match parsed.result with
            | Error err ->
              Alcotest.(check int) "error code" (-32601) err.Mcp_types.code;
              Alcotest.(check string) "error message" "Method not found" err.Mcp_types.message
            | Ok _ -> Alcotest.fail "expected Error result")
         | Error e -> Alcotest.fail ("error response parse failed: " ^ e)));
    ];
  ]
