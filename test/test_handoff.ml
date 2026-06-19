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

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let str_contains haystack needle =
  let rec aux i =
    if i + String.length needle > String.length haystack then false
    else if String.sub haystack i (String.length needle) = needle then true
    else aux (i + 1)
  in
  aux 0

let make_tool ?(name = "tool") handler : tool_binding =
  let descriptor = {
    name;
    description = "A test tool";
    input_schema = `Assoc [];
    output_schema = None;
    permission = Allow;
    timeout = None;
    concurrency_limit = None;
    on_update = None
  } in
  { descriptor; handler }

let make_agent ?(max_iterations = 10) id system_prompt tools : agent_config =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id; system_prompt; system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations;
    middleware = []; retry_policy = None; context_strategy = None;
    resource_quota = None }

let make_registry tools =
  let reg = Tool_registry.create () in
  List.iter (fun (tb : tool_binding) ->
    ignore (Tool_registry.register reg tb.descriptor tb.handler)
  ) tools;
  reg

let system_prompt_of conv =
  match conv.messages with
  | { role = System; content = Some s; _ } :: _ -> Some s
  | _ -> None

let mock_llm_dynamic f : llm_service =
  { complete_fn = (fun _model _tools conv -> Ok (f conv));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
  }

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"

let check_ok_text resp expected =
  match resp with
  | Ok (r, _) ->
      Alcotest.(check (option string)) "text" (Some expected) r.text
  | Error (e, _) ->
      Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)

let handoff_call ?(id = "tc-handoff") ?(name = "handoff") () : tool_call =
  { id; name; arguments = `Assoc [] }

let () =
  Alcotest.run "PAR Handoff" [
    ("Handoff", [
      Alcotest.test_case "carry_context=true passes history to target" `Quick (fun () ->
        let b_conv = ref None in
        let llm = mock_llm_dynamic (fun conv ->
          match system_prompt_of conv with
          | Some "You are B" ->
              b_conv := Some conv;
              text_response "B response"
          | _ ->
              tool_call_response [ handoff_call () ]
        ) in
        let handoff_tool = make_tool ~name:"handoff" (fun _ _ ->
          Handoff { target_agent_id = "B"; carry_context = true; task = None })
        in
        let agent_a = make_agent "A" "You are A" [ handoff_tool ] in
        let agent_b = make_agent "B" "You are B" [] in
        let reg = make_registry [ handoff_tool ] in
        let resolver = function
          | "B" -> Some agent_b
          | _ -> None
        in
        with_token (fun token ->
          check_ok_text
            (Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
               token agent_a "user question" llm reg)
            "B response";
          match !b_conv with
          | None -> Alcotest.fail "agent B was never called"
          | Some conv ->
              let has_user = List.exists (fun (m : message) ->
                m.role = User && m.content = Some "user question") conv.messages in
              let has_assistant = List.exists (fun (m : message) ->
                m.role = Assistant) conv.messages in
              Alcotest.check Alcotest.bool "B saw user history" true has_user;
              Alcotest.check Alcotest.bool "B saw assistant history" true has_assistant));

      Alcotest.test_case "carry_context=false with task starts fresh" `Quick (fun () ->
        let b_conv = ref None in
        let llm = mock_llm_dynamic (fun conv ->
          match system_prompt_of conv with
          | Some "You are B" ->
              b_conv := Some conv;
              text_response "B done"
          | _ ->
              tool_call_response [ handoff_call () ]
        ) in
        let handoff_tool = make_tool ~name:"handoff" (fun _ _ ->
          Handoff { target_agent_id = "B"; carry_context = false;
                    task = Some "Summarize the discussion" })
        in
        let agent_a = make_agent "A" "You are A" [ handoff_tool ] in
        let agent_b = make_agent "B" "You are B" [] in
        let reg = make_registry [ handoff_tool ] in
        let resolver = function "B" -> Some agent_b | _ -> None in
        with_token (fun token ->
          check_ok_text
            (Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
               token agent_a "user question" llm reg)
            "B done";
          match !b_conv with
          | None -> Alcotest.fail "agent B was never called"
          | Some conv ->
              let non_system = List.filter (fun (m : message) -> m.role <> System) conv.messages in
              Alcotest.(check int) "B has exactly one user message" 1 (List.length non_system);
              match non_system with
              | [ { role = User; content = Some "Summarize the discussion"; _ } ] -> ()
              | _ -> Alcotest.fail "B did not receive exactly the task as user message"));

      Alcotest.test_case "carry_context=false without task is rejected" `Quick (fun () ->
        let llm = mock_llm_dynamic (fun _ ->
          tool_call_response [ handoff_call () ])
        in
        let handoff_tool = make_tool ~name:"handoff" (fun _ _ ->
          Handoff { target_agent_id = "B"; carry_context = false; task = None })
        in
        let agent_a = make_agent "A" "You are A" [ handoff_tool ] in
        let agent_b = make_agent "B" "You are B" [] in
        let reg = make_registry [ handoff_tool ] in
        let resolver = function "B" -> Some agent_b | _ -> None in
        with_token (fun token ->
          match Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
                  token agent_a "hi" llm reg with
          | Ok _ -> Alcotest.fail "expected Error for missing task"
          | Error (Invalid_input msg, _) ->
              Alcotest.check Alcotest.bool "mentions task requirement" true
                (str_contains msg "requires a task")
          | Error (e, _) ->
              Alcotest.fail ("expected Invalid_input, got: " ^ error_to_string e)));

      Alcotest.test_case "handoff to unregistered agent fails" `Quick (fun () ->
        let llm = mock_llm_dynamic (fun _ ->
          tool_call_response [ handoff_call () ])
        in
        let handoff_tool = make_tool ~name:"handoff" (fun _ _ ->
          Handoff { target_agent_id = "nonexistent"; carry_context = true; task = None })
        in
        let agent_a = make_agent "A" "You are A" [ handoff_tool ] in
        let reg = make_registry [ handoff_tool ] in
        with_token (fun token ->
          match Engine.run_agent ~agent_resolver:(fun _ -> None)
                  ~enable_handoff:true token agent_a "hi" llm reg with
          | Ok _ -> Alcotest.fail "expected Error for missing target"
          | Error (Invalid_input msg, _) ->
              Alcotest.check Alcotest.bool "mentions not found" true
                (str_contains msg "not found")
          | Error (e, _) ->
              Alcotest.fail ("expected Invalid_input, got: " ^ error_to_string e)));

      Alcotest.test_case "multiple handoffs in one batch rejected" `Quick (fun () ->
        let llm = mock_llm_dynamic (fun _ ->
          tool_call_response [
            handoff_call ~id:"tc-b" ~name:"handoff_b" ();
            handoff_call ~id:"tc-c" ~name:"handoff_c" ();
          ])
        in
        let handoff_b = make_tool ~name:"handoff_b" (fun _ _ ->
          Handoff { target_agent_id = "B"; carry_context = true; task = None })
        in
        let handoff_c = make_tool ~name:"handoff_c" (fun _ _ ->
          Handoff { target_agent_id = "C"; carry_context = true; task = None })
        in
        let agent_a = make_agent "A" "You are A" [ handoff_b; handoff_c ] in
        let agent_b = make_agent "B" "You are B" [] in
        let agent_c = make_agent "C" "You are C" [] in
        let reg = make_registry [ handoff_b; handoff_c ] in
        let resolver = function
          | "B" -> Some agent_b
          | "C" -> Some agent_c
          | _ -> None
        in
        with_token (fun token ->
          match Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
                  ~parallel:true token agent_a "hi" llm reg with
          | Ok _ -> Alcotest.fail "expected Error for multiple handoffs"
          | Error (Invalid_input msg, _) ->
              Alcotest.check Alcotest.bool "mentions multiple handoffs" true
                (str_contains msg "Multiple handoffs")
          | Error (e, _) ->
              Alcotest.fail ("expected Invalid_input, got: " ^ error_to_string e)));

      Alcotest.test_case "handoff disabled returns error" `Quick (fun () ->
        let llm = mock_llm_dynamic (fun _ ->
          tool_call_response [ handoff_call () ])
        in
        let handoff_tool = make_tool ~name:"handoff" (fun _ _ ->
          Handoff { target_agent_id = "B"; carry_context = true; task = None })
        in
        let agent_a = make_agent "A" "You are A" [ handoff_tool ] in
        let agent_b = make_agent "B" "You are B" [] in
        let reg = make_registry [ handoff_tool ] in
        let resolver = function "B" -> Some agent_b | _ -> None in
        with_token (fun token ->
          match Engine.run_agent ~agent_resolver:resolver
                  token agent_a "hi" llm reg with
          | Ok _ -> Alcotest.fail "expected Error when handoff disabled"
          | Error (Invalid_input msg, _) ->
              Alcotest.check Alcotest.bool "mentions enable_handoff=false" true
                (str_contains msg "enable_handoff=false")
          | Error (e, _) ->
              Alcotest.fail ("expected Invalid_input, got: " ^ error_to_string e)));

      Alcotest.test_case "agent_handoff event is emitted" `Quick (fun () ->
        let events = ref [] in
        let llm = mock_llm_dynamic (fun conv ->
          match system_prompt_of conv with
          | Some "You are B" -> text_response "B response"
          | _ -> tool_call_response [ handoff_call () ])
        in
        let handoff_tool = make_tool ~name:"handoff" (fun _ _ ->
          Handoff { target_agent_id = "B"; carry_context = true; task = None })
        in
        let agent_a = make_agent "A" "You are A" [ handoff_tool ] in
        let agent_b = make_agent "B" "You are B" [] in
        let reg = make_registry [ handoff_tool ] in
        let resolver = function "B" -> Some agent_b | _ -> None in
        with_token (fun token ->
          check_ok_text
            (Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
               ~on_tool_event:(Some (fun ev -> events := ev :: !events))
               token agent_a "hi" llm reg)
            "B response";
          let found = List.exists (function
            | Agent_handoff { from_agent = "A"; to_agent = "B"; _ } -> true
            | _ -> false) !events in
          Alcotest.check Alcotest.bool "Agent_handoff event emitted" true found));

      Alcotest.test_case "running global max-of-chain allows B to run" `Quick (fun () ->
        let b_conv = ref None in
        let call_count = ref 0 in
        let handoff_tool = make_tool ~name:"counter" (fun _ _ ->
          incr call_count;
          if !call_count >= 5 then
            Handoff { target_agent_id = "B"; carry_context = true; task = None }
          else
            Success (`String ("count " ^ string_of_int !call_count)))
        in
        let llm = mock_llm_dynamic (fun conv ->
          match system_prompt_of conv with
          | Some "You are B" ->
              b_conv := Some conv;
              text_response "B response"
          | _ -> tool_call_response [ handoff_call ~name:"counter" () ]
        ) in
        let agent_a = make_agent ~max_iterations:10 "A" "You are A" [ handoff_tool ] in
        let agent_b = make_agent ~max_iterations:3 "B" "You are B" [] in
        let reg = make_registry [ handoff_tool ] in
        let resolver = function "B" -> Some agent_b | _ -> None in
        with_token (fun token ->
          check_ok_text
            (Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
               token agent_a "start" llm reg)
            "B response";
          Alcotest.check Alcotest.int "handoff happened after 5 calls" 5 !call_count;
          match !b_conv with
          | None -> Alcotest.fail "agent B was never called"
          | Some _ -> ()));

      Alcotest.test_case "system prompt swapped to target agent" `Quick (fun () ->
        let b_conv = ref None in
        let llm = mock_llm_dynamic (fun conv ->
          match system_prompt_of conv with
          | Some "You are B" ->
              b_conv := Some conv;
              text_response "B response"
          | _ -> tool_call_response [ handoff_call () ]
        ) in
        let handoff_tool = make_tool ~name:"handoff" (fun _ _ ->
          Handoff { target_agent_id = "B"; carry_context = true; task = None })
        in
        let agent_a = make_agent "A" "You are A" [ handoff_tool ] in
        let agent_b = make_agent "B" "You are B" [] in
        let reg = make_registry [ handoff_tool ] in
        let resolver = function "B" -> Some agent_b | _ -> None in
        with_token (fun token ->
          check_ok_text
            (Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
               token agent_a "hi" llm reg)
            "B response";
          match !b_conv with
          | None -> Alcotest.fail "agent B was never called"
          | Some conv ->
              match system_prompt_of conv with
              | Some "You are B" -> ()
              | Some s -> Alcotest.fail ("B saw wrong system prompt: " ^ s)
              | None -> Alcotest.fail "B had no system prompt"));

      Alcotest.test_case "non-handoff results preserved for target" `Quick (fun () ->
        let b_conv = ref None in
        let llm = mock_llm_dynamic (fun conv ->
          match system_prompt_of conv with
          | Some "You are B" ->
              b_conv := Some conv;
              text_response "B response"
          | _ ->
              tool_call_response [
                handoff_call ~id:"tc-x" ~name:"tool_x" ();
                handoff_call ~id:"tc-y" ~name:"tool_y" ();
              ])
        in
        let tool_x = make_tool ~name:"tool_x" (fun _ _ ->
          Success (`String "x-result"))
        in
        let tool_y = make_tool ~name:"tool_y" (fun _ _ ->
          Handoff { target_agent_id = "B"; carry_context = true; task = None })
        in
        let agent_a = make_agent "A" "You are A" [ tool_x; tool_y ] in
        let agent_b = make_agent "B" "You are B" [] in
        let reg = make_registry [ tool_x; tool_y ] in
        let resolver = function "B" -> Some agent_b | _ -> None in
        with_token (fun token ->
          check_ok_text
            (Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
               ~parallel:true token agent_a "hi" llm reg)
            "B response";
          match !b_conv with
          | None -> Alcotest.fail "agent B was never called"
          | Some conv ->
              let has_x_result = List.exists (fun (m : message) ->
                m.role = Tool &&
                Option.fold ~none:false ~some:(fun c -> str_contains c "x-result") m.content
              ) conv.messages in
              Alcotest.check Alcotest.bool "B saw tool_x result" true has_x_result));

      Alcotest.test_case "max iterations exceeded after handoff" `Quick (fun () ->
        let call_count = ref 0 in
        let handoff_tool = make_tool ~name:"counter" (fun _ _ ->
          incr call_count;
          if !call_count >= 5 then
            Handoff { target_agent_id = "B"; carry_context = true; task = None }
          else
            Success (`String ("count " ^ string_of_int !call_count)))
        in
        let llm = mock_llm_dynamic (fun _ ->
          tool_call_response [ handoff_call ~name:"counter" () ])
        in
        let agent_a = make_agent ~max_iterations:5 "A" "You are A" [ handoff_tool ] in
        let agent_b = make_agent ~max_iterations:5 "B" "You are B" [] in
        let reg = make_registry [ handoff_tool ] in
        let resolver = function "B" -> Some agent_b | _ -> None in
        with_token (fun token ->
          match Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
                  token agent_a "start" llm reg with
          | Ok _ -> Alcotest.fail "expected Error for max iterations"
          | Error (Internal msg, _) ->
              Alcotest.check Alcotest.bool "mentions Max iterations" true
                (str_contains msg "Max iterations")
          | Error (e, _) ->
              Alcotest.fail ("expected Internal, got: " ^ error_to_string e)));

      Alcotest.test_case "extract_task_id returns Agent_handoff task_id" `Quick (fun () ->
        let task_id = Task_id.create () in
        let event = Agent_handoff { from_agent = "A"; to_agent = "B"; task_id } in
        Alcotest.(check string) "task_id"
          (Task_id.to_string task_id)
          (Persistence_common.extract_task_id event));
    ])
  ]
