open Par
open Types

let test_streaming_delta_preserves_id_across_chunks () =
  let chunk1 = `Assoc [
    ("choices", `List [`Assoc [
      ("index", `Int 0);
      ("delta", `Assoc [
        ("tool_calls", `List [`Assoc [
          ("index", `Int 0);
          ("id", `String "call_test456");
          ("type", `String "function");
          ("function", `Assoc [("name", `String "get_weather"); ("arguments", `String "")])
        ]])
      ]);
      ("finish_reason", `Null);
    ]])
  ] in
  let chunk2 = `Assoc [
    ("choices", `List [`Assoc [
      ("index", `Int 0);
      ("delta", `Assoc [
        ("tool_calls", `List [`Assoc [
          ("index", `Int 0);
          ("function", `Assoc [("arguments", `String "{\"city\":\"Tokyo\"}")])
        ]])
      ]);
      ("finish_reason", `Null);
    ]])
  ] in
  let map = Hashtbl.create 4 in
  let (_, _, chunks1, _, _) = Openai_provider.parse_stream_delta ~tc_id_map:map chunk1 in
  let (_, _, chunks2, _, _) = Openai_provider.parse_stream_delta ~tc_id_map:map chunk2 in
  let ids_of chunks = List.filter_map (function
    | Tool_call_start { tool_call_id; _ } | Tool_call_delta { tool_call_id; _ } -> Some tool_call_id
    | _ -> None) chunks in
  let ids1 = ids_of chunks1 in
  let ids2 = ids_of chunks2 in
  Alcotest.(check bool) "chunk1 has call_test456" true (List.mem "call_test456" ids1);
  Alcotest.(check bool) "chunk2 inherits call_test456 (not index 0)" true (List.mem "call_test456" ids2);
  Alcotest.(check bool) "chunk2 does NOT use index fallback" false (List.mem "0" ids2)

let test_streaming_multi_tool_distinct_ids () =
  let map = Hashtbl.create 4 in
  let mk_start idx id name =
    `Assoc [("choices", `List [`Assoc [
      ("index", `Int 0);
      ("delta", `Assoc [("tool_calls", `List [`Assoc [
        ("index", `Int idx); ("id", `String id); ("type", `String "function");
        ("function", `Assoc [("name", `String name); ("arguments", `String "")])
      ]])]);
      ("finish_reason", `Null)]])]
  in
  let mk_delta idx args =
    `Assoc [("choices", `List [`Assoc [
      ("index", `Int 0);
      ("delta", `Assoc [("tool_calls", `List [`Assoc [
        ("index", `Int idx);
        ("function", `Assoc [("arguments", `String args)])
      ]])]);
      ("finish_reason", `Null)]])]
  in
  let _, _, _c1, _, _ = Openai_provider.parse_stream_delta ~tc_id_map:map (mk_start 0 "call_A" "search") in
  let _, _, _c2, _, _ = Openai_provider.parse_stream_delta ~tc_id_map:map (mk_start 1 "call_B" "fetch") in
  let _, _, c3, _, _ = Openai_provider.parse_stream_delta ~tc_id_map:map (mk_delta 0 "{\"q\":1}") in
  let _, _, c4, _, _ = Openai_provider.parse_stream_delta ~tc_id_map:map (mk_delta 1 "{\"url\":2}") in
  let ids_of chunks = List.filter_map (function
    | Tool_call_delta { tool_call_id; _ } -> Some tool_call_id | _ -> None) chunks in
  let delta_ids = ids_of c3 @ ids_of c4 in
  Alcotest.(check bool) "delta for tool A uses call_A" true (List.mem "call_A" delta_ids);
  Alcotest.(check bool) "delta for tool B uses call_B" true (List.mem "call_B" delta_ids);
  Alcotest.(check bool) "no index fallbacks" false (List.mem "0" delta_ids || List.mem "1" delta_ids)

let () =
  Alcotest.run "tool_call_id BUG 2 (PAR-58e)" [
    "openai_streaming", [
      Alcotest.test_case "delta inherits real id from start" `Quick test_streaming_delta_preserves_id_across_chunks;
      Alcotest.test_case "multi-tool distinct ids" `Quick test_streaming_multi_tool_distinct_ids;
    ];
  ]
