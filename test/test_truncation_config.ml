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
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 ; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }

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
  context_window_fn = None; cache_control_fn = None;
  }

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
        f token))

let configurable_agent ?(on_max_tokens = (Some Return_partial))
    ?(max_continuation_chunks = (Some 3))
    ?(max_iterations = 10) ?(tools = []) () =
  { id = "test-agent"; system_prompt = stable_prompt "You are a test agent.";
    system_prompt_template = None;
    model = dummy_model; tools; max_iterations; middleware = [];
    retry_policy = None; context_strategy = None; resource_quota = None;
    max_execution_time = None; tool_timeout = None; early_stopping_method = Force;
    on_max_tokens; max_continuation_chunks;
    context_compression_threshold = None; compression_cooldown_messages = None; context_window_override = None; cache_strategy = No_caching }

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
      let agent = configurable_agent ~on_max_tokens:(Some Retry) () in
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
      let agent = configurable_agent ~on_max_tokens:(Some Continue) () in
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
      let agent = configurable_agent ~on_max_tokens:(Some Continue) ~max_continuation_chunks:(Some 1) () in
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
      let agent = configurable_agent ~on_max_tokens:(Some Continue) ~max_continuation_chunks:(Some 10) () in
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
      let agent = configurable_agent ~on_max_tokens:(Some Return_partial) () in
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

(* -------------------------------------------------------------------------- *)
(* Long-output resolver tests (plan §2.3.1)                                   *)
(*                                                                             *)
(* These tests cover the new option-typed [on_max_tokens] /                   *)
(* [max_continuation_chunks] fields and the [Engine.resolve_*] helpers.        *)
(* They verify the Auto-resolution rules and the explicit-override rule       *)
(* without needing the full [Engine.run_agent] execution path.                 *)
(* -------------------------------------------------------------------------- *)

let test_tool_descriptor : tool_descriptor = {
  name = "test_tool";
  description = "A test tool for resolver tests";
  input_schema = `Assoc [];
  output_schema = None;
  permission = Allow;
  timeout = None;
  concurrency_limit = None;
  on_update = None;
}

let check_resolved_on_max_tokens label expected agent effective_tools =
  let resolved = Engine.resolve_on_max_tokens ~effective_tools agent in
  match resolved, expected with
  | Continue, Continue -> Alcotest.(check bool) label true true
  | Return_partial, Return_partial -> Alcotest.(check bool) label true true
  | Retry, Retry -> Alcotest.(check bool) label true true
  | _ -> Alcotest.fail
    (label ^ ": expected " ^
     (match expected with Continue -> "Continue" | Return_partial -> "Return_partial" | Retry -> "Retry") ^
     ", got " ^
     (match resolved with Continue -> "Continue" | Return_partial -> "Return_partial" | Retry -> "Retry"))

let truncation_resolver_suite =
  ("on_max_tokens resolver (long-output mode §2.3.1)", [

    (* 1. tool-less agent with no explicit policy → resolved to Continue.
       This is the foundational case: a text-only agent with no tools
       should never lose output to "Return_partial" since there's no
       ReAct loop to leave hanging mid-thought. *)
    Alcotest.test_case "tool_less_agent_defaults_to_continue" `Quick (fun () ->
      let agent = configurable_agent
        ~on_max_tokens:None ~max_continuation_chunks:None () in
      check_resolved_on_max_tokens
        "tool-less + Auto → Continue"
        Continue agent []);

    (* 2. tool-bearing agent with no explicit policy → Return_partial.
       Backwards compat: existing tool-using agents must NOT silently
       switch to Continue (which would mask truncation of tool-call
       intent mid-response). *)
    Alcotest.test_case "tool_bearing_agent_defaults_to_return_partial" `Quick (fun () ->
      let agent = configurable_agent
        ~on_max_tokens:None ~max_continuation_chunks:None
        ~tools:[test_tool_descriptor] () in
      check_resolved_on_max_tokens
        "tool-bearing + Auto → Return_partial"
        Return_partial agent [test_tool_descriptor]);

    (* 3. Explicit override wins over Auto. Even on a tool-less agent,
       Some Return_partial is honored — the user knows what they want. *)
    Alcotest.test_case "explicit_on_max_tokens_overrides_auto" `Quick (fun () ->
      let agent = configurable_agent
        ~on_max_tokens:(Some Return_partial)
        ~max_continuation_chunks:None () in
      check_resolved_on_max_tokens
        "explicit Return_partial beats tool-less Auto"
        Return_partial agent []);

    (* 4. Tool-less + Auto continuation cap is unbounded (max_int).
       A 5000-token PRD must not be silently truncated to 3 chunks. *)
    Alcotest.test_case "tool_less_max_continuation_chunks_unbounded" `Quick (fun () ->
      let agent = configurable_agent
        ~on_max_tokens:None ~max_continuation_chunks:None () in
      let resolved =
        Engine.resolve_max_continuation_chunks ~effective_tools:[] agent in
      Alcotest.(check int) "tool-less + Auto → max_int (unbounded)"
        max_int resolved);

    (* 5. Tool-bearing + Auto continuation cap is 3 (backwards compat
       with v0.6.0 hard-coded cap). *)
    Alcotest.test_case "tool_bearing_max_continuation_chunks_3" `Quick (fun () ->
      let agent = configurable_agent
        ~on_max_tokens:None ~max_continuation_chunks:None
        ~tools:[test_tool_descriptor] () in
      let resolved =
        Engine.resolve_max_continuation_chunks
          ~effective_tools:[test_tool_descriptor] agent in
      Alcotest.(check int) "tool-bearing + Auto → 3"
        3 resolved);

    (* 6. Explicit cap wins regardless of tool-bearing. *)
    Alcotest.test_case "explicit_max_continuation_chunks_respected" `Quick (fun () ->
      let agent = configurable_agent
        ~on_max_tokens:None
        ~max_continuation_chunks:(Some 5)
        ~tools:[test_tool_descriptor] () in
      let resolved =
        Engine.resolve_max_continuation_chunks
          ~effective_tools:[test_tool_descriptor] agent in
      Alcotest.(check int) "explicit Some 5 → 5"
        5 resolved;
      (* Same answer when skill overlay filters all tools out. *)
      let resolved_toolless =
        Engine.resolve_max_continuation_chunks
          ~effective_tools:[] agent in
      Alcotest.(check int) "explicit Some 5 still 5 with effective_tools=[]"
        5 resolved_toolless);

    (* 7. The main-loop iteration counter must NOT advance inside the
       Continue sub-loop. We prove this by:
       (a) setting max_iterations = 2,
       (b) feeding 3 LLM responses (2 Max_tokens, 1 Stop),
       (c) counting LLM calls (mock_llm_tracked).
       If Continue burned main iterations we'd see 1 main call, then
       continue at iter 1 (Max_tokens) and iter 2 (Stop) — 3 calls —
       but the second Max_tokens would land on Stop because iter 2
       would be reached. With proper sub-loop, 3 calls are made and
       the result is Ok with combined text. The counter = 3 invariant
       distinguishes "sub-loop ran, main loop untouched" (good) from
       "main loop burned an iter per continue" (would fail since
       max_iterations=2 would be hit). *)
    Alcotest.test_case "continue_does_not_burn_iterations" `Quick (fun () ->
      (* Chunks must be ≥500 chars to avoid the diminishing-returns guard
         (engine.ml:775) terminating the sub-loop before Stop is reached. *)
      let long_chunk1 = String.make 600 'a' in
      let long_chunk2 = String.make 600 'b' in
      let counter = ref 0 in
      let llm = mock_llm_tracked counter [
        max_tokens_response long_chunk1;
        max_tokens_response long_chunk2;
        text_response "final";
      ] in
      let agent = configurable_agent
        ~on_max_tokens:(Some Continue)
        ~max_continuation_chunks:None
        ~max_iterations:2 () in
      let reg = make_registry () in
      with_token (fun token ->
        match Engine.run_agent token agent "hi" llm reg with
        | Ok (resp, _) ->
            let expected = long_chunk1 ^ long_chunk2 ^ "final" in
            Alcotest.(check (option string)) "combined text across chunks"
              (Some expected) resp.text;
            Alcotest.(check int)
              "1 main + 2 continues = 3 LLM calls (main loop never advanced)"
              3 !counter
        | Error (e, _) ->
            Alcotest.fail
              ("expected Ok, got Error: " ^ error_to_string e ^
               " (counter=" ^ string_of_int !counter ^ ")")));

    (* 8. Skill overlay that filters all tools out should make the
       resolver see an "effective" tool-less agent — even though the
       agent's static config has tools. We simulate this by calling
       the resolver with effective_tools=[] against an agent whose
       [tools] field is non-empty. The resolver should pick the
       tool-less branch (Continue), not the tool-bearing branch. *)
    Alcotest.test_case "skill_overlay_makes_agent_tool_less" `Quick (fun () ->
      let agent = configurable_agent
        ~on_max_tokens:None ~max_continuation_chunks:None
        ~tools:[test_tool_descriptor] () in
      (* Static config has tools; resolver called with empty
         effective_tools must yield Continue. *)
      check_resolved_on_max_tokens
        "skill overlay strips all tools → Continue"
        Continue agent [];
      (* Same agent, but with effective_tools reflecting the static
         config: resolver yields Return_partial. Confirms the
         resolver is consulting [effective_tools], not [agent.tools]. *)
      check_resolved_on_max_tokens
        "no skill overlay → Return_partial"
        Return_partial agent [test_tool_descriptor];
      (* Continuation cap follows effective_tools: tool-less → unbounded. *)
      let resolved_chunks =
        Engine.resolve_max_continuation_chunks
          ~effective_tools:[] agent in
      Alcotest.(check int)
        "skill overlay strips all tools → cap max_int"
        max_int resolved_chunks);
  ])

let () =
  Alcotest.run "test_truncation_config" [
    truncation_config_suite;
    truncation_resolver_suite;
  ]
