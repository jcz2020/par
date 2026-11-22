open Par


(* -------------------------------------------------------------------------- *)
(* End-to-end router (v0.18 W3)                                               *)
(* -------------------------------------------------------------------------- *)

let mock_path =
  let exe_dir = Filename.dirname Sys.executable_name in
  let sibling = Filename.concat exe_dir "mcp_mock_server.exe" in
  if Sys.file_exists sibling then sibling
  else Filename.concat (Sys.getcwd ()) "_build/default/test/mcp_mock_server.exe"

let dummy_usage : Types.usage_stats =
  { Types.prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let sampling_model : Types.model_config =
  { provider = `Openai; model_name = "sampling-mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None;
    context_window = None }

let test_runtime_config : Types.runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  mcp_sampling = Types.Auto {
    model = sampling_model;
    max_tokens = 64;
    max_requests_per_invoke = 2;
    timeout = 5.0;
  };
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = false;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
  max_tool_schema_tokens = None;
}

let test_sampling_policy_round_trips () =
  match Types.runtime_config_of_yojson
          (Types.runtime_config_to_yojson test_runtime_config) with
  | Ok config ->
    (match config.mcp_sampling with
     | Types.Auto { model; max_tokens; max_requests_per_invoke; timeout } ->
       Alcotest.(check int) "max tokens" 64 max_tokens;
       Alcotest.(check int) "request limit" 2 max_requests_per_invoke;
       Alcotest.(check (float 0.001)) "timeout" 5.0 timeout;
       Alcotest.(check string) "model" "sampling-mock" model.model_name
     | Types.Disabled -> Alcotest.fail "Auto policy decoded as Disabled")
  | Error e -> Alcotest.failf "config decode: %s" e

let run_router ~max_requests_per_invoke ~expect_sampled () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let tool_name = "echo" in
      let calls = ref 0 in
      let saw_sampled_text = ref false in
      let events = ref [] in
      let bus : Types.event_bus_service = {
        publish_fn = (fun event -> events := event :: !events);
        subscribe_fn = (fun _ -> "");
        unsubscribe_fn = (fun _ -> ());
        set_session_id_fn = (fun _ -> ());
        start_dispatcher_fn = (fun _ -> ());
      } in
      let llm : Types.llm_service = {
        complete_fn = (fun _model _tools conv ->
          incr calls;
          if !calls = 1 then
            Ok { text = None; reasoning = [];
                 tool_calls = Some [{ id = "call-mcp-1"; name = tool_name;
                                      arguments = `Assoc ["message", `String "hi"] }];
                 finish_reason = Types.Tool_calls; usage = dummy_usage;
                 model = "sampling-mock" }
          else begin
            let serialized =
              Yojson.Safe.to_string (Types.conversation_to_yojson conv)
            in
            if Str.string_match (Str.regexp ".*sampled:.*") serialized 0 then
              saw_sampled_text := true;
            Ok { text = Some "done"; reasoning = []; tool_calls = None;
                 finish_reason = Types.Stop; usage = dummy_usage;
                 model = "sampling-mock" }
          end);
        stream_fn = (fun _ _ _ _ _ ->
          Ok { final_usage = dummy_usage; finish_reason = Types.Stop;
               chunks_received = 0 });
        close_fn = (fun () -> ());
        complete_structured_fn = None;
        list_models_fn = None;
        supports_native_tools_fn = None;
        context_window_fn = None;
        cache_control_fn = None;
      } in
      let server : Mcp_types.server_config = Mcp_types.Stdio_server {
        name = "mock";
        command = mock_path;
        args = ["--sampling-on-tool-call"];
        env = [];
        cwd = None;
        startup_timeout = 5.0;
      } in
      let config = { test_runtime_config with
                       mcp_sampling = Types.Auto {
                         model = sampling_model;
                         max_tokens = 64;
                         max_requests_per_invoke;
                         timeout = 5.0;
                       } } in
      match Runtime.create ~event_bus:bus ~llm ~config ~mcp_servers:[server]
              ~mcp_clock:(Eio.Stdenv.clock env)
              ~mcp_process_mgr:(Eio.Stdenv.process_mgr env)
              ~mcp_net:(Eio.Stdenv.net env) sw with
      | Error e -> Alcotest.failf "create: %s" (Types.string_of_error_category e)
      | Ok rt ->
        Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () ->
          let descriptor =
            match List.find_opt
                    (fun (d : Types.tool_descriptor) -> d.name = tool_name)
                    (Runtime.mcp_tool_descriptors rt) with
            | Some d -> d
            | None ->
              Alcotest.failf "missing MCP tool %s (have: %s)" tool_name
                (String.concat ", "
                   (List.map (fun (d : Types.tool_descriptor) -> d.name)
                      (Runtime.mcp_tool_descriptors rt)))
          in
          let agent =
            match Runtime.make_agent ~id:"sampling-agent"
                    ~system_prompt:(Types.stable_prompt "sampling fixture")
                    ~model:sampling_model ~tools:[descriptor] () with
            | Ok a -> a
            | Error e -> Alcotest.failf "make_agent: %s"
                           (Types.string_of_error_category e)
          in
          (match Runtime.register_agent rt agent with
           | Ok () -> ()
           | Error e -> Alcotest.failf "register_agent: %s"
                          (Types.string_of_error_category e));
          match Runtime.invoke rt ~agent_id:"sampling-agent" ~message:"hi" () with
          | Error (e, _) -> Alcotest.failf "invoke: %s"
                              (Types.string_of_error_category e)
          | Ok _ ->
            let requested =
              List.exists (function
                | Types.Mcp_sampling_requested _ -> true
                | _ -> false) !events
            in
            let completed =
              List.exists (function
                | Types.Mcp_sampling_completed _ -> true
                | _ -> false) !events
            in
            let failed =
              List.exists (function
                | Types.Mcp_sampling_failed _ -> true
                | _ -> false) !events
            in
            if expect_sampled then begin
              Alcotest.(check int) "engine calls + one sampling call" 3 !calls;
              Alcotest.(check bool) "sampled text reached the model" true
                !saw_sampled_text;
              Alcotest.(check bool) "requested event" true requested;
              Alcotest.(check bool) "completed event" true completed;
              Alcotest.(check bool) "no failure event" false failed
            end else begin
              Alcotest.(check int) "no sampling LLM call" 2 !calls;
              Alcotest.(check bool) "no sampled text" false !saw_sampled_text;
              Alcotest.(check bool) "failure event" true failed;
              Alcotest.(check bool) "no completed event" false completed
            end))
  )

let test_sampling_router_answers_the_server () =
  run_router ~max_requests_per_invoke:2 ~expect_sampled:true ()

let test_sampling_budget_rejects_the_request () =
  run_router ~max_requests_per_invoke:0 ~expect_sampled:false ()

let () =
  Alcotest.run "mcp_sampling" [
    "sampling_constants", [
      Alcotest.test_case "method_sampling_create_name" `Quick (fun () ->
        Alcotest.(check string) "method name"
          "sampling/createMessage" Mcp_types.method_sampling_create);
    ];

    "sampling_request_roundtrip", [
      Alcotest.test_case "full_sampling_request_parses" `Quick (fun () ->
        let json = `Assoc [
          ("jsonrpc", `String "2.0");
          ("id", `Int 99);
          ("method", `String Mcp_types.method_sampling_create);
          ("params", `Assoc [
            ("messages", `List [
              `Assoc [("role", `String "user");
                      ("content", `Assoc [("type", `String "text"); ("text", `String "Summarize this")])];
            ]);
            ("maxTokens", `Int 500);
            ("systemPrompt", `String "You are a helpful assistant");
            ("temperature", `Float 0.7);
          ])
        ] in
        (match Mcp_types.jsonrpc_request_of_yojson json with
         | Ok req ->
           Alcotest.(check string) "method" Mcp_types.method_sampling_create req.Mcp_types.method_;
           Alcotest.(check bool) "has params" true (Option.is_some req.Mcp_types.params);
           (match req.Mcp_types.params with
            | Some (`Assoc params) ->
              (match List.assoc_opt "maxTokens" params with
               | Some (`Int 500) -> ()
               | _ -> Alcotest.fail "maxTokens not parsed correctly");
              (match List.assoc_opt "temperature" params with
               | Some (`Float f) -> Alcotest.(check (float 0.001)) "temperature" 0.7 f
               | _ -> Alcotest.fail "temperature not parsed")
            | _ -> Alcotest.fail "params not an object")
         | Error e -> Alcotest.fail ("parse failed: " ^ e)));

      Alcotest.test_case "sampling_request_serializes" `Quick (fun () ->
        let req : Mcp_types.jsonrpc_request = {
          id = Mcp_types.Int_id 7;
          method_ = Mcp_types.method_sampling_create;
          params = Some (`Assoc [
            ("maxTokens", `Int 100);
            ("messages", `List []);
          ]);
        } in
        let json = Mcp_types.request_to_yojson req in
        (match Mcp_types.jsonrpc_request_of_yojson json with
         | Ok parsed ->
           Alcotest.(check string) "roundtrip method"
             Mcp_types.method_sampling_create parsed.Mcp_types.method_
         | Error e -> Alcotest.fail ("roundtrip failed: " ^ e)));
    ];

    "runtime_router", [
      Alcotest.test_case "policy round-trips" `Quick
        test_sampling_policy_round_trips;
      Alcotest.test_case "stdio server receives a sampled answer" `Quick
        test_sampling_router_answers_the_server;
      Alcotest.test_case "budget rejects the request" `Quick
        test_sampling_budget_rejects_the_request;
    ];

    "sampling_response", [
      Alcotest.test_case "sampling_response_roundtrip" `Quick (fun () ->
        let resp : Mcp_types.jsonrpc_response = {
          id = Mcp_types.Int_id 7;
          result = Ok (`Assoc [
            ("role", `String "assistant");
            ("content", `Assoc [("type", `String "text"); ("text", `String "Generated text")]);
            ("model", `String "gpt-4");
            ("stopReason", `String "endTurn");
          ]);
        } in
        let json = Mcp_types.jsonrpc_response_to_yojson resp in
        (match Mcp_types.response_of_yojson json with
         | Ok parsed ->
           (match parsed.result with
            | Ok (`Assoc fields) ->
              (match List.assoc_opt "role" fields with
               | Some (`String "assistant") -> ()
               | _ -> Alcotest.fail "role field missing or wrong");
              (match List.assoc_opt "stopReason" fields with
               | Some (`String "endTurn") -> ()
               | _ -> Alcotest.fail "stopReason field missing or wrong")
            | _ -> Alcotest.fail "result not an object")
         | Error e -> Alcotest.fail ("response roundtrip failed: " ^ e)));

      Alcotest.test_case "sampling_error_response" `Quick (fun () ->
        let resp : Mcp_types.jsonrpc_response = {
          id = Mcp_types.String_id "err-1";
          result = Error { code = -32601; message = "Method not found"; data = None };
        } in
        let json = Mcp_types.jsonrpc_response_to_yojson resp in
        (match Mcp_types.response_of_yojson json with
         | Ok parsed ->
           (match parsed.result with
            | Error err ->
              Alcotest.(check int) "error code" (-32601) err.Mcp_types.code;
              Alcotest.(check string) "error message" "Method not found" err.Mcp_types.message
            | Ok _ -> Alcotest.fail "expected Error result")
         | Error e -> Alcotest.fail ("error response parse failed: " ^ e)));
    ];
  ]
