open Par
module T = Par__Mcp_types

let pp_yojson ppf j = Format.fprintf ppf "%s" (Yojson.Safe.to_string j)
let yojson_t = Alcotest.testable pp_yojson (=)
let yojson_option = Alcotest.option yojson_t

let is_invalid_input = function
  | Error (Types.Invalid_input _) -> true
  | _ -> false

let must_ok_sid label = function
  | Ok v -> v
  | Error (Types.Invalid_input e) ->
    Alcotest.failf "%s: expected Ok, got Invalid_input %s" label e
  | Error other ->
    Alcotest.failf "%s: expected Ok, got %s" label
      (match other with
       | Types.Timeout -> "Timeout"
       | Types.External_failure m -> Printf.sprintf "External_failure %S" m
       | Types.Rate_limited -> "Rate_limited"
       | Types.Permission_denied m -> Printf.sprintf "Permission_denied %S" m
       | Types.Internal m -> Printf.sprintf "Internal %S" m
       | Types.Invalid_input _ -> assert false)

let must_ok label = function
  | Ok v -> v
  | Error e ->
    Alcotest.failf "%s: expected Ok, got Error %s" label e

let must_err label = function
  | Ok _ ->
    Alcotest.failf "%s: expected Err, got Ok" label
  | Error _ -> ()

let must_invalid label r =
  if is_invalid_input r then ()
  else
    match r with
    | Ok _ -> Alcotest.failf "%s: expected Invalid_input, got Ok" label
    | Error other ->
      Alcotest.failf "%s: expected Invalid_input, got %s" label
        (match other with
         | Types.Timeout -> "Timeout"
         | Types.External_failure m -> Printf.sprintf "External_failure %S" m
         | Types.Rate_limited -> "Rate_limited"
         | Types.Permission_denied m -> Printf.sprintf "Permission_denied %S" m
         | Types.Internal m -> Printf.sprintf "Internal %S" m
         | Types.Invalid_input _ -> assert false)

let test_server_id_accepts_short () =
  let s = must_ok_sid "fs" (T.server_id_of_string "fs") in
  Alcotest.(check string) "round-trips" "fs" (T.server_id_to_string s)

let test_server_id_accepts_underscore () =
  let s = must_ok_sid "git_1" (T.server_id_of_string "git_1") in
  Alcotest.(check string) "round-trips" "git_1" (T.server_id_to_string s)

let test_server_id_accepts_dash () =
  let s = must_ok_sid "my-server" (T.server_id_of_string "my-server") in
  Alcotest.(check string) "round-trips" "my-server"
    (T.server_id_to_string s)

let test_server_id_rejects_empty () =
  must_invalid "empty" (T.server_id_of_string "")

let test_server_id_rejects_colon () =
  must_invalid "colon" (T.server_id_of_string "a:b")

let test_server_id_rejects_dot () =
  must_invalid "dot" (T.server_id_of_string "a.b")

let test_server_id_rejects_slash () =
  must_invalid "slash" (T.server_id_of_string "a/b")

let test_server_id_rejects_too_long () =
  let s = String.make 33 'a' in
  must_invalid "33 chars" (T.server_id_of_string s)

let test_server_id_rejects_space () =
  must_invalid "space" (T.server_id_of_string "has space")

let test_server_id_rejects_backslash () =
  must_invalid "backslash" (T.server_id_of_string "a\\b")

let test_server_id_compare_total () =
  let a = must_ok_sid "a" (T.server_id_of_string "a") in
  let b = must_ok_sid "b" (T.server_id_of_string "b") in
  let aa = must_ok_sid "a2" (T.server_id_of_string "a") in
  Alcotest.(check bool) "a < b" true (T.server_id_compare a b < 0);
  Alcotest.(check bool) "b > a" true (T.server_id_compare b a > 0);
  Alcotest.(check bool) "a = a" true (T.server_id_compare a aa = 0)

let test_tool_roundtrip () =
  let tool : T.mcp_tool = {
    name = "read_file";
    description = Some "Reads a file by path";
    title = Some "Read File";
    input_schema = `Assoc ["type", `String "object"];
  } in
  let j = T.mcp_tool_to_yojson tool in
  let tool' = must_ok "tool" (T.mcp_tool_of_yojson j) in
  Alcotest.(check string) "name" tool.name tool'.name;
  Alcotest.(check (option string)) "description" tool.description tool'.description;
  Alcotest.(check (option string)) "title" tool.title tool'.title;
  Alcotest.(check string) "schema"
    (Yojson.Safe.to_string tool.input_schema)
    (Yojson.Safe.to_string tool'.input_schema)

let test_resource_roundtrip () =
  let r : T.mcp_resource = {
    uri = "file:///tmp/x";
    name = "x";
    description = Some "a thing";
    mime_type = Some "text/plain";
    title = Some "X";
  } in
  let j = T.mcp_resource_to_yojson r in
  let r' = must_ok "resource" (T.mcp_resource_of_yojson j) in
  Alcotest.(check string) "uri" r.uri r'.uri;
  Alcotest.(check string) "name" r.name r'.name;
  Alcotest.(check (option string)) "description" r.description r'.description;
  Alcotest.(check (option string)) "mime_type" r.mime_type r'.mime_type;
  Alcotest.(check (option string)) "title" r.title r'.title

let test_prompt_roundtrip () =
  let p : T.mcp_prompt = {
    name = "summarise";
    description = Some "Summarise a doc";
    title = Some "Summarise";
    arguments = [
      { name = "doc"; description = Some "doc body"; required = true };
      { name = "max_words"; description = None; required = false };
    ];
  } in
  let j = T.mcp_prompt_to_yojson p in
  let p' = must_ok "prompt" (T.mcp_prompt_of_yojson j) in
  Alcotest.(check string) "name" p.name p'.name;
  Alcotest.(check (option string)) "description" p.description p'.description;
  Alcotest.(check (option string)) "title" p.title p'.title;
  Alcotest.(check int) "arg count" (List.length p.arguments)
    (List.length p'.arguments);
  match p'.arguments with
  | [a; b] ->
    Alcotest.(check string) "arg0.name" "doc" a.name;
    Alcotest.(check bool) "arg0.required" true a.required;
    Alcotest.(check string) "arg1.name" "max_words" b.name;
    Alcotest.(check bool) "arg1.required" false b.required
  | _ -> Alcotest.fail "expected exactly 2 arguments"

let test_capabilities_roundtrip () =
  let c : T.capabilities = {
    tools = true; resources = false; prompts = true;
    logging = false; sampling = false;
  } in
  let j = T.capabilities_to_yojson c in
  let c' = must_ok "caps" (T.capabilities_of_yojson j) in
  Alcotest.(check bool) "tools" c.tools c'.tools;
  Alcotest.(check bool) "resources" c.resources c'.resources;
  Alcotest.(check bool) "prompts" c.prompts c'.prompts;
  Alcotest.(check bool) "logging" c.logging c'.logging;
  Alcotest.(check bool) "sampling" c.sampling c'.sampling

let test_request_int_id_roundtrip () =
  let r : T.jsonrpc_request = {
    id = Int_id 42;
    method_ = "ping";
    params = Some (`Assoc []);
  } in
  let j = T.request_to_yojson r in
  let r' = must_ok "req" (T.jsonrpc_request_of_yojson j) in
  (match r'.id with
   | Int_id 42 -> ()
   | _ -> Alcotest.fail "expected Int_id 42");
  Alcotest.(check string) "method" r.method_ r'.method_

let test_request_string_id_roundtrip () =
  let r : T.jsonrpc_request = {
    id = String_id "abc";
    method_ = "tools/list";
    params = None;
  } in
  let j = T.request_to_yojson r in
  let r' = must_ok "req" (T.jsonrpc_request_of_yojson j) in
  (match r'.id with
   | String_id "abc" -> ()
   | _ -> Alcotest.fail "expected String_id \"abc\"");
  Alcotest.(check yojson_option) "params" r.params r'.params

let test_response_ok_roundtrip () =
  let r : T.jsonrpc_response = {
    id = Int_id 7;
    result = Ok (`String "hello");
  } in
  let j = T.jsonrpc_response_to_yojson r in
  let r' = must_ok "resp" (T.response_of_yojson j) in
  (match r'.result with
   | Ok (`String s) -> Alcotest.(check string) "result" "hello" s
   | _ -> Alcotest.fail "expected Ok \"hello\"")

let test_response_err_roundtrip () =
  let r : T.jsonrpc_response = {
    id = String_id "x";
    result = Error { code = -32601; message = "Method not found"; data = None };
  } in
  let j = T.jsonrpc_response_to_yojson r in
  let r' = must_ok "resp" (T.response_of_yojson j) in
  (match r'.result with
   | Error e ->
     Alcotest.(check int) "code" (-32601) e.code;
     Alcotest.(check string) "message" "Method not found" e.message
   | _ -> Alcotest.fail "expected Error variant")

let test_notification_roundtrip () =
  let n : T.jsonrpc_notification = {
    method_ = "notifications/initialized";
    params = None;
  } in
  let j = T.notification_to_yojson n in
  let n' = must_ok "n" (T.notification_of_yojson j) in
  Alcotest.(check string) "method" n.method_ n'.method_;
  Alcotest.(check yojson_option) "params" n.params n'.params

let test_request_id_int_parse () =
  let r = must_ok "int" (T.jsonrpc_request_of_yojson
    (`Assoc ["id", `Int 99; "method", `String "ping"])) in
  match r.id with
  | Int_id 99 -> ()
  | _ -> Alcotest.fail "expected Int_id 99"

let test_request_id_string_parse () =
  let r = must_ok "str" (T.jsonrpc_request_of_yojson
    (`Assoc ["id", `String "req-001"; "method", `String "ping"])) in
  match r.id with
  | String_id "req-001" -> ()
  | _ -> Alcotest.fail "expected String_id \"req-001\""

let test_response_rejects_both_result_and_error () =
  let j = `Assoc [
    "id", `Int 1;
    "result", `Null;
    "error", `Assoc ["code", `Int (-32603); "message", `String "oops"];
  ] in
  must_err "both" (T.response_of_yojson j)

let test_response_rejects_neither_result_nor_error () =
  let j = `Assoc ["id", `Int 1] in
  must_err "neither" (T.response_of_yojson j)

let test_notification_rejects_with_id () =
  let j = `Assoc [
    "id", `Int 1;
    "method", `String "notifications/cancelled";
  ] in
  must_err "with id" (T.notification_of_yojson j)

let test_notification_accepts_no_id () =
  let j = `Assoc ["method", `String "notifications/progress"] in
  let n = must_ok "no id" (T.notification_of_yojson j) in
  Alcotest.(check string) "method" "notifications/progress" n.method_

let test_tool_missing_input_schema_defaults () =
  let j = `Assoc ["name", `String "no_schema"] in
  let t = must_ok "tool" (T.tool_of_yojson j) in
  Alcotest.(check string) "input_schema"
    {|{"type":"object"}|}
    (Yojson.Safe.to_string t.input_schema)

let test_tool_missing_optional_text () =
  let j = `Assoc [
    "name", `String "t";
    "inputSchema", `Assoc ["type", `String "object"];
  ] in
  let t = must_ok "tool" (T.tool_of_yojson j) in
  Alcotest.(check (option string)) "description" None t.description;
  Alcotest.(check (option string)) "title" None t.title

let test_resource_missing_optional_text () =
  let j = `Assoc ["uri", `String "file:///x"; "name", `String "x"] in
  let r = must_ok "res" (T.resource_of_yojson j) in
  Alcotest.(check (option string)) "description" None r.description;
  Alcotest.(check (option string)) "mime_type" None r.mime_type;
  Alcotest.(check (option string)) "title" None r.title

let test_prompt_missing_arguments_defaults_to_empty () =
  let j = `Assoc ["name", `String "p"] in
  let p = must_ok "p" (T.prompt_of_yojson j) in
  Alcotest.(check int) "arguments" 0 (List.length p.arguments)

let test_prompt_arg_missing_required_defaults_false () =
  let j = `Assoc [
    "name", `String "greet";
    "arguments", `List [
      `Assoc ["name", `String "who"];
    ];
  ] in
  let p = must_ok "p" (T.prompt_of_yojson j) in
  match p.arguments with
  | [a] -> Alcotest.(check bool) "required defaults to false" false a.required
  | _ -> Alcotest.fail "expected exactly 1 argument"

let test_capabilities_partial_object () =
  let j = `Assoc ["tools", `Bool true] in
  let c = must_ok "caps" (T.capabilities_of_yojson j) in
  Alcotest.(check bool) "tools true" true c.tools;
  Alcotest.(check bool) "resources false" false c.resources;
  Alcotest.(check bool) "prompts false" false c.prompts;
  Alcotest.(check bool) "logging false" false c.logging;
  Alcotest.(check bool) "sampling false" false c.sampling

let test_capabilities_empty_object () =
  let c = must_ok "caps" (T.capabilities_of_yojson (`Assoc [])) in
  Alcotest.(check bool) "tools false" false c.tools;
  Alcotest.(check bool) "resources false" false c.resources;
  Alcotest.(check bool) "prompts false" false c.prompts;
  Alcotest.(check bool) "logging false" false c.logging;
  Alcotest.(check bool) "sampling false" false c.sampling

let test_capabilities_ignores_unknown_fields () =
  let j = `Assoc [
    "tools", `Bool true;
    "experimental_thingy", `Assoc ["x", `Int 1];
    "weird_flag", `String "yes";
  ] in
  let c = must_ok "caps" (T.capabilities_of_yojson j) in
  Alcotest.(check bool) "tools true" true c.tools;
  Alcotest.(check bool) "resources false" false c.resources

let test_method_initialize () =
  Alcotest.(check string) "initialize" "initialize" T.method_initialize

let test_method_tools_call () =
  Alcotest.(check string) "tools/call" "tools/call" T.method_tools_call

let test_method_progress () =
  Alcotest.(check string) "progress" "notifications/progress"
    T.method_progress

let test_method_cancelled () =
  Alcotest.(check string) "cancelled" "notifications/cancelled"
    T.method_cancelled

let test_protocol_version () =
  Alcotest.(check string) "pinned" "2025-06-18" T.protocol_version

let server_id_suite =
  ("server_id", [
    Alcotest.test_case "accepts 'fs'"            `Quick test_server_id_accepts_short;
    Alcotest.test_case "accepts 'git_1'"         `Quick test_server_id_accepts_underscore;
    Alcotest.test_case "accepts 'my-server'"     `Quick test_server_id_accepts_dash;
    Alcotest.test_case "rejects empty"           `Quick test_server_id_rejects_empty;
    Alcotest.test_case "rejects colon"           `Quick test_server_id_rejects_colon;
    Alcotest.test_case "rejects dot"             `Quick test_server_id_rejects_dot;
    Alcotest.test_case "rejects slash"           `Quick test_server_id_rejects_slash;
    Alcotest.test_case "rejects backslash"       `Quick test_server_id_rejects_backslash;
    Alcotest.test_case "rejects 33-char string"  `Quick test_server_id_rejects_too_long;
    Alcotest.test_case "rejects space"           `Quick test_server_id_rejects_space;
    Alcotest.test_case "compare is total order"  `Quick test_server_id_compare_total;
  ])

let roundtrip_suite =
  ("json round-trip", [
    Alcotest.test_case "mcp_tool"                `Quick test_tool_roundtrip;
    Alcotest.test_case "mcp_resource"            `Quick test_resource_roundtrip;
    Alcotest.test_case "mcp_prompt"              `Quick test_prompt_roundtrip;
    Alcotest.test_case "capabilities"            `Quick test_capabilities_roundtrip;
    Alcotest.test_case "jsonrpc_request (int)"   `Quick test_request_int_id_roundtrip;
    Alcotest.test_case "jsonrpc_request (str)"   `Quick test_request_string_id_roundtrip;
    Alcotest.test_case "jsonrpc_response Ok"     `Quick test_response_ok_roundtrip;
    Alcotest.test_case "jsonrpc_response Error"  `Quick test_response_err_roundtrip;
    Alcotest.test_case "jsonrpc_notification"    `Quick test_notification_roundtrip;
  ])

let request_id_suite =
  ("request_id dual support", [
    Alcotest.test_case "parses int id"  `Quick test_request_id_int_parse;
    Alcotest.test_case "parses str id"  `Quick test_request_id_string_parse;
  ])

let response_validation_suite =
  ("response validation", [
    Alcotest.test_case "rejects both result & error"  `Quick test_response_rejects_both_result_and_error;
    Alcotest.test_case "rejects neither result/error"  `Quick test_response_rejects_neither_result_nor_error;
  ])

let notification_validation_suite =
  ("notification validation", [
    Alcotest.test_case "rejects when id field present" `Quick test_notification_rejects_with_id;
    Alcotest.test_case "accepts when no id"            `Quick test_notification_accepts_no_id;
  ])

let decoder_defaults_suite =
  ("entity decoder defaults", [
    Alcotest.test_case "tool missing inputSchema"        `Quick test_tool_missing_input_schema_defaults;
    Alcotest.test_case "tool missing description/title"  `Quick test_tool_missing_optional_text;
    Alcotest.test_case "resource missing optionals"      `Quick test_resource_missing_optional_text;
    Alcotest.test_case "prompt missing arguments"        `Quick test_prompt_missing_arguments_defaults_to_empty;
    Alcotest.test_case "prompt arg missing required"     `Quick test_prompt_arg_missing_required_defaults_false;
    Alcotest.test_case "capabilities partial"            `Quick test_capabilities_partial_object;
    Alcotest.test_case "capabilities empty object"       `Quick test_capabilities_empty_object;
    Alcotest.test_case "capabilities unknown fields"     `Quick test_capabilities_ignores_unknown_fields;
  ])

let constants_suite =
  ("method & version constants", [
    Alcotest.test_case "method_initialize"    `Quick test_method_initialize;
    Alcotest.test_case "method_tools_call"    `Quick test_method_tools_call;
    Alcotest.test_case "method_progress"      `Quick test_method_progress;
    Alcotest.test_case "method_cancelled"     `Quick test_method_cancelled;
    Alcotest.test_case "protocol_version"     `Quick test_protocol_version;
  ])

let () =
  Alcotest.run "mcp_types" [
    server_id_suite;
    roundtrip_suite;
    request_id_suite;
    response_validation_suite;
    notification_validation_suite;
    decoder_defaults_suite;
    constants_suite;
  ]
