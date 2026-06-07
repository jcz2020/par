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
    stream_fn = (fun _ _ _ _ _ ->
       Ok { final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
  }

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let dummy_tool ?(name = "test_tool") handler =
  let descriptor = { name; description = "A test tool"; input_schema = `Assoc [];
    permission = Allow; timeout = None; concurrency_limit = None; on_update = None } in
  { descriptor; handler }

let basic_agent ?(tools = []) ?(middleware = []) ?(max_iterations = 10) () =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id = "test-agent"; system_prompt = "You are a test agent.";
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations; middleware;
    retry_policy = None; context_strategy = None; resource_quota = None }

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

let is_tool_lifecycle ev =
  match ev with
  | Tool_invoked _ | Tool_completed _ | Tool_failed _ -> true
  | _ -> false

let test_invoked_then_completed_on_success () =
  let events : event list ref = ref [] in
  let capture ev = events := ev :: !events in
  let tool = dummy_tool ~name:"good_tool"
    (fun _ _ -> Success (`String "ok")) in
  let call : tool_call = {
    id = "tc-good"; name = "good_tool"; arguments = `Assoc []
  } in
  let llm = mock_llm [
    tool_call_response [ call ];
    text_response "done after tool";
  ] in
  let agent = basic_agent ~tools:[ tool ] () in
  let reg = make_registry [ tool ] in
  with_token (fun token ->
    let result = Engine.run_agent
      ~on_tool_event:(Some capture)
      token agent "do something" llm reg in
    match result with
    | Ok _ ->
      let tool_events = List.filter is_tool_lifecycle (List.rev !events) in
      Alcotest.(check int) "two tool events" 2 (List.length tool_events);
      (match List.nth tool_events 0 with
       | Tool_invoked { tool_name; _ } ->
         Alcotest.(check string) "invoked name" "good_tool" tool_name
       | _ -> Alcotest.fail "first event should be Tool_invoked");
      (match List.nth tool_events 1 with
       | Tool_completed { tool_name; duration_ms; _ } ->
         Alcotest.(check string) "completed name" "good_tool" tool_name;
         Alcotest.(check bool) "duration >= 0" true (duration_ms >= 0.0)
       | _ -> Alcotest.fail "second event should be Tool_completed")
    | Error (e, _) ->
      Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e))

let test_invoked_then_failed_on_error () =
  let events : event list ref = ref [] in
  let capture ev = events := ev :: !events in
  let tool = dummy_tool ~name:"bad_tool"
    (fun _ _ ->
      Error { category = Internal "boom";
              message = "boom";
              retryable = false;
              metadata = [] }) in
  let call : tool_call = {
    id = "tc-bad"; name = "bad_tool"; arguments = `Assoc []
  } in
  let llm = mock_llm [
    tool_call_response [ call ];
    text_response "recovered after error";
  ] in
  let agent = basic_agent ~tools:[ tool ] () in
  let reg = make_registry [ tool ] in
  with_token (fun token ->
    let result = Engine.run_agent
      ~on_tool_event:(Some capture)
      token agent "do bad" llm reg in
    match result with
    | Ok _ ->
      let tool_events = List.filter is_tool_lifecycle (List.rev !events) in
      Alcotest.(check int) "two tool events" 2 (List.length tool_events);
      (match List.nth tool_events 0 with
       | Tool_invoked { tool_name; _ } ->
         Alcotest.(check string) "invoked name" "bad_tool" tool_name
       | _ -> Alcotest.fail "first event should be Tool_invoked");
      (match List.nth tool_events 1 with
       | Tool_failed { tool_name; error; _ } -> begin
           Alcotest.(check string) "failed name" "bad_tool" tool_name;
           match error with
           | Internal msg ->
             Alcotest.(check string) "error msg" "boom" msg
           | _ -> Alcotest.fail "expected Internal error"
         end
       | _ -> Alcotest.fail "second event should be Tool_failed")
    | Error (e, _) ->
      Alcotest.fail ("expected Ok (recovered), got Error: " ^ error_to_string e))

let test_duration_is_positive () =
  let events : event list ref = ref [] in
  let capture ev = events := ev :: !events in
  let tool = dummy_tool ~name:"slow_tool" (fun _ _ ->
    Unix.sleepf 0.01;
    Success (`String "done")
  ) in
  let call : tool_call = {
    id = "tc-slow"; name = "slow_tool"; arguments = `Assoc []
  } in
  let llm = mock_llm [
    tool_call_response [ call ];
    text_response "ok after slow";
  ] in
  let agent = basic_agent ~tools:[ tool ] () in
  let reg = make_registry [ tool ] in
  with_token (fun token ->
    let _ = Engine.run_agent
      ~on_tool_event:(Some capture)
      token agent "go slow" llm reg in
    let completed = List.find_map (fun ev ->
      match ev with
      | Tool_completed { tool_name = "slow_tool"; duration_ms; _ } ->
        Some duration_ms
      | _ -> None
    ) (List.rev !events) in
    match completed with
    | Some d ->
      Alcotest.check Alcotest.bool "duration > 0" true (d > 0.0);
      Alcotest.check Alcotest.bool "duration >= 10ms" true (d >= 10.0)
    | None -> Alcotest.fail "no Tool_completed event captured")

let test_backward_compat_no_callback () =
  let tool = dummy_tool ~name:"compat_tool"
    (fun _ _ -> Success (`String "ok")) in
  let call : tool_call = {
    id = "tc-compat"; name = "compat_tool"; arguments = `Assoc []
  } in
  let llm = mock_llm [
    tool_call_response [ call ];
    text_response "ok done";
  ] in
  let agent = basic_agent ~tools:[ tool ] () in
  let reg = make_registry [ tool ] in
  with_token (fun token ->
    let result = Engine.run_agent
      token agent "test compat" llm reg in
    match result with
    | Ok (resp, _) ->
      Alcotest.(check (option string)) "text" (Some "ok done") resp.text
    | Error (e, _) ->
      Alcotest.fail ("expected Ok without on_tool_event, got Error: "
                     ^ error_to_string e))

let () =
  let open Alcotest in
  run "tool_events" [
    "engine_tool_events", [
      test_case "Tool_invoked then Tool_completed on success" `Quick
        test_invoked_then_completed_on_success;
      test_case "Tool_invoked then Tool_failed on error" `Quick
        test_invoked_then_failed_on_error;
      test_case "duration is positive after sleep" `Quick
        test_duration_is_positive;
      test_case "backward compat: no on_tool_event still works" `Quick
        test_backward_compat_no_callback;
    ];
  ]
