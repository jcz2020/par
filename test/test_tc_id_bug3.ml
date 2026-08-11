open Par
open Types

let test_tool_message_serializes_as_tool_result () =
  let msg : message = {
    role = Tool;
    content_blocks = [Text_block { text = "42 degrees"; cache_control = None }];
    tool_calls = None;
    tool_call_id = Some "toolu_abc123";
    name = Some "get_weather";
    reasoning_content = None;
  } in
  let json = Anthropic_provider.build_message_json msg in
  let open Yojson.Safe.Util in
  let role = json |> member "role" |> to_string in
  Alcotest.(check string) "role is user" "user" role;
  let content = json |> member "content" |> to_list in
  Alcotest.(check int) "exactly 1 content block" 1 (List.length content);
  let block = List.hd content in
  Alcotest.(check string) "type is tool_result" "tool_result" (block |> member "type" |> to_string);
  Alcotest.(check string) "tool_use_id preserved" "toolu_abc123" (block |> member "tool_use_id" |> to_string);
  Alcotest.(check string) "content text preserved" "42 degrees" (block |> member "content" |> to_string)

let test_tool_message_without_id_falls_back () =
  let msg : message = {
    role = Tool;
    content_blocks = [Text_block { text = "orphan result"; cache_control = None }];
    tool_calls = None;
    tool_call_id = None;
    name = None;
    reasoning_content = None;
  } in
  let json = Anthropic_provider.build_message_json msg in
  let open Yojson.Safe.Util in
  let role = json |> member "role" |> to_string in
  Alcotest.(check string) "fallback role is user" "user" role;
  let content = json |> member "content" |> to_list in
  Alcotest.(check bool) "fallback has content blocks" true (List.length content >= 1)

let () =
  Alcotest.run "tool_call_id BUG 3 (PAR-v6z)" [
    "anthropic_tool_result", [
      Alcotest.test_case "Tool message → tool_result with tool_use_id" `Quick test_tool_message_serializes_as_tool_result;
      Alcotest.test_case "Tool message without id → fallback user message" `Quick test_tool_message_without_id_falls_back;
    ];
  ]
