open Par
open Types
open Par.Mock_provider

(* --- Shared fixtures --- *)

let mock_model : model_config = {
  provider = `Openai;
  model_name = "test-model";
  api_base = None;
  temperature = 0.7;
  max_tokens = None;
  top_p = None;
  stop_sequences = None;
}

let empty_conv : conversation = { messages = []; metadata = [] }

let make_tc name args : tool_call =
  { id = "tc_" ^ name; name; arguments = args }

let default_stream_config : stream_config = {
  chunk_timeout = 10.0;
  total_timeout = None;
  buffer_size = 4096;
}

let show_error : error_category -> string = function
  | Timeout -> "timeout"
  | Invalid_input s -> s
  | External_failure s -> s
  | Rate_limited -> "rate_limited"
  | Permission_denied s -> s
  | Internal s -> s
  | Embedding_unsupported -> "embedding_unsupported"

let test_create_returns_valid_service () =
  let (svc, _history) = create [Text "hello"] in
  (* All three function fields must be callable without crashing *)
  ignore (svc.complete_fn mock_model [] empty_conv);
  ignore (svc.stream_fn mock_model [] empty_conv default_stream_config ignore);
  svc.close_fn ()

let test_single_text_response () =
  let (svc, _history) = create [Text "hello"] in
  match svc.complete_fn mock_model [] empty_conv with
  | Ok resp ->
    Alcotest.(check (option string) "text" (Some "hello") resp.text);
    Alcotest.(check bool "tool_calls None" true (resp.tool_calls = None));
    Alcotest.(check bool "finish_reason" true (resp.finish_reason = Stop));
    Alcotest.(check string "model" "mock-llm" resp.model)
  | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)

let test_multi_turn_scripted_sequence () =
  let (svc, _history) =
    create [Text "first"; Text "second"; Text "third"]
  in
  let get_text () =
    match svc.complete_fn mock_model [] empty_conv with
    | Ok r -> r.text
    | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
  in
  Alcotest.(check (option string) "1st" (Some "first") (get_text ()));
  Alcotest.(check (option string) "2nd" (Some "second") (get_text ()));
  Alcotest.(check (option string) "3rd" (Some "third") (get_text ()));
  (* 4th call cycles back to first *)
  Alcotest.(check (option string) "4th (cycle)" (Some "first") (get_text ()))

let test_tool_call_response () =
  let tc = make_tc "calc" (`Assoc []) in
  let (svc, _history) =
    create [With_tool_calls { text = None; calls = [tc] }]
  in
  match svc.complete_fn mock_model [] empty_conv with
  | Ok resp ->
    (match resp.tool_calls with
     | Some [c] ->
       Alcotest.(check string "tool name" "calc" c.name);
       Alcotest.(check string "tool id" "tc_calc" c.id)
     | _ -> Alcotest.fail "expected single tool call");
    Alcotest.(check (option string) "text" None resp.text);
    Alcotest.(check bool "finish_reason" true (resp.finish_reason = Tool_calls))
  | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)

let test_error_injection () =
  let (svc, _history) =
    create [Error (Invalid_input "test error")]
  in
  match svc.complete_fn mock_model [] empty_conv with
  | Ok _ -> Alcotest.fail "expected error"
  | Error (Internal msg) ->
    Alcotest.(check string "error message" "test error" msg)
  | Error other ->
    Alcotest.failf "expected Internal, got: %s" (show_error other)

let test_empty_response_list_returns_default () =
  let (svc, _history) = create [] in
  match svc.complete_fn mock_model [] empty_conv with
  | Ok resp ->
    Alcotest.(check (option string) "text" (Some "mock") resp.text)
  | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)

let test_custom_usage_stats () =
  let usage = { prompt_tokens = 100; completion_tokens = 200; total_tokens = 300; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 } in
  let (svc, _history) = create ~usage [Text "hi"] in
  match svc.complete_fn mock_model [] empty_conv with
  | Ok resp ->
    Alcotest.(check int "prompt_tokens" 100 resp.usage.prompt_tokens);
    Alcotest.(check int "completion_tokens" 200 resp.usage.completion_tokens);
    Alcotest.(check int "total_tokens" 300 resp.usage.total_tokens)
  | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)

let test_custom_model_name () =
  let (svc, _history) = create ~model_name:"custom-model" [Text "x"] in
  match svc.complete_fn mock_model [] empty_conv with
  | Ok resp ->
    Alcotest.(check string "model" "custom-model" resp.model)
  | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)

let test_single_response_always_same () =
  let (svc, _history) = create [Text "always"] in
  for _i = 1 to 3 do
    match svc.complete_fn mock_model [] empty_conv with
    | Ok resp ->
      Alcotest.(check (option string) "text" (Some "always") resp.text)
    | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
  done

(* --- stream_fn tests --- *)

let test_stream_yields_chunks_then_completes () =
  let (svc, _history) = create [Text "hello"] in
  let chunks : llm_response_chunk list ref = ref [] in
  let cb chunk = chunks := chunk :: !chunks in
  match svc.stream_fn mock_model [] empty_conv default_stream_config cb with
  | Ok _sc ->
    let rev = List.rev !chunks in
    (* Should contain Text_delta, Usage_update, Done at minimum *)
    let has_text_delta = List.exists (function Text_delta _ -> true | _ -> false) rev in
    let has_usage = List.exists (function Usage_update _ -> true | _ -> false) rev in
    let has_done = List.exists (function Done _ -> true | _ -> false) rev in
    Alcotest.(check bool "has Text_delta" true has_text_delta);
    Alcotest.(check bool "has Usage_update" true has_usage);
    Alcotest.(check bool "has Done" true has_done)
  | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)

(* --- history tests --- *)

let test_call_history_tracks_complete_calls () =
  let (svc, history) = create [Text "a"; Text "b"] in
  ignore (svc.complete_fn mock_model [] empty_conv);
  ignore (svc.complete_fn mock_model [] empty_conv);
  Alcotest.(check int "call_count" 2 (call_count history));
  Alcotest.(check int "complete_calls length" 2
    (List.length history.complete_calls))

let test_call_history_records_model_and_tools () =
  let tools : tool_descriptor list = [
    { name = "t1"; description = "tool 1";
      input_schema = `Assoc []; output_schema = None; permission = Allow;
      timeout = None; concurrency_limit = None; on_update = None };
  ] in
  let specific_model = { mock_model with model_name = "specific-model" } in
  let (svc, history) = create [Text "x"] in
  ignore (svc.complete_fn specific_model tools empty_conv);
  match last_complete_call history with
  | Some record ->
    Alcotest.(check string "model_name" "specific-model" record.model.model_name);
    Alcotest.(check int "tools length" 1 (List.length record.tools))
  | None -> Alcotest.fail "expected a recorded call"

let test_close_tracking () =
  let (svc, history) = create [Text "x"] in
  Alcotest.(check int "before close" 0 history.close_calls);
  svc.close_fn ();
  Alcotest.(check int "after close" 1 history.close_calls)

(* --- Test runner --- *)

let () =
  let open Alcotest in
  run "Mock Provider" [
    "complete_fn", [
      test_case "create returns valid llm_service" `Quick
        test_create_returns_valid_service;
      test_case "single text response" `Quick
        test_single_text_response;
      test_case "multi-turn scripted sequence" `Quick
        test_multi_turn_scripted_sequence;
      test_case "tool call response" `Quick
        test_tool_call_response;
      test_case "error injection" `Quick
        test_error_injection;
      test_case "empty response list returns default" `Quick
        test_empty_response_list_returns_default;
      test_case "custom usage stats" `Quick
        test_custom_usage_stats;
      test_case "custom model name" `Quick
        test_custom_model_name;
      test_case "single response always returns same" `Quick
        test_single_response_always_same;
    ];
    "stream_fn", [
      test_case "stream yields chunks then completes" `Quick
        test_stream_yields_chunks_then_completes;
    ];
    "history", [
      test_case "call history tracks complete_calls" `Quick
        test_call_history_tracks_complete_calls;
      test_case "call history records model and tools" `Quick
        test_call_history_records_model_and_tools;
      test_case "close tracking" `Quick
        test_close_tracking;
    ];
  ]
