(* Test for Max_tokens truncation handling fix (PAR-h7a).
   Fixtures copied verbatim from test/test_integration.ml per project
   convention (ROADMAP §Test Conventions point 3: no shared helpers). *)
open Par
open Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let max_tokens_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Max_tokens;
    usage = dummy_usage; model = "mock" }

let empty_max_tokens_response : llm_response =
  { text = None; tool_calls = None; finish_reason = Max_tokens;
    usage = dummy_usage; model = "mock" }

let mock_llm responses =
  let counter = ref 0 in
  let next () =
    let idx = !counter in
    incr counter;
    match List.nth_opt responses idx with
    | Some resp -> resp
    | None -> text_response "default"
  in
  { complete_fn = (fun _model _tools _conv -> Ok (next ()));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
  }

(* Variant that exposes its call counter for iteration-burn assertions. *)
let mock_llm_tracked counter responses =
  let next () =
    incr counter;
    let idx = (!counter - 1) in
    match List.nth_opt responses idx with
    | Some resp -> resp
    | None -> text_response "default"
  in
  { complete_fn = (fun _model _tools _conv -> Ok (next ()));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
  }

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
        f token))

let basic_agent ?(tools = []) ?(middleware = []) ?(max_iterations = 10) () =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id = "test-agent"; system_prompt = "You are a test agent.";
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations; middleware;
    retry_policy = None; context_strategy = None; resource_quota = None; max_execution_time = None; early_stopping_method = Force; on_max_tokens = Return_partial; max_continuation_chunks = 3 }

let make_registry tools =
  let reg = Tool_registry.create () in
  List.iter (fun (tb : tool_binding) ->
    ignore (Tool_registry.register reg tb.descriptor tb.handler)
  ) tools;
  reg

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"

let truncation_suite =
  ("Max_tokens truncation", [
    (* Test 1: Max_tokens with non-empty text → Ok with partial result.
       With current buggy code: the response is discarded, the loop re-enters,
       and eventually hits "Max iterations exceeded". This test FAILS (red)
       until the fix at engine.ml:657-660. *)
    Alcotest.test_case "Max_tokens with content returns partial result" `Quick (fun () ->
      let llm = mock_llm [ max_tokens_response "partial answer that was truncated" ] in
      let agent = basic_agent () in
      let reg = make_registry [] in
      with_token (fun token ->
        match Engine.run_agent token agent "hi" llm reg with
        | Ok (resp, conv) ->
            Alcotest.(check (option string)) "partial text preserved"
              (Some "partial answer that was truncated") resp.text;
            let msgs = conv.messages in
            let last_assistant =
              List.find_opt (fun (m : message) -> m.role = Assistant) (List.rev msgs)
            in
            (match last_assistant with
             | Some m ->
                 Alcotest.(check (option string)) "assistant message preserved in conv"
                   (Some "partial answer that was truncated") m.content
             | None ->
                 Alcotest.fail "expected an Assistant message in conversation")
        | Error (e, _) ->
            Alcotest.fail ("expected Ok with partial result, got Error: " ^ error_to_string e)));

    (* Test 2: Max_tokens with empty text → Error (regression guard).
       The fix must NOT return Ok for empty/think-only truncations.
       This test PASSES with both current and fixed code. *)
    Alcotest.test_case "Max_tokens with empty text keeps error behavior" `Quick (fun () ->
      let llm = mock_llm [ empty_max_tokens_response ] in
      let agent = basic_agent ~max_iterations:1 () in
      let reg = make_registry [] in
      with_token (fun token ->
        match Engine.run_agent token agent "hi" llm reg with
        | Ok _ ->
            Alcotest.fail "expected Error for empty Max_tokens, got Ok"
        | Error (Internal msg, _) ->
            Alcotest.(check bool) "error mentions Max iterations" true
              (try ignore (Str.search_forward (Str.regexp_string "Max iterations") msg 0); true
               with Not_found -> false)
        | Error (e, _) ->
            Alcotest.fail ("expected Internal error, got: " ^ error_to_string e)));

    (* Test 3: Max_tokens with content does NOT burn iterations.
       With current buggy code: the engine loops, calling the LLM again.
       Counter would be >= 2. This test FAILS (red) until the fix.
       With fix: engine returns Ok after 1 call. Counter = 1. *)
    Alcotest.test_case "Max_tokens with content does not burn iterations" `Quick (fun () ->
      let counter = ref 0 in
      let llm = mock_llm_tracked counter [
        max_tokens_response "truncated but valid output";
        text_response "should not be reached";
      ] in
      let agent = basic_agent () in
      let reg = make_registry [] in
      with_token (fun token ->
        match Engine.run_agent token agent "hi" llm reg with
        | Ok (resp, _) ->
            Alcotest.(check (option string)) "partial text returned"
              (Some "truncated but valid output") resp.text;
            Alcotest.(check int) "only 1 LLM call made (no iteration burn)" 1 !counter
        | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e
              ^ " (counter=" ^ string_of_int !counter ^ ")")));
  ])

let () =
  Alcotest.run "test_truncation_fix" [
    truncation_suite;
  ]
