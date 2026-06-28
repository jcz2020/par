(* Tests for configurable on_max_tokens_behavior (Phase 2, PAR-cx3).
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
  supports_native_tools_fn = None;
  }

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
        f token))

let configurable_agent ?(on_max_tokens = Return_partial) ?(max_continuation_chunks = 3)
    ?(max_iterations = 10) () =
  { id = "test-agent"; system_prompt = "You are a test agent.";
    system_prompt_template = None;
    model = dummy_model; tools = []; max_iterations; middleware = [];
    retry_policy = None; context_strategy = None; resource_quota = None;
    max_execution_time = None; tool_timeout = None; early_stopping_method = Force;
    on_max_tokens; max_continuation_chunks }

let make_registry () = Tool_registry.create ()

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"

let truncation_config_suite =
  ("on_max_tokens behavior", [

    Alcotest.test_case "Retry preserves message then re-loops" `Quick (fun () ->
      (* GIVEN: mock returns Max_tokens then Stop. Retry policy.
         WHEN: run_agent executes.
         THEN: result is Ok with the Stop response text, 2 LLM calls made. *)
      let counter = ref 0 in
      let llm = mock_llm_tracked counter [
        max_tokens_response "truncated";
        text_response "complete answer";
      ] in
      let agent = configurable_agent ~on_max_tokens:Retry () in
      let reg = make_registry () in
      with_token (fun token ->
        match Engine.run_agent token agent "hi" llm reg with
        | Ok (resp, _) ->
            Alcotest.(check (option string)) "retry gets complete answer"
              (Some "complete answer") resp.text;
            Alcotest.(check int) "2 LLM calls (retry)" 2 !counter
        | Error (e, _) ->
            Alcotest.fail ("expected Ok: " ^ error_to_string e)));

    Alcotest.test_case "Continue concatenates chunks" `Quick (fun () ->
      (* GIVEN: mock returns Max_tokens "part1" then Stop "part2".
         WHEN: Continue mode executes.
         THEN: final text = "part1part2", 2 LLM calls. *)
      let counter = ref 0 in
      let llm = mock_llm_tracked counter [
        max_tokens_response "part1";
        text_response "part2";
      ] in
      let agent = configurable_agent ~on_max_tokens:Continue () in
      let reg = make_registry () in
      with_token (fun token ->
        match Engine.run_agent token agent "hi" llm reg with
        | Ok (resp, _) ->
            Alcotest.(check (option string)) "concatenated text"
              (Some "part1part2") resp.text;
            Alcotest.(check int) "2 LLM calls (continue)" 2 !counter
        | Error (e, _) ->
            Alcotest.fail ("expected Ok: " ^ error_to_string e)));

    Alcotest.test_case "Continue respects max_continuation_chunks cap" `Quick (fun () ->
      (* GIVEN: max_continuation_chunks=1, mock always returns Max_tokens.
         WHEN: Continue mode executes.
         THEN: stops after 1 chunk, no continuation calls, text = first chunk. *)
      let counter = ref 0 in
      let llm = mock_llm_tracked counter [
        max_tokens_response "only chunk";
        max_tokens_response "should not be reached";
      ] in
      let agent = configurable_agent ~on_max_tokens:Continue ~max_continuation_chunks:1 () in
      let reg = make_registry () in
      with_token (fun token ->
        match Engine.run_agent token agent "hi" llm reg with
        | Ok (resp, _) ->
            Alcotest.(check (option string)) "first chunk text"
              (Some "only chunk") resp.text;
            Alcotest.(check int) "1 LLM call (cap at 1)" 1 !counter
        | Error (e, _) ->
            Alcotest.fail ("expected Ok: " ^ error_to_string e)));

    Alcotest.test_case "Continue stops on diminishing returns" `Quick (fun () ->
      (* GIVEN: mock returns long Max_tokens chunk then short (<500 chars) chunk.
         WHEN: Continue mode executes.
         THEN: stops after 2 chunks (short chunk triggers guard). *)
      let counter = ref 0 in
      let long_text = String.make 600 'x' in
      let short_text = String.make 100 'y' in
      let llm = mock_llm_tracked counter [
        max_tokens_response long_text;
        max_tokens_response short_text;
      ] in
      let agent = configurable_agent ~on_max_tokens:Continue ~max_continuation_chunks:10 () in
      let reg = make_registry () in
      with_token (fun token ->
        match Engine.run_agent token agent "hi" llm reg with
        | Ok (resp, _) ->
            let expected = long_text ^ short_text in
            Alcotest.(check (option string)) "combined text"
              (Some expected) resp.text;
            Alcotest.(check int) "2 LLM calls (diminishing returns)" 2 !counter
        | Error (e, _) ->
            Alcotest.fail ("expected Ok: " ^ error_to_string e)));

    Alcotest.test_case "Llm_response_truncated event emitted" `Quick (fun () ->
      (* GIVEN: mock returns Max_tokens with content.
         WHEN: run_agent with event collector.
         THEN: Llm_response_truncated event appears in collected events. *)
      let counter = ref 0 in
      let events = ref [] in
      let llm = mock_llm_tracked counter [ max_tokens_response "partial output" ] in
      let agent = configurable_agent ~on_max_tokens:Return_partial () in
      let reg = make_registry () in
      let collector evt = events := evt :: !events in
      with_token (fun token ->
        (match Engine.run_agent ~on_tool_event:(Some collector) token agent "hi" llm reg with
         | Ok _ -> ()
         | Error (e, _) -> Alcotest.fail ("expected Ok: " ^ error_to_string e));
        let has_truncation = List.exists (function
          | Llm_response_truncated _ -> true
          | _ -> false) !events in
        Alcotest.(check bool) "truncation event emitted" true has_truncation));
  ])

let () =
  Alcotest.run "test_truncation_config" [
    truncation_config_suite;
  ]
