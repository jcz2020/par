open Par
open Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let tool_descriptor name : tool_descriptor =
  { name; description = "test tool"; input_schema = `Assoc [("type", `String "object")];
    output_schema = None; permission = Allow; timeout = None;
    concurrency_limit = None; on_update = None; cache_control = None }

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"
  | Cancelled _ -> "cancelled"

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let agent_with tools : agent_config =
  { id = "payload-test"; system_prompt = stable_prompt "test";
    system_prompt_template = None; model = dummy_model; tools;
    max_iterations = 5; middleware = []; retry_policy = None;
    context_strategy = None; resource_quota = None; max_execution_time = None;
    tool_timeout = None; early_stopping_method = Force;
    on_max_tokens = None; max_continuation_chunks = None;
    context_compression_threshold = None; compression_cooldown_messages = None;
    context_window_override = None; cache_strategy = No_caching;
    approval_handler = None }

let make_registry tools =
  let reg = Tool_registry.create () in
  List.iter (fun (tb : tool_binding) ->
    match Tool_registry.register reg tb.descriptor tb.handler with
    | Ok () -> ()
    | Error _ -> Alcotest.failf "register %s" tb.descriptor.name
  ) tools;
  reg

let test_malformed_arguments_are_normalized () =
  with_token (fun token ->
    let seen_input = ref None in
    let second_call_conv = ref None in
    let calls = ref 0 in
    let handler input _token =
      seen_input := Some input;
      Success (`String "tool ok")
    in
    let tb : tool_binding = {
      descriptor = tool_descriptor "probe";
      handler;
    } in
    let llm : llm_service = {
      complete_fn = (fun _ _ _ -> failwith "complete_fn should not be called");
      stream_fn = (fun _model _tools conv _cfg cb ->
        incr calls;
        if !calls = 1 then begin
          cb (Tool_call_start { tool_call_id = "tc1"; name = "probe" });
          cb (Tool_call_delta { tool_call_id = "tc1"; args_json = "{not json" });
          cb (Done { finish_reason = Tool_calls });
          Ok { final_usage = dummy_usage; finish_reason = Tool_calls; chunks_received = 3 }
        end else begin
          second_call_conv := Some conv;
          cb (Text_delta { text = "done" });
          cb (Done { finish_reason = Stop });
          Ok { final_usage = dummy_usage; finish_reason = Stop; chunks_received = 2 }
        end);
      close_fn = (fun () -> ());
      complete_structured_fn = None;
      list_models_fn = None;
      supports_native_tools_fn = None;
      context_window_fn = None; cache_control_fn = None;
    } in
    let agent = agent_with [tb.descriptor] in
    let reg = make_registry [tb] in
    match Engine.run_agent ~on_chunk:(Some (fun _ -> ())) token agent "go" llm reg with
    | Error (e, _) -> Alcotest.fail ("expected Ok: " ^ error_to_string e)
    | Ok (resp, conv) ->
      Alcotest.(check (option string)) "final text" (Some "done") resp.text;
      (match !seen_input with
       | Some (`Assoc []) -> ()
       | Some other -> Alcotest.failf "handler got %s" (Yojson.Safe.to_string other)
       | None -> Alcotest.fail "handler was not called");
      (* The assistant message persisted in the conversation must carry {} —
         never null — so the next request cannot be rejected. *)
      let args = List.concat_map (fun (m : message) ->
        match m.tool_calls with
        | Some tcs -> List.map (fun (tc : tool_call) -> tc.arguments) tcs
        | None -> []
      ) conv.messages in
      (match args with
       | [a] ->
         Alcotest.(check string) "persisted arguments are an object" "{}"
           (Yojson.Safe.to_string a)
       | _ -> Alcotest.failf "expected one tool call, got %d" (List.length args));
      (* The second LLM request must already see the normalized value. *)
      (match !second_call_conv with
       | None -> Alcotest.fail "second LLM call missing"
       | Some c ->
         let args = List.concat_map (fun (m : message) ->
           match m.tool_calls with
           | Some tcs -> List.map (fun (tc : tool_call) -> tc.arguments) tcs
           | None -> []
         ) c.messages in
         (match args with
          | [a] ->
            Alcotest.(check string) "request arguments are an object" "{}"
              (Yojson.Safe.to_string a)
          | _ -> Alcotest.fail "expected one tool call in second request")))

let test_orphan_tool_result_is_rejected_before_request () =
  with_token (fun token ->
    let called = ref false in
    let llm : llm_service = {
      complete_fn = (fun _ _ _ -> called := true; failwith "should not be called");
      stream_fn = (fun _ _ _ _ _ -> called := true; failwith "should not be called");
      close_fn = (fun () -> ());
      complete_structured_fn = None;
      list_models_fn = None;
      supports_native_tools_fn = None;
      context_window_fn = None; cache_control_fn = None;
    } in
    let bad : conversation = { messages = [
        { role = User; content_blocks = Message.content_of_string "hi";
          tool_calls = None; tool_call_id = None; name = None };
        { role = Tool; content_blocks = Message.content_of_string "orphan";
          tool_calls = None; tool_call_id = Some "tc_orphan"; name = None };
      ]; metadata = [] } in
    let agent = agent_with [] in
    let reg = make_registry [] in
    match Engine.run_agent ~conversation:bad token agent "go" llm reg with
    | Ok _ -> Alcotest.fail "expected Invalid_input"
    | Error (Invalid_input msg, _) ->
      Alcotest.(check bool) "mentions orphan id" true
        (try ignore (Str.search_forward (Str.regexp_string "tc_orphan") msg 0); true
         with Not_found -> false);
      Alcotest.(check bool) "provider was not called" false !called
    | Error (e, _) -> Alcotest.failf "expected Invalid_input, got %s"
        (error_to_string e))

let test_hallucinated_tool_calls_not_persisted () =
  with_token (fun token ->
    let llm : llm_service = {
      complete_fn = (fun _ _ _ ->
        Ok { text = Some "answer"; reasoning = [];
             tool_calls = Some [{ id = "tc_halluc"; name = "ghost";
                                  arguments = `Assoc [] }];
             finish_reason = Tool_calls; usage = dummy_usage; model = "mock" });
      stream_fn = (fun _ _ _ _ _ -> Error Timeout);
      close_fn = (fun () -> ());
      complete_structured_fn = None;
      list_models_fn = None;
      supports_native_tools_fn = None;
      context_window_fn = None; cache_control_fn = None;
    } in
    let agent = agent_with [] in
    let reg = make_registry [] in
    match Engine.run_agent token agent "go" llm reg with
    | Error (e, _) -> Alcotest.fail ("expected Ok: " ^ error_to_string e)
    | Ok (resp, conv) ->
      Alcotest.(check bool) "raw response keeps the hallucinated call" true
        (resp.tool_calls <> None);
      (match Conversation_repair.validate conv with
       | Ok () -> ()
       | Error msg -> Alcotest.fail ("persisted conversation invalid: " ^ msg));
      let persisted_calls = List.concat_map (fun (m : message) ->
        match m.tool_calls with Some calls -> calls | None -> []) conv.messages in
      Alcotest.(check int) "hallucinated calls stripped from conversation" 0
        (List.length persisted_calls))

let test_hallucinated_tool_calls_without_text () =
  with_token (fun token ->
    let llm : llm_service = {
      complete_fn = (fun _ _ _ ->
        Ok { text = None; reasoning = [];
             tool_calls = Some [{ id = "tc_empty"; name = "ghost";
                                  arguments = `Assoc [] }];
             finish_reason = Tool_calls; usage = dummy_usage; model = "mock" });
      stream_fn = (fun _ _ _ _ _ -> Error Timeout);
      close_fn = (fun () -> ());
      complete_structured_fn = None;
      list_models_fn = None;
      supports_native_tools_fn = None;
      context_window_fn = None; cache_control_fn = None;
    } in
    let agent = agent_with [] in
    let reg = make_registry [] in
    match Engine.run_agent token agent "go" llm reg with
    | Error (e, _) -> Alcotest.fail ("expected Ok: " ^ error_to_string e)
    | Ok (_resp, conv) ->
      (match Conversation_repair.validate conv with
       | Ok () -> ()
       | Error msg -> Alcotest.fail ("persisted conversation invalid: " ^ msg));
      let empty_assistant = List.exists (fun (m : message) ->
        m.role = Assistant && m.content_blocks = [] && m.tool_calls = None)
        conv.messages in
      Alcotest.(check bool) "no empty assistant message" false empty_assistant)

let () =
  Alcotest.run "engine_payload_validation" [
    "payload", [
      Alcotest.test_case "malformed_arguments_normalized" `Quick
        test_malformed_arguments_are_normalized;
      Alcotest.test_case "orphan_tool_result_rejected" `Quick
        test_orphan_tool_result_is_rejected_before_request;
      Alcotest.test_case "hallucinated_tool_calls_not_persisted" `Quick
        test_hallucinated_tool_calls_not_persisted;
      Alcotest.test_case "hallucinated_tool_calls_without_text" `Quick
        test_hallucinated_tool_calls_without_text;
    ]
  ]
