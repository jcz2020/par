(* End-to-end regression test for hook-exception isolation in parallel tool
   execution (PAR-9jn, invoke_one try-with fix).

   Before the fix: a hook throwing an exception during parallel tool dispatch
   would propagate and crash the entire batch, leaving the other tool's result
   missing from the conversation.

   After the fix: invoke_one catches the exception, fires a Tool_failed event,
   and returns an Error handler_result so the batch completes normally.

   These tests use Engine.run_agent with a mock LLM to exercise the real code
   path — reverting the engine.ml fix will make them fail.

   Fixtures copied verbatim from test_engine_assistant_message.ml / test_integration.ml
   per project convention (ROADMAP §Test Conventions point 3: no shared helpers). *)

open Par
open Types

(* ---- Helpers (copied from test_engine_assistant_message.ml) ---- *)

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
  { text = Some text; reasoning_content = None; tool_calls = None;
    finish_reason = Stop; usage = dummy_usage; model = "mock" }

let tool_call_response calls : llm_response =
  { text = None; reasoning_content = None; tool_calls = Some calls;
    finish_reason = Tool_calls; usage = dummy_usage; model = "mock" }

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
    cache_strategy = No_caching; approval_handler = None }

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
  | Cancelled _ -> "cancelled"

(* ---- Test suite ---- *)

let hook_exception_isolation_suite =
  ("Hook exception isolation (PAR-9jn)", [

    (* ---- Test 1: Hook exception caught in parallel mode ----
       Two tools called in parallel: safe_tool (hook returns Allow) and
       crash_tool (hook throws Failure). Verifies:
       (a) batch does not crash — run_agent returns Ok
       (b) both Tool-role messages present in conversation
       (c) crash_tool's result message contains "invocation crashed"
       (d) Tool_failed event fired for crash_tool *)
    Alcotest.test_case "hook exception in parallel: batch survives, both results present" `Quick
      (fun () ->
        let safe_tool = dummy_tool ~name:"safe_tool"
          (fun _ _ -> Success (`String "safe-ok")) in
        let crash_tool = dummy_tool ~name:"crash_tool"
          (fun _ _ -> Success (`String "crash-ok")) in
        let call_safe : tool_call = {
          id = "tc-safe"; name = "safe_tool"; arguments = `Assoc []
        } in
        let call_crash : tool_call = {
          id = "tc-crash"; name = "crash_tool"; arguments = `Assoc []
        } in
        (* First LLM call: two parallel tool calls. Second: text "done". *)
        let llm = mock_llm [
          tool_call_response [ call_safe; call_crash ];
          stop_response "all done";
        ] in
        let agent = basic_agent ~tools:[ safe_tool; crash_tool ] () in
        let reg = make_registry [ safe_tool; crash_tool ] in
        (* Hook that throws for crash_tool, allows everything else *)
        let throwing_hook : Hook.tool_call_hook = fun (ctx : Hook.tool_call_context) ->
          if ctx.tool_name = "crash_tool" then
            Failure "hook crash!" |> raise
          else
            Hook.Allow
        in
        (* Event collector *)
        let events = ref [] in
        let on_event evt = events := evt :: !events in
        with_token (fun token ->
          match Engine.run_agent
                  ~tool_call_hooks:(Some [ throwing_hook ])
                  ~parallel:true
                  ~on_tool_event:(Some on_event)
                  token agent "use both tools" llm reg with
          | Ok (resp, conv) ->
            (* (a) Sanity: final text returned *)
            Alcotest.(check (option string)) "final response text"
              (Some "all done") resp.text;

            (* (b) Both Tool-role messages present *)
            let tool_messages =
              List.filter (fun (m : message) -> m.role = Tool) conv.messages
            in
            Alcotest.(check int) "2 Tool-role messages in conversation"
              2 (List.length tool_messages);

            (* (c) crash_tool result contains "invocation crashed" *)
            let crash_tool_msg =
              List.find_opt (fun (m : message) ->
                m.role = Tool && m.name = Some "crash_tool") conv.messages
            in
            (match crash_tool_msg with
             | None -> Alcotest.fail "crash_tool result message not found in conversation"
             | Some msg ->
               let text = Message.text_of_message msg in
               Alcotest.(check bool) "crash_tool result contains 'invocation crashed'"
                 true (contains_substring ~needle:"invocation crashed" text));

            (* (d) Tool_failed event fired for crash_tool *)
            let has_tool_failed =
              List.exists (function
                | Tool_failed { tool_name; _ } -> tool_name = "crash_tool"
                | _ -> false) !events
            in
            Alcotest.(check bool) "Tool_failed event fired for crash_tool"
              true has_tool_failed

          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* ---- Test 2: Hook exception caught in sequential mode ----
       Same as Test 1 but parallel=false. Verifies the fix works for
       both execution paths. *)
    Alcotest.test_case "hook exception in sequential: batch survives, both results present" `Quick
      (fun () ->
        let safe_tool = dummy_tool ~name:"safe_tool"
          (fun _ _ -> Success (`String "safe-ok")) in
        let crash_tool = dummy_tool ~name:"crash_tool"
          (fun _ _ -> Success (`String "crash-ok")) in
        let call_safe : tool_call = {
          id = "tc-safe"; name = "safe_tool"; arguments = `Assoc []
        } in
        let call_crash : tool_call = {
          id = "tc-crash"; name = "crash_tool"; arguments = `Assoc []
        } in
        let llm = mock_llm [
          tool_call_response [ call_safe; call_crash ];
          stop_response "done sequential";
        ] in
        let agent = basic_agent ~tools:[ safe_tool; crash_tool ] () in
        let reg = make_registry [ safe_tool; crash_tool ] in
        let throwing_hook : Hook.tool_call_hook = fun (ctx : Hook.tool_call_context) ->
          if ctx.tool_name = "crash_tool" then
            Failure "hook crash!" |> raise
          else
            Hook.Allow
        in
        let events = ref [] in
        let on_event evt = events := evt :: !events in
        with_token (fun token ->
          match Engine.run_agent
                  ~tool_call_hooks:(Some [ throwing_hook ])
                  ~parallel:false
                  ~on_tool_event:(Some on_event)
                  token agent "use both tools" llm reg with
          | Ok (resp, conv) ->
            Alcotest.(check (option string)) "final response text"
              (Some "done sequential") resp.text;

            let tool_messages =
              List.filter (fun (m : message) -> m.role = Tool) conv.messages
            in
            Alcotest.(check int) "2 Tool-role messages in conversation"
              2 (List.length tool_messages);

            let crash_tool_msg =
              List.find_opt (fun (m : message) ->
                m.role = Tool && m.name = Some "crash_tool") conv.messages
            in
            (match crash_tool_msg with
             | None -> Alcotest.fail "crash_tool result message not found"
             | Some msg ->
               let text = Message.text_of_message msg in
               Alcotest.(check bool) "crash_tool result contains 'invocation crashed'"
                 true (contains_substring ~needle:"invocation crashed" text));

            let has_tool_failed =
              List.exists (function
                | Tool_failed { tool_name; _ } -> tool_name = "crash_tool"
                | _ -> false) !events
            in
            Alcotest.(check bool) "Tool_failed event fired for crash_tool"
              true has_tool_failed

          | Error (e, _) ->
            Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));
  ])

let () =
  Alcotest.run "tool_call_id BUG 4 (PAR-9jn)" [
    hook_exception_isolation_suite;
  ]
