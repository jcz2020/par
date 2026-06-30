open Par
open Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let mock_llm : llm_service = {
  complete_fn = (fun _ _ _ ->
    Ok { text = Some "mock"; tool_calls = None; finish_reason = Stop;
         usage = { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 };
         model = "mock" });
  stream_fn = (fun _ _ _ _ _ -> Error (Timeout));
  close_fn = ignore;
  complete_structured_fn = None;
  list_models_fn = None;
  supports_native_tools_fn = None;
  context_window_fn = None; cache_control_fn = None;
}

let tmp_db () =
  let p = Filename.temp_file "listagents" ".db" in
  Sys.remove p;
  p

let make_runtime_config db =
  {
    persistence = `Sqlite db;
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = true;
    bash_confirm = Types.default_bash_confirm_config;
    event_retention_seconds = 604800.0;
  }

let with_runtime f =
  let db = tmp_db () in
  let cleanup () = try Sys.remove db with _ -> () in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let config = make_runtime_config db in
      match Runtime.create ~llm:mock_llm ~config
          ~mcp_process_mgr:(Eio.Stdenv.process_mgr _env)
          ~mcp_clock:(Eio.Stdenv.clock _env)
          sw with
      | Error e -> cleanup (); Alcotest.fail ("Runtime.create failed: " ^ Yojson.Safe.to_string (error_category_to_yojson e))
      | Ok rt ->
        let result = f rt in
        ignore (Runtime.close rt);
        cleanup ();
        result))

let make_test_agent id =
  match Runtime.make_agent ~id ~system_prompt:(stable_prompt ("You are " ^ id))
          ~model:dummy_model ~max_iterations:5 () with
  | Ok a -> a
  | Error e -> Alcotest.fail ("make_agent failed: " ^ Yojson.Safe.to_string (error_category_to_yojson e))

let () =
  Alcotest.run "list_agents" [
    "list_agents", [
      Alcotest.test_case "empty runtime returns empty list" `Quick (fun () ->
        with_runtime (fun rt ->
          let agents = Runtime.list_agents rt in
          Alcotest.(check int) "empty list" 0 (List.length agents)));

      Alcotest.test_case "returns registered agents" `Quick (fun () ->
        with_runtime (fun rt ->
          let a1 = make_test_agent "alpha" in
          let a2 = make_test_agent "beta" in
          (match Runtime.register_agent rt a1 with
           | Error e -> Alcotest.fail ("register alpha: " ^ Yojson.Safe.to_string (error_category_to_yojson e))
           | Ok () -> ());
          (match Runtime.register_agent rt a2 with
           | Error e -> Alcotest.fail ("register beta: " ^ Yojson.Safe.to_string (error_category_to_yojson e))
           | Ok () -> ());
          let agents = Runtime.list_agents rt in
          let ids = List.map (fun (a : agent_config) -> a.id) agents in
          Alcotest.(check int) "two agents" 2 (List.length agents);
          Alcotest.(check bool) "contains alpha" true (List.mem "alpha" ids);
          Alcotest.(check bool) "contains beta" true (List.mem "beta" ids)));

      Alcotest.test_case "agent configs are complete" `Quick (fun () ->
        with_runtime (fun rt ->
          let a = make_test_agent "checker" in
          (match Runtime.register_agent rt a with
           | Ok () -> ()
           | Error _ -> Alcotest.fail "register failed");
          let agents = Runtime.list_agents rt in
          (match agents with
           | [ config ] ->
             Alcotest.(check string) "id matches" "checker" config.id;
             Alcotest.(check string) "system_prompt" "You are checker" (Types.prompt_text config.system_prompt);
             Alcotest.(check int) "max_iterations" 5 config.max_iterations
           | _ -> Alcotest.fail "expected exactly 1 agent")));
    ]
  ]
