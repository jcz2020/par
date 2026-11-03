open Par
open Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None; context_window = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; reasoning = []; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let runtime_config : runtime_config =
  { persistence = `Sqlite ":memory:";
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = true;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = 604800.0;
    max_tool_schema_tokens = Some 1;
  }

let err_str (e : error_category) =
  Yojson.Safe.to_string (error_category_to_yojson e)

let tool_names (tools : tool_descriptor list) =
  List.map (fun (d : tool_descriptor) -> d.name) tools

let test_searchable_layer () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let seen = ref [] in
      let llm : llm_service = {
        complete_fn = (fun _model tools _conv ->
          seen := tool_names tools;
          Ok (text_response "ok"));
        stream_fn = (fun _ _ _ _ _ -> Error Timeout);
        close_fn = (fun () -> ());
        complete_structured_fn = None;
        list_models_fn = None;
        supports_native_tools_fn = None;
        context_window_fn = None; cache_control_fn = None;
      } in
      match Runtime.create ~llm ~config:runtime_config sw with
      | Error e -> Alcotest.fail ("create: " ^ err_str e)
      | Ok rt ->
        let handler _input _token = Success (`String "done") in
        let tb = match Runtime.register_tool rt
                       ~name:"hidden" ~description:"A searchable tool"
                       ~input_schema:(`Assoc [("type", `String "object")])
                       ~handler ~layer:Tool_registry.Searchable () with
          | Ok tb -> tb
          | Error e -> Alcotest.fail ("register: " ^ err_str e)
        in
        let agent = match Runtime.make_agent ~id:"a"
                        ~system_prompt:(stable_prompt "test")
                        ~model:dummy_model ~tools:[tb.descriptor] () with
          | Ok a -> a
          | Error e -> Alcotest.fail ("make_agent: " ^ err_str e)
        in
        (match Runtime.register_agent rt agent with
         | Ok () -> ()
         | Error e -> Alcotest.fail ("register_agent: " ^ err_str e));

        (match Runtime.invoke rt ~agent_id:"a" ~message:"one" () with
         | Ok _ -> ()
         | Error (e, _) -> Alcotest.fail ("invoke 1: " ^ err_str e));
        Alcotest.(check bool) "searchable tool hidden" false
          (List.mem "hidden" !seen);
        Alcotest.(check bool) "tool_search advertised" true
          (List.mem "tool_search" !seen);

        (match Runtime.set_tool_layer rt ~name:"hidden"
                 ~layer:Tool_registry.Always with
         | Ok () -> ()
         | Error e -> Alcotest.fail ("set layer: " ^ err_str e));
        (match Runtime.invoke rt ~agent_id:"a" ~message:"two" () with
         | Ok _ -> ()
         | Error (e, _) -> Alcotest.fail ("invoke 2: " ^ err_str e));
        Alcotest.(check bool) "always tool advertised" true
          (List.mem "hidden" !seen);

        (match Runtime.set_tool_layer rt ~name:"missing"
                 ~layer:Tool_registry.Searchable with
         | Ok () -> Alcotest.fail "expected Error for unknown tool"
         | Error (Invalid_input _) -> ()
         | Error e -> Alcotest.failf "expected Invalid_input, got %s" (err_str e))))

let test_facade_exports_think_tag_strip () =
  let _middleware = Par.Think_tag_strip.create () in
  ()

let () =
  Alcotest.run "tool_layers" [
    "layers", [
      Alcotest.test_case "searchable layer is hidden until promoted" `Quick
        test_searchable_layer;
      Alcotest.test_case "facade exports Think_tag_strip" `Quick
        test_facade_exports_think_tag_strip;
    ]
  ]
