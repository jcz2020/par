open Par
open Types

let test_synthesized_ids_are_distinct () =
  let input =
    "{\"tool_calls\": [{\"name\": \"search\", \"arguments\": {\"q\": \"test\"}}, {\"name\": \"fetch\", \"arguments\": {\"url\": \"http://example.com\"}}, {\"name\": \"compute\", \"arguments\": {\"x\": 42}}]}"
  in
  let calls = Tool_prompt.parse_tool_calls_from_text input in
  Alcotest.(check int) "3 tool calls" 3 (List.length calls);
  let ids = List.map (fun (tc : tool_call) -> tc.id) calls in
  Alcotest.(check bool) "first id is synth_0" true (List.mem "synth_0" ids);
  Alcotest.(check bool) "second id is synth_1" true (List.mem "synth_1" ids);
  Alcotest.(check bool) "third id is synth_2" true (List.mem "synth_2" ids)

let test_synthesized_ids_non_empty () =
  let input = "{\"tool_calls\": [{\"name\": \"solo\", \"arguments\": null}]}" in
  let calls = Tool_prompt.parse_tool_calls_from_text input in
  match calls with
  | [tc] -> Alcotest.(check bool) "id non-empty" true (String.length tc.id > 0)
  | _ -> Alcotest.fail "expected single tool call"

let () =
  Alcotest.run "tool_call_id BUG 1 (PAR-64l)" [
    "synthesized_ids", [
      Alcotest.test_case "distinct ids for multiple tools" `Quick test_synthesized_ids_are_distinct;
      Alcotest.test_case "single tool gets non-empty id" `Quick test_synthesized_ids_non_empty;
    ];
  ]
