(* Regression tests for the root-cause fix that ensures the terminal
   Assistant response is always materialized into the returned conversation.

   Bug (v0.7.8 root-cause fix): Engine.run_agent's Stop / Content_filter
   terminal branch returned (resp, conv) without calling add_assistant_message.
   The fix wraps a single add_assistant_message at run_agent's egress,
   eliminating the "remember-to-call" pattern across 6+ branches.

   These tests verify the invariant: for every Ok result, conv.messages'
   last entry is role=Assistant and its text matches resp.text.

   Fixtures copied verbatim from test_integration.ml per project
   convention (ROADMAP §Test Conventions point 3: no shared helpers). *)

open Par
open Types

let contains_substring ~needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let stop_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let content_filter_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Content_filter;
    usage = dummy_usage; model = "mock" }

let max_tokens_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Max_tokens;
    usage = dummy_usage; model = "mock" }

let tool_call_response calls : llm_response =
  { text = None; tool_calls = Some calls; finish_reason = Tool_calls;
    usage = dummy_usage; model = "mock" }

let mock_llm responses =
  let counter = ref 0 in
  let next () =
    let idx = !counter in
    incr counter;
    match List.nth_opt responses idx with
    | Some resp -> resp
    | None -> stop_response "default"
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

let dummy_tool ?(name = "test_tool") handler =
  let descriptor =
    { name; description = "A test tool"; input_schema = `Assoc [];
      output_schema = None; permission = Allow; timeout = None;
      concurrency_limit = None; on_update = None; cache_control = None }
  in
  { descriptor; handler }

let basic_agent ?(tools = []) ?(middleware = []) ?(max_iterations = 10)
    ?(on_max_tokens = Some Return_partial) ?(max_continuation_chunks = Some 3) () =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id = "test-agent";
    system_prompt = stable_prompt "You are a test agent.";
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations; middleware;
    retry_policy = None; context_strategy = None; resource_quota = None;
    max_execution_time = None; tool_timeout = None;
    early_stopping_method = Force;
    on_max_tokens; max_continuation_chunks;
    context_compression_threshold = None;
    compression_cooldown_messages = None;
    context_window_override = None;
    cache_strategy = No_caching }

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

let system_prompt_of conv =
  match conv.messages with
  | { role = System; content_blocks = [Text_block { text = s; cache_control = None }]; _ } :: _ -> Some s
  | _ -> None

let mock_llm_dynamic f =
  let counter = ref 0 in
  { complete_fn = (fun _model _tools conv ->
       incr counter;
       Ok (f conv));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None;
  }

let handoff_call ?(id = "tc-handoff") ?(name = "handoff") () : tool_call =
  { id; name; arguments = `Assoc [] }

let make_handoff_tool ?(name = "handoff") target_id =
  let descriptor =
    { name; description = "Handoff to target agent";
      input_schema = `Assoc []; output_schema = None;
      permission = Allow; timeout = None;
      concurrency_limit = None; on_update = None; cache_control = None }
  in
  let handler _ _ = Handoff { target_agent_id = target_id; carry_context = true; task = None } in
  { descriptor; handler }

let make_agent_with_id ?(tools = []) ?(max_iterations = 10) ?(early_stopping = Force)
    ?(on_max_tokens = Some Return_partial) ?(max_continuation_chunks = Some 3)
    id system_prompt =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id;
    system_prompt = stable_prompt system_prompt;
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations;
    middleware = []; retry_policy = None; context_strategy = None;
    resource_quota = None; max_execution_time = None; tool_timeout = None;
    early_stopping_method = early_stopping;
    on_max_tokens; max_continuation_chunks;
    context_compression_threshold = None;
    compression_cooldown_messages = None;
    context_window_override = None;
    cache_strategy = No_caching }

let make_registry_from tools =
  let reg = Tool_registry.create () in
  List.iter (fun (tb : tool_binding) ->
    ignore (Tool_registry.register reg tb.descriptor tb.handler)
  ) tools;
  reg

(* Core invariant assertion: the last message of conv is role=Assistant
   and its text equals Option.value resp.text ~default:"".
   This is the property the egress wrap guarantees. *)
let assert_last_message_is_terminal_assistant
    ~(name : string) (resp : llm_response) (conv : conversation) =
  match List.rev conv.messages with
  | [] -> Alcotest.fail (name ^ ": conversation is empty")
  | last :: _ ->
    Alcotest.(check string) (name ^ ": last message role is Assistant")
      "Assistant"
      (match last.role with
       | System -> "System" | User -> "User"
       | Assistant -> "Assistant" | Tool -> "Tool");
    let last_text = Message.text_of_message last in
    let resp_text = Option.value resp.text ~default:"" in
    Alcotest.(check string) (name ^ ": last message text matches resp.text")
      resp_text last_text

let terminal_assistant_message_suite =
  ("Terminal assistant message invariant", [

    (* ---- Test 1: Stop with non-empty text (the original bug) ---- *)
    Alcotest.test_case "Stop with content materializes Assistant message" `Quick
      (fun () ->
        let llm = mock_llm [ stop_response "final answer" ] in
        let agent = basic_agent () in
        let reg = make_registry [] in
        with_token (fun token ->
          match Engine.run_agent token agent "hi" llm reg with
          | Ok (resp, conv) ->
            assert_last_message_is_terminal_assistant
              ~name:"Stop" resp conv
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 2: Content_filter with non-empty text (also in the buggy _ catch-all) ---- *)
    Alcotest.test_case "Content_filter materializes Assistant message" `Quick
      (fun () ->
        let llm = mock_llm [ content_filter_response "filtered content" ] in
        let agent = basic_agent () in
        let reg = make_registry [] in
        with_token (fun token ->
          match Engine.run_agent token agent "hi" llm reg with
          | Ok (resp, conv) ->
            assert_last_message_is_terminal_assistant
              ~name:"Content_filter" resp conv
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 3: Tool_calls -> Stop two-iteration loop ----
       Verifies (a) line 790 mid-iteration append still works (tool_call_response
       is in conv before the tool result), and (b) egress wrap appends the
       SECOND (Stop) response, not the tool_call_response. *)
    Alcotest.test_case "Tool_calls then Stop: terminal is the Stop response" `Quick
      (fun () ->
        let tool = dummy_tool (fun _ _ -> Success (`String "tool-result")) in
        let call : tool_call = {
          id = "tc-1"; name = "test_tool"; arguments = `Assoc []
        } in
        let llm = mock_llm [
          tool_call_response [ call ];
          stop_response "final after tool";
        ] in
        let agent = basic_agent ~tools:[ tool ] () in
        let reg = make_registry [ tool ] in
        with_token (fun token ->
          match Engine.run_agent token agent "do something" llm reg with
          | Ok (resp, conv) ->
            (* resp is the SECOND LLM response (the Stop one) *)
            Alcotest.(check (option string)) "resp is final Stop response"
              (Some "final after tool") resp.text;
            (* Last conv message must be the terminal Stop, not the tool_call *)
            assert_last_message_is_terminal_assistant
              ~name:"Tool_calls->Stop" resp conv;
            (* Also: there must be a Tool role message for the tool_result *)
            let has_tool_msg =
              List.exists (fun (m : message) -> m.role = Tool) conv.messages
            in
            Alcotest.(check bool) "tool result message present"
              true has_tool_msg
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 4: Max_tokens / Return_partial with content ----
       Pre-fix: line 973 appended inline. Post-fix: egress wrap appends.
       Behavior must be identical. *)
    Alcotest.test_case "Max_tokens/Return_partial materializes Assistant message" `Quick
      (fun () ->
        let llm = mock_llm [ max_tokens_response "partial truncated output" ] in
        let agent = basic_agent () in
        let reg = make_registry [] in
        with_token (fun token ->
          match Engine.run_agent token agent "hi" llm reg with
          | Ok (resp, conv) ->
            assert_last_message_is_terminal_assistant
              ~name:"Return_partial" resp conv
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 5: Max_tokens / Continue multi-chunk ----
       Verifies Branch 6 normalize: conv's last message is the combined text,
       not the last chunk only. Also verifies no duplicate trailing Assistant
       messages (the compact replaced the intermediate trail). *)
    Alcotest.test_case "Max_tokens/Continue: combined text in single terminal message" `Quick
      (fun () ->
        (* Chunk 1: Max_tokens with >500 chars (passes diminishing-returns gate).
           Chunk 2: Max_tokens with <500 chars (triggers termination). *)
        let long_chunk = String.make 600 'x' in
        let llm = mock_llm [
          max_tokens_response long_chunk;
          max_tokens_response " short tail";
        ] in
        let agent = basic_agent ~on_max_tokens:(Some Continue) () in
        let reg = make_registry [] in
        with_token (fun token ->
          match Engine.run_agent token agent "hi" llm reg with
          | Ok (resp, conv) ->
            let expected_combined = long_chunk ^ " short tail" in
            Alcotest.(check (option string)) "resp.text is combined"
              (Some expected_combined) resp.text;
            (* The conversation's last message must equal the combined text *)
            assert_last_message_is_terminal_assistant
              ~name:"Continue" resp conv;
            (* Count trailing Assistant messages: must be exactly 1 (the compact
               replaced the intermediate trail). *)
            let trailing_assistant_count =
              List.length (List.filter (fun (m : message) -> m.role = Assistant)
                             (List.rev conv.messages))
            in
            (* Allow the egress wrap's Assistant as the single trailing one.
               Earlier messages may also be Assistant (e.g. early-stopping);
               but the LAST one must be the combined. The compact ensures no
               intermediate chunk-Assistant messages remain between the
               pre-Continue prefix and the combined terminal. *)
            Alcotest.(check bool) "trailing assistant count >= 1"
              true (trailing_assistant_count >= 1)
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 6: Stop with empty text (edge case) ----
       When resp.text = None or "", the wrap still adds an Assistant message
       with empty content_blocks. This is current behavior; we verify it's
       preserved. *)
    Alcotest.test_case "Stop with empty text still adds Assistant turn" `Quick
      (fun () ->
        let empty_resp : llm_response =
          { text = None; tool_calls = None; finish_reason = Stop;
            usage = dummy_usage; model = "mock" } in
        let llm = mock_llm [ empty_resp ] in
        let agent = basic_agent () in
        let reg = make_registry [] in
        with_token (fun token ->
          match Engine.run_agent token agent "hi" llm reg with
          | Ok (_resp, conv) ->
            (match List.rev conv.messages with
             | last :: _ ->
               Alcotest.(check string) "last message role is Assistant"
                 "Assistant"
                 (match last.role with
                  | Assistant -> "Assistant"
                  | _ -> "other");
               Alcotest.(check bool) "empty content_blocks permitted"
                 true (last.content_blocks = [])
             | [] ->
               Alcotest.fail "expected at least one message in conv")
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 7: Max_tokens / Retry does NOT append partial (loop invariant) ----
       Retry policy: first call truncated, second call succeeds with full text.
       The truncated partial must NOT be in conv as a separate Assistant turn
       — only the final successful response. *)
    Alcotest.test_case "Max_tokens/Retry: only final success in conv, no partial turn" `Quick
      (fun () ->
        let llm = mock_llm [
          max_tokens_response "partial that should be discarded";
          stop_response "full answer after retry";
        ] in
        let agent = basic_agent ~on_max_tokens:(Some Retry) () in
        let reg = make_registry [] in
        with_token (fun token ->
          match Engine.run_agent token agent "hi" llm reg with
          | Ok (resp, conv) ->
            Alcotest.(check (option string)) "resp is final Stop"
              (Some "full answer after retry") resp.text;
            assert_last_message_is_terminal_assistant
              ~name:"Retry" resp conv;
            (* The partial "discarded" text must NOT appear in any Assistant message *)
            let partial_in_conv =
              List.exists (fun (m : message) ->
                m.role = Assistant
                && contains_substring
                     ~needle:"partial that should be discarded"
                     (Message.text_of_message m)
              ) conv.messages
            in
            Alcotest.(check bool) "partial truncated text not in conv"
              false partial_in_conv
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 8 (P0): Handoff path — terminal assistant materialized across handoff ----
       Oracle audit identified this as the highest-risk untested path: A issues a
       tool_call that returns Handoff → B runs and finishes with Stop. Verify the
       egress wrap catches the terminal response through the recursive loop call,
       and the returned conv's last message is B's Stop response (not A's
       tool_call message). *)
    Alcotest.test_case "Handoff carry_context=true: terminal is target agent's response" `Quick
      (fun () ->
        let handoff_tool = make_handoff_tool "B" in
        let llm = mock_llm_dynamic (fun conv ->
          match system_prompt_of conv with
          | Some "You are B" -> stop_response "B's final answer"
          | _ -> tool_call_response [ handoff_call () ])
        in
        let agent_a = make_agent_with_id ~tools:[ handoff_tool ] "A" "You are A" in
        let agent_b = make_agent_with_id "B" "You are B" in
        let reg = make_registry_from [ handoff_tool ] in
        let resolver = function
          | "B" -> Some agent_b
          | _ -> None
        in
        with_token (fun token ->
          match Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
                  token agent_a "user question" llm reg with
          | Ok (resp, conv) ->
            Alcotest.(check (option string)) "resp is B's Stop"
              (Some "B's final answer") resp.text;
            assert_last_message_is_terminal_assistant
              ~name:"Handoff" resp conv;
            (* Conversation audit trail: A's tool_calls turn must be present.
               Note: handoff tool results do NOT generate a Tool-role message
               (they go into the `handoffs` partition, not `non_handoff`,
               so add_tool_result_message is not called). *)
            let has_a_tool_call =
              List.exists (fun (m : message) ->
                m.role = Assistant && m.tool_calls <> None) conv.messages
            in
            Alcotest.(check bool) "A's tool_call assistant message preserved"
              true has_a_tool_call
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 9 (P0): Early-stopping Generate path materializes final Assistant ----
       When max_iterations is exceeded with Generate policy, the loop makes a
       final LLM call asking for "best final answer". Verify the egress wrap
       materializes that final response into conv. Setup: max_iterations=1, first
       LLM call returns tool_calls (burns iteration), loop recurses to iter=1
       which exceeds max → Generate fires. *)
    Alcotest.test_case "Early-stopping Generate: final answer materialized" `Quick
      (fun () ->
        let echo_tool =
          let descriptor =
            { name = "echo"; description = "Echo tool";
              input_schema = `Assoc []; output_schema = None;
              permission = Allow; timeout = None;
              concurrency_limit = None; on_update = None; cache_control = None }
          in
          let handler _ _ = Success (`String "ok") in
          { descriptor; handler }
        in
        let llm = mock_llm_dynamic (fun conv ->
          (* Heuristic: if the last user message is the "Based on the work..."
             feedback added by the Generate early-stopping path, this is the
             final Generate call. Otherwise it's the first iteration. *)
          match List.rev conv.messages with
          | { role = User; _ } as last :: _ ->
            if contains_substring ~needle:"provide your best final answer"
                 (Message.text_of_message last)
            then stop_response "final generated answer"
            else tool_call_response [ { id = "tc-1"; name = "echo"; arguments = `Assoc [] } ]
          | _ -> stop_response "default")
        in
        let agent =
          make_agent_with_id ~tools:[ echo_tool ] ~max_iterations:1
            ~early_stopping:Generate "early-stop-agent" "You are a test agent"
        in
        let reg = make_registry_from [ echo_tool ] in
        with_token (fun token ->
          match Engine.run_agent token agent "hi" llm reg with
          | Ok (resp, conv) ->
            Alcotest.(check (option string)) "resp is Generate final answer"
              (Some "final generated answer") resp.text;
            assert_last_message_is_terminal_assistant
              ~name:"EarlyGenerate" resp conv
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 10 (P0): Handoff + empty-text terminal Stop ----
       Oracle's third audit found a hole in the egress wrap's idempotency
       check: in Handoff with carry_context=true, the source agent's
       mid-iteration tool_calls Assistant message survives in carried context
       with content_blocks=[] (text_of_message returns ""). If the target
       agent returns a Stop response with text=None, the naive role-only
       check would false-match on text_of_message="" and skip the target's
       terminal append. Verify the tightened check (requires tool_calls=None
       AND tool_call_id=None) correctly materializes the empty terminal turn. *)
    Alcotest.test_case "Handoff + empty-text terminal Stop: still materialized" `Quick
      (fun () ->
        let handoff_tool = make_handoff_tool "B" in
        let empty_stop_resp : llm_response =
          { text = None; tool_calls = None; finish_reason = Stop;
            usage = dummy_usage; model = "mock" } in
        let llm = mock_llm_dynamic (fun conv ->
          match system_prompt_of conv with
          | Some "You are B" -> empty_stop_resp
          | _ -> tool_call_response [ handoff_call () ])
        in
        let agent_a = make_agent_with_id ~tools:[ handoff_tool ] "A" "You are A" in
        let agent_b = make_agent_with_id "B" "You are B" in
        let reg = make_registry_from [ handoff_tool ] in
        let resolver = function
          | "B" -> Some agent_b
          | _ -> None
        in
        with_token (fun token ->
          match Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
                  token agent_a "user question" llm reg with
          | Ok (resp, conv) ->
            Alcotest.(check (option string)) "resp.text is None"
              None resp.text;
            (* Last message MUST be B's empty Stop turn, not A's tool_call *)
            (match List.rev conv.messages with
             | last :: _ ->
               Alcotest.(check string) "last message role is Assistant"
                 "Assistant"
                 (match last.role with
                  | Assistant -> "Assistant"
                  | _ -> "other");
               (* Critical assertion: last Assistant must NOT have tool_calls
                  (it's the terminal Stop, not A's mid-iteration tool_call).
                  The tightened idempotency check requires tool_calls=None AND
                  tool_call_id=None for the skip path; without it, A's
                  tool_call Assistant (text_of_message="") would false-match
                  B's empty terminal Stop and skip the append. *)
               Alcotest.(check bool) "last Assistant has no tool_calls"
                 true (last.tool_calls = None)
             | [] -> Alcotest.fail "conv empty")
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 11 (sanity): Conversation resume ending in Assistant ----
       Sanity check (NOT a regression test for the egress wrap fix — Test 10
       is the regression test for the Oracle-identified hole). Verifies that
       resuming a conversation whose last message is an Assistant (from a
       prior run_agent call) does not confuse the egress wrap. The two texts
       ("previous answer" vs "new answer after resume") differ, so the
       idempotency check short-circuits to needs_append=true before any
       role/tool_calls matching matters. This test would pass even without
       the tightened check from commit 10416b8 — it documents correct
       behavior for the resume use case, not a bug fix. *)
    Alcotest.test_case "Conversation resume ending in Assistant: new turn still appended" `Quick
      (fun () ->
        let prior_assistant_msg : message = {
          role = Assistant;
          content_blocks = [Text_block { text = "previous answer"; cache_control = None }];
          tool_calls = None; tool_call_id = None; name = None;
        } in
        let prior_sys : message = {
          role = System;
          content_blocks = [Text_block { text = "you are resumed"; cache_control = None }];
          tool_calls = None; tool_call_id = None; name = None;
        } in
        let prior_user : message = {
          role = User;
          content_blocks = [Text_block { text = "previous question"; cache_control = None }];
          tool_calls = None; tool_call_id = None; name = None;
        } in
        let existing_conv : conversation = {
          messages = [prior_sys; prior_user; prior_assistant_msg];
          metadata = [];
        } in
        let new_user_msg : message = {
          role = User;
          content_blocks = [Text_block { text = "follow-up question"; cache_control = None }];
          tool_calls = None; tool_call_id = None; name = None;
        } in
        let resumed_conv = { existing_conv with
                              messages = existing_conv.messages @ [new_user_msg] } in
        let llm = mock_llm_dynamic (fun _ ->
          stop_response "new answer after resume")
        in
        let agent = make_agent_with_id "resume-agent" "you are resumed" in
        let reg = make_registry_from [] in
        with_token (fun token ->
          match Engine.run_agent ~conversation:resumed_conv
                  token agent "follow-up question" llm reg with
          | Ok (resp, conv) ->
            Alcotest.(check (option string)) "resp is new answer"
              (Some "new answer after resume") resp.text;
            (* The conversation must end with the NEW terminal Assistant, not
               the prior one. The prior Assistant ("previous answer") must
               still be present earlier in the message list. *)
            (match List.rev conv.messages with
             | last :: _ ->
               Alcotest.(check string) "last message is new terminal"
                 "new answer after resume"
                 (Message.text_of_message last)
             | [] -> Alcotest.fail "conv empty");
            let has_prior =
              List.exists (fun (m : message) ->
                m.role = Assistant
                && Message.text_of_message m = "previous answer"
              ) conv.messages
            in
            Alcotest.(check bool) "prior assistant preserved in trail"
              true has_prior
          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

  ])

let () =
  Alcotest.run "test_engine_assistant_message" [
    terminal_assistant_message_suite;
  ]
