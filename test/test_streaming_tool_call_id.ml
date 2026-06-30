(* test/test_streaming_tool_call_id.ml - PAR-zlm
   Verifies that LLM streaming providers emit the REAL tool_call_id in
   Tool_call_start / Tool_call_delta events, not the synthetic array index.
   Covers both OpenAI (call_ prefix) and Anthropic (toolu_ prefix) providers. *)

open Par
open Types

let test_openai_streaming_preserves_real_id () =
  let json : Yojson.Safe.t =
    `Assoc
      [ "id", `String "chatcmpl-stream-1"
      ; "object", `String "chat.completion.chunk"
      ; "model", `String "gpt-4o-mini"
      ; "choices",
        `List
          [ `Assoc
              [ "index", `Int 0
              ; "delta",
                `Assoc
                  [ "role", `String "assistant"
                  ; "tool_calls",
                    `List
                      [ `Assoc
                          [ "index", `Int 0
                          ; "id", `String "call_test123"
                          ; "type", `String "function"
                          ; "function",
                            `Assoc
                              [ "name", `String "get_time"
                              ; "arguments", `String "{}"
                              ]
                          ]
                      ]
                  ]
              ; "finish_reason", `Null
              ]
          ]
      ]
  in
  let _text, tool_chunks, _finish, _usage =
    Openai_provider.parse_stream_delta json
  in
  Alcotest.(check int) "exactly 2 tool_chunks (start + delta)"
    2 (List.length tool_chunks);
  let _ = match tool_chunks with
  | Tool_call_start { tool_call_id; name } :: _ ->
    Alcotest.(check string) "real id preserved, not index"
      "call_test123" tool_call_id;
    Alcotest.(check string) "name preserved" "get_time" name
  | _ ->
    Alcotest.failf "expected Tool_call_start first, got %d chunks"
      (List.length tool_chunks)
  in
  let _ = match List.rev tool_chunks with
  | Tool_call_delta { tool_call_id; args_json } :: _ ->
    Alcotest.(check string) "delta carries same real id"
      "call_test123" tool_call_id;
    Alcotest.(check string) "args_json preserved" "{}" args_json
  | _ -> Alcotest.fail "expected Tool_call_delta last"
  in
  ()

let test_openai_streaming_falls_back_to_index_when_id_absent () =
  let json : Yojson.Safe.t =
    `Assoc
      [ "choices",
        `List
          [ `Assoc
              [ "index", `Int 0
              ; "delta",
                `Assoc
                  [ "tool_calls",
                    `List
                      [ `Assoc
                          [ "index", `Int 1
                          ; "function",
                            `Assoc
                              [ "arguments", `String "{\"x\":1}" ]
                          ]
                      ]
                  ]
              ; "finish_reason", `Null
              ]
          ]
      ]
  in
  let _text, tool_chunks, _finish, _usage =
    Openai_provider.parse_stream_delta json
  in
  Alcotest.(check int) "1 tool_chunk (delta only)"
    1 (List.length tool_chunks);
  match tool_chunks with
  | [ Tool_call_delta { tool_call_id; args_json } ] ->
    Alcotest.(check string) "falls back to index string"
      "1" tool_call_id;
    Alcotest.(check string) "args preserved"
      "{\"x\":1}" args_json
  | _ -> Alcotest.failf "expected single Tool_call_delta, got %d chunks"
           (List.length tool_chunks)

let test_anthropic_streaming_tool_call_start_uses_real_id () =
  let data =
    {|{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_abc","name":"get_time","input":{}}}|}
  in
  let received : llm_response_chunk list ref = ref [] in
  let cb chunk = received := chunk :: !received in
  let usage = ref { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 } in
  let finish : finish_reason ref = ref Stop in
  let chunks : int ref = ref 0 in
  let current_tc_id : string ref = ref "" in
  Anthropic_provider.process_stream_event
    ("content_block_start", data) cb usage finish chunks current_tc_id;
  Alcotest.(check int) "callback fired exactly once"
    1 (List.length !received);
  let _ = match !received with
  | [ Tool_call_start { tool_call_id; name } ] ->
    Alcotest.(check string) "real Anthropic id preserved"
      "toolu_abc" tool_call_id;
    Alcotest.(check string) "name preserved" "get_time" name
  | _ ->
    Alcotest.failf "expected single Tool_call_start, got %d chunks"
      (List.length !received)
  in
  Alcotest.(check string) "current_tc_id ref set to real id"
    "toolu_abc" !current_tc_id

let test_anthropic_streaming_input_delta_uses_real_id () =
  let start_data =
    {|{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_abc","name":"get_time","input":{}}}|}
  in
  let delta_data =
    {|{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Beijing\"}"}}|}
  in
  let received : llm_response_chunk list ref = ref [] in
  let cb chunk = received := !received @ [chunk] in
  let usage = ref { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 } in
  let finish : finish_reason ref = ref Stop in
  let chunks : int ref = ref 0 in
  let current_tc_id : string ref = ref "" in
  Anthropic_provider.process_stream_event
    ("content_block_start", start_data) cb usage finish chunks current_tc_id;
  Anthropic_provider.process_stream_event
    ("content_block_delta", delta_data) cb usage finish chunks current_tc_id;
  Alcotest.(check int) "callback fired twice"
    2 (List.length !received);
  match !received with
  | [ _; Tool_call_delta { tool_call_id; args_json } ] ->
    Alcotest.(check string) "delta carries real id, not index"
      "toolu_abc" tool_call_id;
    Alcotest.(check string) "partial_json preserved"
      "{\"city\":\"Beijing\"}" args_json
  | _ ->
    Alcotest.failf "expected [start; delta] sequence, got %d chunks"
      (List.length !received)

let () =
  Alcotest.run "Streaming tool_call_id (PAR-zlm)" [
    "openai_provider", [
      Alcotest.test_case "preserves real call_ id" `Quick
        test_openai_streaming_preserves_real_id;
      Alcotest.test_case "falls back to index when id absent" `Quick
        test_openai_streaming_falls_back_to_index_when_id_absent;
    ];
    "anthropic_provider", [
      Alcotest.test_case "Tool_call_start uses real toolu_ id" `Quick
        test_anthropic_streaming_tool_call_start_uses_real_id;
      Alcotest.test_case "input_delta uses real id via current_tc_id" `Quick
        test_anthropic_streaming_input_delta_uses_real_id;
    ];
  ]
