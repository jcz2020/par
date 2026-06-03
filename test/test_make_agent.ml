open Par
open Par.Types

let valid_model = {
  Types.provider = `Openai;
  model_name = "gpt-4";
  api_base = None;
  temperature = 0.7;
  max_tokens = None;
  top_p = None;
  stop_sequences = None;
}

let suite = [
  Alcotest.test_case "valid agent construction" `Quick (fun () ->
    match Runtime.make_agent
      ~id:"agent1"
      ~system_prompt:"hello"
      ~model:valid_model () with
    | Ok agent ->
      Alcotest.(check string) "id" "agent1" agent.id;
      Alcotest.(check string) "system_prompt" "hello" agent.system_prompt;
      Alcotest.(check int) "max_iterations" 10 agent.max_iterations
    | Error e -> Alcotest.failf "expected Ok, got: %s"
        (match e with Invalid_input m -> m | _ -> "other"));

  Alcotest.test_case "empty id rejected" `Quick (fun () ->
    match Runtime.make_agent
      ~id:""
      ~system_prompt:"hello"
      ~model:valid_model () with
    | Ok _ -> Alcotest.fail "expected Error for empty id"
    | Error (Invalid_input msg) ->
      Alcotest.(check bool) "error mentions id" true
        (String.contains msg 'i')
    | Error _ -> Alcotest.fail "wrong error type");

  Alcotest.test_case "empty system_prompt without template rejected" `Quick (fun () ->
    match Runtime.make_agent
      ~id:"a"
      ~system_prompt:""
      ~model:valid_model () with
    | Ok _ -> Alcotest.fail "expected Error"
    | Error (Invalid_input msg) ->
      Alcotest.(check bool) "error mentions system_prompt" true
        (String.contains msg 's' || String.contains msg 't')
    | Error _ -> Alcotest.fail "wrong error type");

  Alcotest.test_case "system_prompt_template can replace system_prompt" `Quick (fun () ->
    match Runtime.make_agent
      ~id:"a"
      ~system_prompt:""
      ~system_prompt_template:(Some {
        template = "Hello {{name}}";
        variables = [];
        required = [];
      })
      ~model:valid_model () with
    | Ok _ -> ()
    | Error e -> Alcotest.failf "expected Ok, got: %s"
        (match e with Invalid_input m -> m | _ -> "other"));

  Alcotest.test_case "max_iterations=0 rejected" `Quick (fun () ->
    match Runtime.make_agent
      ~id:"a"
      ~system_prompt:"hello"
      ~max_iterations:0
      ~model:valid_model () with
    | Ok _ -> Alcotest.fail "expected Error"
    | Error (Invalid_input msg) ->
      Alcotest.(check bool) "error mentions max_iterations" true
        (String.contains msg 'm')
    | Error _ -> Alcotest.fail "wrong error type");

  Alcotest.test_case "max_iterations=-1 rejected" `Quick (fun () ->
    match Runtime.make_agent
      ~id:"a"
      ~system_prompt:"hello"
      ~max_iterations:(-1)
      ~model:valid_model () with
    | Ok _ -> Alcotest.fail "expected Error"
    | Error _ -> ());

  Alcotest.test_case "duplicate tool names rejected" `Quick (fun () ->
    let tool_a = { name = "dup"; description = ""; input_schema = `Assoc [];
                   permission = Allow; timeout = None; concurrency_limit = None; on_update = None } in
    let tool_b = { name = "dup"; description = ""; input_schema = `Assoc [];
                   permission = Allow; timeout = None; concurrency_limit = None; on_update = None } in
    match Runtime.make_agent
      ~id:"a"
      ~system_prompt:"hello"
      ~model:valid_model
      ~tools:[tool_a; tool_b] () with
    | Ok _ -> Alcotest.fail "expected Error for duplicate tools"
    | Error (Invalid_input msg) ->
      Alcotest.(check bool) "error mentions duplicate" true
        (String.contains msg 'd' && String.contains msg 'p')
    | Error _ -> Alcotest.fail "wrong error type");

  Alcotest.test_case "empty tool name rejected" `Quick (fun () ->
    let bad_tool = { name = ""; description = ""; input_schema = `Assoc [];
                     permission = Allow; timeout = None; concurrency_limit = None; on_update = None } in
    match Runtime.make_agent
      ~id:"a"
      ~system_prompt:"hello"
      ~model:valid_model
      ~tools:[bad_tool] () with
    | Ok _ -> Alcotest.fail "expected Error"
    | Error _ -> ());

  Alcotest.test_case "make_agent integrates with register_agent" `Quick (fun () ->
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        let cfg = {
          Types.persistence = `Sqlite ":memory:";
          event_bus = Par.Runtime.default_event_bus_config;
          default_quota = Par.Runtime.default_quota;
          shutdown = Par.Runtime.default_shutdown_config;
          llm_providers = [];
          eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
        } in
        match Par.Runtime.create ~config:cfg sw with
        | Error _ -> Alcotest.fail "create failed"
        | Ok rt ->
          let agent = match Runtime.make_agent
            ~id:"test"
            ~system_prompt:"hi"
            ~model:valid_model () with
          | Ok a -> a
          | Error _ -> Alcotest.fail "make_agent failed" in
          (match Runtime.register_agent rt agent with
           | Ok () -> ()
           | Error _ -> Alcotest.fail "register_agent failed");
          ignore (Par.Runtime.close rt))));
]

let () =
  Alcotest.run "make_agent" [
    ("make_agent", suite);
  ]
