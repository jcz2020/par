open Par
module M = Par__Mcp_errors

let contains needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  if nlen = 0 then true else loop 0

let cat_equal expected actual =
  Yojson.Safe.to_string (Types.error_category_to_yojson expected)
  = Yojson.Safe.to_string (Types.error_category_to_yojson actual)

let test_constants =
  let open Alcotest in
  [
    test_case "code_parse_error == -32700"        `Quick (fun () ->
      check int "parse error code" (-32700) M.code_parse_error);
    test_case "code_invalid_request == -32600"    `Quick (fun () ->
      check int "invalid request code" (-32600) M.code_invalid_request);
    test_case "code_method_not_found == -32601"   `Quick (fun () ->
      check int "method not found code" (-32601) M.code_method_not_found);
    test_case "code_invalid_params == -32602"     `Quick (fun () ->
      check int "invalid params code" (-32602) M.code_invalid_params);
    test_case "code_internal_error == -32603"     `Quick (fun () ->
      check int "internal error code" (-32603) M.code_internal_error);

    test_case "code_server_error_min == -32099"   `Quick (fun () ->
      check int "server error min" (-32099) M.code_server_error_min);
    test_case "code_server_error_max == -32000"   `Quick (fun () ->
      check int "server error max" (-32000) M.code_server_error_max);

    test_case "code_connection_closed == -32000"  `Quick (fun () ->
      check int "connection closed code" (-32000) M.code_connection_closed);
    test_case "code_request_timeout == -32001"    `Quick (fun () ->
      check int "request timeout code" (-32001) M.code_request_timeout);
    test_case "code_request_cancelled == -32800"  `Quick (fun () ->
      check int "request cancelled code" (-32800) M.code_request_cancelled);
    test_case "code_url_elicitation == -32042"    `Quick (fun () ->
      check int "url elicitation code" (-32042) M.code_url_elicitation);
  ]

let test_to_category_per_variant =
  let open Alcotest in
  let check_cat label expected actual =
    check bool label true (cat_equal expected actual)
  in
  [
    test_case "Jsonrpc_parse_error -> Invalid_input" `Quick (fun () ->
      let e = M.Jsonrpc_parse_error
        { code = -32700; message = "bad json"; raw = "{not json" } in
      check_cat "parse error"
        (Types.Invalid_input "MCP parse error: bad json")
        (M.to_category e));

    test_case "Jsonrpc_protocol_error -32600 -> Invalid_input" `Quick (fun () ->
      let e = M.Jsonrpc_protocol_error
        { code = -32600; message = "missing jsonrpc field"; data = None } in
      check_cat "invalid request"
        (Types.Invalid_input "MCP invalid request: missing jsonrpc field")
        (M.to_category e));

    test_case "Jsonrpc_protocol_error -32601 -> Invalid_input" `Quick (fun () ->
      let e = M.Jsonrpc_protocol_error
        { code = -32601; message = "tools/foo"; data = None } in
      check_cat "method not found"
        (Types.Invalid_input "MCP method not found: tools/foo")
        (M.to_category e));

    test_case "Jsonrpc_protocol_error -32602 -> Invalid_input" `Quick (fun () ->
      let e = M.Jsonrpc_protocol_error
        { code = -32602; message = "missing arg"; data = None } in
      check_cat "invalid params"
        (Types.Invalid_input "MCP invalid params: missing arg")
        (M.to_category e));

    test_case "Jsonrpc_protocol_error -32603 -> Internal" `Quick (fun () ->
      let e = M.Jsonrpc_protocol_error
        { code = -32603; message = "boom"; data = None } in
      check_cat "internal error"
        (Types.Internal "MCP internal error: boom")
        (M.to_category e));

    test_case "Jsonrpc_protocol_error -32700 -> Invalid_input" `Quick (fun () ->
      let e = M.Jsonrpc_protocol_error
        { code = -32700; message = "parse fail"; data = None } in
      check_cat "parse error code"
        (Types.Invalid_input "MCP parse error: parse fail")
        (M.to_category e));

    test_case "Tool_call_failed -> Internal" `Quick (fun () ->
      let e = M.Tool_call_failed
        { tool_name = "bash"; message = "exit 1" } in
      check_cat "tool call failed"
        (Types.Internal "MCP tool bash failed: exit 1")
        (M.to_category e));

    test_case "Server_crashed -> External_failure" `Quick (fun () ->
      let e = M.Server_crashed
        { pid = 1234; exit_code = 139; stderr_tail = "segfault" } in
      check_cat "server crashed"
        (Types.External_failure
           "MCP server (pid 1234) crashed with exit 139: segfault")
        (M.to_category e));

    test_case "Timeout_error -> Timeout" `Quick (fun () ->
      let e = M.Timeout_error { request_id = 42; waited_seconds = 30.0 } in
      check_cat "timeout" Types.Timeout (M.to_category e));

    test_case "Cancelled -> Internal" `Quick (fun () ->
      let e = M.Cancelled { request_id = 7; reason = None } in
      check_cat "cancelled"
        (Types.Internal "MCP request 7 cancelled")
        (M.to_category e));

    test_case "Connection_closed -> External_failure" `Quick (fun () ->
      check_cat "connection closed"
        (Types.External_failure "MCP connection closed unexpectedly")
        (M.to_category M.Connection_closed));

    test_case "Spawn_failed -> External_failure" `Quick (fun () ->
      let e = M.Spawn_failed
        { command = "/usr/bin/mcp-server"; args = ["--port"; "8080"];
          unix_error = "No such file or directory" } in
      check_cat "spawn failed"
        (Types.External_failure
           "MCP server failed to spawn: /usr/bin/mcp-server --port 8080 (No such file or directory)")
        (M.to_category e));
  ]

let test_boundary_codes =
  let open Alcotest in
  let check_cat label expected actual =
    check bool label true (cat_equal expected actual)
  in
  [
    test_case "code -32099 (lower bound) -> External_failure" `Quick (fun () ->
      let e = M.Jsonrpc_protocol_error
        { code = -32099; message = "low edge"; data = None } in
      check_cat "boundary low"
        (Types.External_failure "MCP server-defined error -32099: low edge")
        (M.to_category e));

    test_case "code -32000 (upper bound) -> External_failure" `Quick (fun () ->
      let e = M.Jsonrpc_protocol_error
        { code = -32000; message = "high edge"; data = None } in
      check_cat "boundary high"
        (Types.External_failure "MCP server-defined error -32000: high edge")
        (M.to_category e));

    test_case "code -32100 (just outside range) -> Internal" `Quick (fun () ->
      let e = M.Jsonrpc_protocol_error
        { code = -32100; message = "outside"; data = None } in
      check_cat "just below range"
        (Types.Internal "MCP unknown error code -32100: outside")
        (M.to_category e));

    test_case "code 0 (out of spec) -> Internal" `Quick (fun () ->
      let e = M.Jsonrpc_protocol_error
        { code = 0; message = "weird"; data = None } in
      check_cat "code 0"
        (Types.Internal "MCP unknown error code 0: weird")
        (M.to_category e));

    test_case "code -32768 (far outside) -> Internal" `Quick (fun () ->
      let e = M.Jsonrpc_protocol_error
        { code = -32768; message = "far"; data = None } in
      check_cat "code -32768"
        (Types.Internal "MCP unknown error code -32768: far")
        (M.to_category e));
  ]

let test_format =
  let open Alcotest in
  [
    test_case "format Connection_closed contains 'MCP connection closed'"
      `Quick (fun () ->
        let s = M.format M.Connection_closed in
        check bool "contains" true (contains "MCP connection closed" s));

    test_case "format Spawn_failed contains command and unix_error"
      `Quick (fun () ->
        let e = M.Spawn_failed
          { command = "mcp-server"; args = ["--x"];
            unix_error = "permission denied" } in
        let s = M.format e in
        check bool "contains command" true (contains "mcp-server" s);
        check bool "contains unix_error" true
          (contains "permission denied" s));

    test_case "format Tool_call_failed contains tool_name" `Quick (fun () ->
      let e = M.Tool_call_failed
        { tool_name = "special_tool"; message = "oops" } in
      let s = M.format e in
      check bool "contains tool_name" true (contains "special_tool" s));

    test_case "format Server_crashed contains pid and exit_code" `Quick (fun () ->
      let e = M.Server_crashed
        { pid = 4242; exit_code = 2; stderr_tail = "EOF" } in
      let s = M.format e in
      check bool "contains pid" true (contains "4242" s);
      check bool "contains exit_code" true (contains "exit 2" s));

    test_case "format Jsonrpc_protocol_error uses 'MCP error N: ...' format"
      `Quick (fun () ->
        let e = M.Jsonrpc_protocol_error
          { code = -32602; message = "bad param"; data = None } in
        let s = M.format e in
        let expected = "MCP error -32602: bad param" in
        check string "exact" expected s);
  ]

let () =
  Alcotest.run "mcp_errors" [
    "constants",             test_constants;
    "to_category_variants",  test_to_category_per_variant;
    "boundary_codes",        test_boundary_codes;
    "format",                test_format;
  ]
