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
    | None -> text_response "default"
  in
  { complete_fn = (fun _model _tools _conv -> Ok (next ()));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
  }

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let dummy_tool ?(name = "test_tool") handler =
  let descriptor = { name; description = "A test tool"; input_schema = `Assoc [];
    permission = Allow; timeout = None; concurrency_limit = None } in
  { descriptor; handler }

let basic_agent ?(tools = []) ?(middleware = []) ?(max_iterations = 10) () =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id = "test-agent"; system_prompt = "You are a test agent.";
    model = dummy_model; tools = descriptors; max_iterations; middleware;
    retry_policy = None; context_strategy = None; resource_quota = None }

let make_registry tools =
  let reg = Tool_registry.create () in
  List.iter (fun (tb : tool_binding) ->
    Tool_registry.register reg tb.descriptor tb.handler
  ) tools;
  reg

let check_ok_text resp expected =
  match resp with
  | Ok r ->
      Alcotest.(check (option string)) "text" (Some expected) r.text
  | Error e ->
      Alcotest.fail ("expected Ok, got Error: " ^ (match e with
        | Internal s -> s | Invalid_input s -> s | _ -> "other"))

let agent_loop_suite =
  ("Agent loop", [
    Alcotest.test_case "mock LLM returns text response" `Quick (fun () ->
      let llm = mock_llm [ text_response "hello world" ] in
      let agent = basic_agent () in
      let reg = make_registry [] in
      with_token (fun token ->
        check_ok_text (Engine.run_agent token agent "hi" llm reg) "hello world"));

    Alcotest.test_case "mock LLM triggers tool call then stops" `Quick (fun () ->
      let tool = dummy_tool (fun _ _ -> Success (`String "tool-result")) in
      let call : tool_call = {
        id = "tc-1"; name = "test_tool"; arguments = `Assoc []
      } in
      let llm = mock_llm [
        tool_call_response [ call ];
        text_response "done after tool";
      ] in
      let agent = basic_agent ~tools:[ tool ] () in
      let reg = make_registry [ tool ] in
      with_token (fun token ->
        check_ok_text
          (Engine.run_agent token agent "do something" llm reg)
          "done after tool"));

    Alcotest.test_case "max iterations exceeded" `Quick (fun () ->
      let call : tool_call = {
        id = "tc-loop"; name = "test_tool"; arguments = `Assoc []
      } in
      let llm = mock_llm [
        tool_call_response [ call ];
        tool_call_response [ call ];
        tool_call_response [ call ];
      ] in
      let tool = dummy_tool (fun _ _ -> Success `Null) in
      let agent = basic_agent ~tools:[ tool ] ~max_iterations:2 () in
      let reg = make_registry [ tool ] in
      with_token (fun token ->
        (match Engine.run_agent token agent "loop" llm reg with
         | Error (Internal msg) ->
             Alcotest.check Alcotest.bool "contains 'Max'" true
               (String.contains msg 'M')
         | Ok _ -> Alcotest.fail "expected Error (max iterations)"
         | Error _ -> Alcotest.fail "expected Internal error")));

    Alcotest.test_case "tool not found" `Quick (fun () ->
      let call : tool_call = {
        id = "tc-1"; name = "nonexistent_tool"; arguments = `Assoc []
      } in
      let llm = mock_llm [
        tool_call_response [ call ];
        text_response "recovered";
      ] in
      let agent = basic_agent () in
      let reg = make_registry [] in
      with_token (fun token ->
        (match Engine.run_agent token agent "bad tool" llm reg with
         | Ok _ -> ()
         | Error e ->
             Alcotest.fail ("unexpected error: " ^ (match e with
               | Internal s -> s | Invalid_input s -> s | _ -> "other")))));

    Alcotest.test_case "middleware chain composition" `Quick (fun () ->
      let transformed = ref false in
      let mw_before : middleware_hook = {
        name = "add-marker";
        on_before_llm = Some (fun conv ->
          transformed := true;
          let sys_msg = {
            role = System;
            content = Some "modified system prompt";
            tool_calls = None; tool_call_id = None; name = None
          } in
          Some { conv with messages = sys_msg :: conv.messages });
        on_after_llm = None;
        on_before_tool = None;
        on_after_tool = None;
        on_error = None;
      } in
      let mw_after : middleware_hook = {
        name = "modify-response";
        on_before_llm = None;
        on_after_llm = Some (fun resp ->
          match resp.text with
          | Some t -> Some { resp with text = Some (t ^ " [modified]") }
          | None -> None);
        on_before_tool = None;
        on_after_tool = None;
        on_error = None;
      } in
      let llm = mock_llm [ text_response "original" ] in
      let agent = basic_agent ~middleware:[ mw_before; mw_after ] () in
      let reg = make_registry [] in
      with_token (fun token ->
        check_ok_text (Engine.run_agent token agent "test" llm reg) "original [modified]";
        Alcotest.check Alcotest.bool "before_mw_ran" true !transformed));
  ])

let workflow_engine_suite =
  ("Workflow engine", [
    Alcotest.test_case "sequential steps" `Quick (fun () ->
      let tool = dummy_tool ~name:"my_tool"
        (fun _ _ -> Success (`String "tool-returned")) in
      let llm = mock_llm [ text_response "agent-returned" ] in
      let agent = basic_agent () in
      let reg = make_registry [ tool ] in
      with_token (fun token ->
        let ctx : Workflow_engine.exec_context = {
          variables = []; token;
          agent_resolver = (fun _ -> Some agent);
          tool_resolver = (fun _ -> Some tool.descriptor);
          llm; registry = reg; parallel_limit = 4; failure_policy = Fail_fast;
          workflow_resolver = (fun _ -> None);
          on_step_complete = None;
          workflow_run_id = None;
        } in
        let steps : workflow_step = Sequential [
          Tool_call { tool_name = "my_tool"; input = `Assoc [] };
          Agent_call { agent_id = "test-agent"; prompt_template = "hello" };
        ] in
        (match Workflow_engine.execute_step ctx steps with
         | Ok (`List [ a; b ]) ->
             Alcotest.(check string) "tool result" "\"tool-returned\""
               (Yojson.Safe.to_string a);
             Alcotest.(check string) "agent result" "\"agent-returned\""
               (Yojson.Safe.to_string b)
         | Ok _ -> Alcotest.fail "expected list of 2"
         | Error e ->
             Alcotest.fail ("expected Ok: " ^ (match e with
               | Internal s -> s | Invalid_input s -> s | _ -> "other")))));

    Alcotest.test_case "conditional step — true branch" `Quick (fun () ->
      let tool = dummy_tool (fun _ _ -> Success (`String "then-result")) in
      with_token (fun token ->
        let llm = mock_llm [] in
        let reg = make_registry [ tool ] in
        let ctx : Workflow_engine.exec_context = {
          variables = [("x", `Int 10)]; token;
          agent_resolver = (fun _ -> None);
          tool_resolver = (fun _ -> Some tool.descriptor);
          llm; registry = reg; parallel_limit = 4; failure_policy = Fail_fast;
          workflow_resolver = (fun _ -> None);
          on_step_complete = None;
          workflow_run_id = None;
        } in
        let step : workflow_step = Conditional {
          condition = Greater_than (Variable "x", Literal (`Int 5));
          then_step = Tool_call { tool_name = "test_tool"; input = `Assoc [] };
          else_step = Some (Tool_call {
              tool_name = "test_tool"; input = `String "else" });
        } in
        (match Workflow_engine.execute_step ctx step with
         | Ok json ->
             Alcotest.(check string) "then branch" "\"then-result\""
               (Yojson.Safe.to_string json)
         | Error e ->
             Alcotest.fail ("expected Ok: " ^ (match e with
               | Internal s -> s | _ -> "other")))));

    Alcotest.test_case "conditional step — false branch" `Quick (fun () ->
      let tool = dummy_tool (fun input _token ->
        match input with
        | `String "else" -> Success (`String "else-result")
        | _ -> Success (`String "then-result")) in
      with_token (fun token ->
        let llm = mock_llm [] in
        let reg = make_registry [ tool ] in
        let ctx : Workflow_engine.exec_context = {
          variables = [("x", `Int 1)]; token;
          agent_resolver = (fun _ -> None);
          tool_resolver = (fun _ -> Some tool.descriptor);
          llm; registry = reg; parallel_limit = 4; failure_policy = Fail_fast;
          workflow_resolver = (fun _ -> None);
          on_step_complete = None;
          workflow_run_id = None;
        } in
        let step : workflow_step = Conditional {
          condition = Greater_than (Variable "x", Literal (`Int 5));
          then_step = Tool_call { tool_name = "test_tool"; input = `Assoc [] };
          else_step = Some (Tool_call {
              tool_name = "test_tool"; input = `String "else" });
        } in
        (match Workflow_engine.execute_step ctx step with
         | Ok json ->
             Alcotest.(check string) "else branch" "\"else-result\""
               (Yojson.Safe.to_string json)
         | Error e ->
             Alcotest.fail ("expected Ok: " ^ (match e with
               | Internal s -> s | _ -> "other")))));

    Alcotest.test_case "map_reduce — collect_all" `Quick (fun () ->
      let tool = dummy_tool (fun input _token ->
        match input with
        | `Assoc [("item", v)] -> Success v
        | _ -> Success `Null) in
      with_token (fun token ->
        let llm = mock_llm [] in
        let reg = make_registry [ tool ] in
        let ctx : Workflow_engine.exec_context = {
          variables = [("items", `List [
              `Assoc [("item", `String "a")];
              `Assoc [("item", `String "b")];
              `Assoc [("item", `String "c")];
            ])];
          token;
          agent_resolver = (fun _ -> None);
          tool_resolver = (fun _ -> Some tool.descriptor);
          llm; registry = reg; parallel_limit = 4; failure_policy = Fail_fast;
          workflow_resolver = (fun _ -> None);
          on_step_complete = None;
          workflow_run_id = None;
        } in
        let step : workflow_step = Map_reduce {
          over = "items";
          step = Tool_call { tool_name = "test_tool"; input = `Assoc [] };
          reduce = `Collect_all;
        } in
        (match Workflow_engine.execute_step ctx step with
         | Ok (`List items) ->
             Alcotest.check Alcotest.int "3 results" 3 (List.length items)
         | Ok _ -> Alcotest.fail "expected list"
         | Error e ->
             Alcotest.fail ("expected Ok: " ^ (match e with
               | Internal s -> s | Invalid_input s -> s | _ -> "other")))));

    Alcotest.test_case "agent not found" `Quick (fun () ->
      with_token (fun token ->
        let llm = mock_llm [] in
        let reg = Tool_registry.create () in
        let ctx : Workflow_engine.exec_context = {
          variables = []; token;
          agent_resolver = (fun _ -> None);
          tool_resolver = (fun _ -> None);
          llm; registry = reg; parallel_limit = 4; failure_policy = Fail_fast;
          workflow_resolver = (fun _ -> None);
          on_step_complete = None;
          workflow_run_id = None;
        } in
        let step : workflow_step =
          Agent_call { agent_id = "nonexistent"; prompt_template = "hi" }
        in
        (match Workflow_engine.execute_step ctx step with
         | Error (Invalid_input msg) ->
             Alcotest.check Alcotest.bool "contains 'not found'" true
               (String.contains msg 'n')
         | Ok _ -> Alcotest.fail "expected Error for nonexistent agent"
         | Error _ -> ())));
  ])

let default_bus_config : event_bus_config =
  { buffer_capacity = 10; delivery = {
      max_delivery_attempts = 1; initial_retry_delay = 0.1;
      retry_backoff = Fixed 0.1; delivery_timeout = 1.0 };
    dlq_enabled = false; critical_event_types = [] }

let event_bus_suite =
  ("Event bus", [
    Alcotest.test_case "subscribe returns non-empty ID" `Quick (fun () ->
      let bus = Event_bus.create default_bus_config in
      let sub = Event_bus.subscribe bus (fun _ -> ()) in
      Alcotest.(check bool) "sub non-empty" true (String.length sub > 0);
      Event_bus.unsubscribe bus sub);

    Alcotest.test_case "multiple subscriptions are unique" `Quick (fun () ->
      let bus = Event_bus.create default_bus_config in
      let sub_a = Event_bus.subscribe bus (fun _ -> ()) in
      let sub_b = Event_bus.subscribe bus (fun _ -> ()) in
      Alcotest.(check bool) "different IDs" true (sub_a <> sub_b);
      Event_bus.unsubscribe bus sub_a;
      Event_bus.unsubscribe bus sub_b);

    Alcotest.test_case "re-subscribe after unsubscribe works" `Quick (fun () ->
      let bus = Event_bus.create default_bus_config in
      let sub1 = Event_bus.subscribe bus (fun _ -> ()) in
      Event_bus.unsubscribe bus sub1;
      let sub2 = Event_bus.subscribe bus (fun _ -> ()) in
      Alcotest.(check bool) "new sub non-empty" true (String.length sub2 > 0);
      Event_bus.unsubscribe bus sub2);

    Alcotest.test_case "create bus with different configs" `Quick (fun () ->
      let config : event_bus_config =
        { buffer_capacity = 5; delivery = {
            max_delivery_attempts = 3; initial_retry_delay = 0.5;
            retry_backoff = Exponential { base = 2.0; max_delay = 10.0 };
            delivery_timeout = 5.0 };
          dlq_enabled = true;
          critical_event_types = [ "Shutdown_initiated" ] } in
      let bus = Event_bus.create config in
      let dlq = Event_bus.get_dead_letters bus in
      Alcotest.(check int) "empty DLQ" 0 (List.length dlq));
  ])

let middleware_suite =
  ("Middleware", [
    Alcotest.test_case "retry middleware tracks attempts" `Quick (fun () ->
      let mw = Retry.retry () in
      (match mw.on_error with
       | Some on_error_fn ->
           (match on_error_fn Timeout with
            | Some (Error { metadata; _ }) ->
                (match List.assoc_opt "attempt" metadata with
                 | Some (`Int n) -> Alcotest.(check int) "attempt" 1 n
                 | _ -> Alcotest.fail "no attempt in metadata")
            | _ -> Alcotest.fail "expected Error result with metadata")
       | None -> Alcotest.fail "on_error should be Some"));

    Alcotest.test_case "PII mask middleware" `Quick (fun () ->
      let mw = Pii_mask.pii_mask () in
      let conv : conversation = {
        messages = [{ role = User;
          content = Some "contact me at user@example.com please";
          tool_calls = None; tool_call_id = None; name = None }];
        metadata = [] } in
      (match mw.on_before_llm with
       | Some before_fn ->
           (match before_fn conv with
            | Some masked ->
                (match masked.messages with
                 | [ msg ] ->
                     (match msg.content with
                      | Some text ->
                          Alcotest.(check bool) "email masked" true
                            (not (String.contains text '@'))
                      | None -> Alcotest.fail "content should exist")
                 | _ -> Alcotest.fail "expected 1 message")
            | None -> Alcotest.fail "should return Some (PII found)")
       | None -> Alcotest.fail "on_before_llm should be Some"));

    Alcotest.test_case "validation middleware rejects non-object args" `Quick (fun () ->
      let mw = Validation.validation ~strict:true () in
      let call : tool_call =
        { id = "tc-v"; name = "my_tool";
          arguments = `String "not-an-object" } in
      (match mw.on_before_tool with
       | Some before_fn ->
           (match before_fn call with
            | Some modified ->
                (match modified.arguments with
                 | `Assoc _ ->
                     Alcotest.(check string) "name preserved" "my_tool" modified.name
                 | _ -> Alcotest.fail "args should be replaced with Assoc")
            | None -> Alcotest.fail "should return Some (invalid args)")
       | None -> Alcotest.fail "on_before_tool should be Some"));

    Alcotest.test_case "validation passes valid args unchanged" `Quick (fun () ->
      let mw = Validation.validation () in
      let call : tool_call =
        { id = "tc-ok"; name = "ok_tool";
          arguments = `Assoc [("key", `String "value")] } in
      (match mw.on_before_tool with
       | Some before_fn ->
           (match before_fn call with
            | None -> ()
            | Some _ -> Alcotest.fail "valid args should pass through")
       | None -> Alcotest.fail "on_before_tool should be Some"));
  ])

let () =
  Alcotest.run "PAR Integration" [
    agent_loop_suite;
    workflow_engine_suite;
    event_bus_suite;
    middleware_suite;
  ]
