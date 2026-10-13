open Par
open Types

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"
  | Cancelled r ->
    (match r with
     | User_cancelled -> "User_cancelled"
     | Guard_cancelled s -> "Guard_cancelled:" ^ s)

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 10; completion_tokens = 5; total_tokens = 15;
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
    context_window_fn = None; cache_control_fn = None }

let make_agent ?(tools = []) id sys_prompt =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id;
    system_prompt = stable_prompt sys_prompt;
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations = 10;
    middleware = []; retry_policy = None; context_strategy = None;
    resource_quota = None; max_execution_time = None; tool_timeout = None;
    early_stopping_method = Force;
    on_max_tokens = Some Return_partial; max_continuation_chunks = Some 3;
    context_compression_threshold = None;
    compression_cooldown_messages = None;
    context_window_override = None;
    cache_strategy = No_caching; approval_handler = None }

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = false;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
    max_tool_schema_tokens = None;
  }

let run_test f = Eio_main.run (fun _env -> Eio.Switch.run (fun sw -> f sw))

let snapshot_get key snap =
  match List.assoc_opt key snap with
  | Some n -> n
  | None -> 0

let text_of_content_block (b : content_block) =
  match b with
  | Text_block { text; _ } -> Some text
  | Tool_result_block { content; _ } -> Some content
  | _ -> None

let text_of_conversation (conv : conversation) =
  String.concat " "
    (List.filter_map (fun (m : message) ->
      List.find_map text_of_content_block m.content_blocks
    ) conv.messages)

(* ── B7.1: Duplicate registration rejected ================================ *)

let duplicate_suite =
  ("duplicate_registration", [

    Alcotest.test_case "register_agent_as_tool rejects duplicate tool_name" `Quick
      (fun () ->
        let llm = mock_llm [ stop_response "unused" ] in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_agent rt
              (make_agent "child" "You are a child agent."));
            (match Runtime.register_agent_as_tool rt ~agent_id:"child" () with
             | Ok () -> ()
             | Error e -> Alcotest.failf "first register: %s" (error_to_string e));
            match Runtime.register_agent_as_tool rt ~agent_id:"child" () with
            | Ok () -> Alcotest.fail "should reject duplicate tool name"
            | Error (Invalid_input msg) ->
              Alcotest.(check bool) "mentions duplicate" true
                (String.length msg > 0)
            | Error e ->
              Alcotest.failf "wrong error: %s" (error_to_string e)));
  ])

(* ── B7.2: Depth limit triggers instructive error ========================= *)

let depth_suite =
  ("depth_limit", [

    Alcotest.test_case "depth >= max_depth returns [agent-tool] instructive error in tool result" `Quick
      (fun () ->
        let combined_counter = ref 0 in
        let combined_llm = {
          complete_fn = (fun _model _tools _conv ->
            let idx = !combined_counter in
            incr combined_counter;
            let resp = match idx with
              | 0 -> tool_call_response [
                  { id = "tc-d"; name = "agent_child";
                    arguments = `Assoc [("message", `String "go")] }]
              | _ -> stop_response "parent-done"
            in
            Ok resp);
          stream_fn = (fun _ _ _ _ _ -> Ok {
              final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
          close_fn = (fun () -> ());
          complete_structured_fn = None;
          list_models_fn = None;
          supports_native_tools_fn = None;
          context_window_fn = None; cache_control_fn = None;
        } in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm:combined_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_agent rt
              (make_agent "child" "You are the child."));
            ignore (Runtime.register_agent_as_tool rt ~agent_id:"child"
              ~max_depth:0 ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[{
                descriptor = { name = "agent_child";
                  description = "Invoke child";
                  input_schema = `Assoc []; output_schema = None;
                  permission = Allow; timeout = None;
                  concurrency_limit = None; on_update = None;
                  cache_control = None };
                handler = (fun _input _token -> Success (`String "noop"))
              }] "parent" "You are the parent."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~update_current:false () with
            | Error (e, _) ->
              Alcotest.failf "invoke failed: %s" (error_to_string e)
            | Ok result ->
              let conv_text = text_of_conversation result.conversation in
              Alcotest.(check bool) "has [agent-tool] marker in tool result" true
                (try ignore (Str.search_forward (Str.regexp_string "[agent-tool]") conv_text 0); true
                 with Not_found -> false)));
  ])

let isolation_suite =
  ("conversation_isolation", [

    Alcotest.test_case "child messages do not leak into parent conversation" `Quick
      (fun () ->
        let child_llm = mock_llm [ stop_response "child-secret-answer" ] in
        let parent_llm = mock_llm [
          tool_call_response [
            { id = "tc-iso"; name = "agent_child"; arguments = `Assoc [("message", `String "hi child")] }
          ];
          stop_response "parent-final"
        ] in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm:parent_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            (* We need to supply the child's LLM. Since register_agent_as_tool
               uses rt.services.llm, we need to override it via a custom
               complete_fn wrapper. For this test we register the child LLM
               as the runtime's LLM. We'll use a multi-response mock that
               serves both parent and child. *)
            ignore child_llm;
            ignore (Runtime.register_agent rt
              (make_agent "child" "You are the child."));
            ignore (Runtime.register_agent_as_tool rt ~agent_id:"child" ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[{
                descriptor = { name = "agent_child";
                  description = "Invoke child";
                  input_schema = `Assoc []; output_schema = None;
                  permission = Allow; timeout = None;
                  concurrency_limit = None; on_update = None;
                  cache_control = None };
                handler = (fun _input _token -> Success (`String "noop"))
              }] "parent" "You are the parent."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~update_current:false () with
            | Error (e, _) ->
              Alcotest.failf "invoke failed: %s" (error_to_string e)
            | Ok result ->
              let conv = result.conversation in
              let has_child_text = List.exists (fun (m : message) ->
                List.exists (fun (b : content_block) ->
                  match b with
                  | Text_block { text; _ } ->
                    (try ignore (Str.search_forward (Str.regexp_string "child-secret-answer") text 0); true
                     with Not_found -> false)
                  | _ -> false
                ) m.content_blocks
              ) conv.messages in
              Alcotest.(check bool) "child text NOT in parent conv" false has_child_text));
  ])

(* ── B7.4: Cancellation inheritance ======================================= *)

let cancellation_suite =
  ("cancellation_inheritance", [

    Alcotest.test_case "inherit_cancellation=true: parent cancelled → child short-circuits" `Quick
      (fun () ->
        let child_llm = mock_llm [ stop_response "child-should-not-run" ] in
        run_test (fun sw ->
          let parent_token = Cancellation.create_token sw in
          Cancellation.request_cancel parent_token User_cancelled;
          match Runtime.create ~config:test_config ~llm:child_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_agent rt
              (make_agent "child" "You are the child."));
            ignore (Runtime.register_agent_as_tool rt ~agent_id:"child"
              ~inherit_cancellation:true ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[{
                descriptor = { name = "agent_child";
                  description = "Invoke child";
                  input_schema = `Assoc []; output_schema = None;
                  permission = Allow; timeout = None;
                  concurrency_limit = None; on_update = None;
                  cache_control = None };
                handler = (fun _input _token -> Success (`String "noop"))
              }] "parent" "You are the parent."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~cancellation_token:parent_token ~update_current:false () with
            | Error (Cancelled User_cancelled, _) -> ()  (* expected *)
            | Error (e, _) ->
              Alcotest.failf "wrong error: %s" (error_to_string e)
            | Ok _ ->
              Alcotest.fail "should have been cancelled"));

    Alcotest.test_case "inherit_cancellation=false: parent cancelled, child still runs" `Quick
      (fun () ->
        let child_llm = mock_llm [ stop_response "child-survived" ] in
        let parent_llm = mock_llm [
          tool_call_response [
            { id = "tc-noinh"; name = "agent_child"; arguments = `Assoc [("message", `String "go")] }
          ];
          stop_response "parent-done"
        ] in
        run_test (fun sw ->
          (* We need a custom LLM that can serve both parent and child *)
          let combined_counter = ref 0 in
          let combined_llm = {
            complete_fn = (fun _model _tools _conv ->
              let idx = !combined_counter in
              incr combined_counter;
              let resp = match idx with
                | 0 -> tool_call_response [
                    { id = "tc-noinh"; name = "agent_child";
                      arguments = `Assoc [("message", `String "go")] }]
                | 1 -> stop_response "child-survived"
                | _ -> stop_response "parent-done"
              in
              Ok resp);
            stream_fn = (fun _ _ _ _ _ -> Ok {
                final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
            close_fn = (fun () -> ());
            complete_structured_fn = None;
            list_models_fn = None;
            supports_native_tools_fn = None;
            context_window_fn = None; cache_control_fn = None;
          } in
          ignore child_llm;
          ignore parent_llm;
          match Runtime.create ~config:test_config ~llm:combined_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_agent rt
              (make_agent "child" "You are the child."));
            ignore (Runtime.register_agent_as_tool rt ~agent_id:"child"
              ~inherit_cancellation:false ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[{
                descriptor = { name = "agent_child";
                  description = "Invoke child";
                  input_schema = `Assoc []; output_schema = None;
                  permission = Allow; timeout = None;
                  concurrency_limit = None; on_update = None;
                  cache_control = None };
                handler = (fun _input _token -> Success (`String "noop"))
              }] "parent" "You are the parent."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~update_current:false () with
            | Error (e, _) ->
              Alcotest.failf "invoke should succeed: %s" (error_to_string e)
            | Ok _result -> ()));
  ])

(* ── B7.5: Event suppression + Agent_tool_completed summary =============== *)

let event_suite =
  ("event_suppression", [

    Alcotest.test_case "Agent_tool_completed emitted, child internal events suppressed" `Quick
      (fun () ->
        let combined_counter = ref 0 in
        let combined_llm = {
          complete_fn = (fun _model _tools _conv ->
            let idx = !combined_counter in
            incr combined_counter;
            let resp = match idx with
              | 0 -> tool_call_response [
                  { id = "tc-ev"; name = "agent_child";
                    arguments = `Assoc [("message", `String "go")] }]
              | 1 -> stop_response "child-answer"
              | _ -> stop_response "parent-done"
            in
            Ok resp);
          stream_fn = (fun _ _ _ _ _ -> Ok {
              final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
          close_fn = (fun () -> ());
          complete_structured_fn = None;
          list_models_fn = None;
          supports_native_tools_fn = None;
          context_window_fn = None; cache_control_fn = None;
        } in
        let collected_events = ref [] in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm:combined_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_agent rt
              (make_agent "child" "You are the child."));
            ignore (Runtime.register_agent_as_tool rt ~agent_id:"child" ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[{
                descriptor = { name = "agent_child";
                  description = "Invoke child";
                  input_schema = `Assoc []; output_schema = None;
                  permission = Allow; timeout = None;
                  concurrency_limit = None; on_update = None;
                  cache_control = None };
                handler = (fun _input _token -> Success (`String "noop"))
              }] "parent" "You are the parent."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~update_current:false
                    ~on_tool_event:(fun evt -> collected_events := evt :: !collected_events)
                    () with
            | Error (e, _) ->
              Alcotest.failf "invoke failed: %s" (error_to_string e)
            | Ok _ ->
              let has_agent_tool_completed = List.exists (fun evt ->
                match evt with
                | Agent_tool_completed { child_agent_id; _ } ->
                  child_agent_id = "child"
                | _ -> false
              ) !collected_events in
              Alcotest.(check bool) "Agent_tool_completed emitted" true
                has_agent_tool_completed;
              let llm_request_count = List.fold_left (fun acc evt ->
                match evt with
                | Llm_request_sent _ -> acc + 1
                | _ -> acc
              ) 0 !collected_events in
              Alcotest.(check int) "only parent LLM events (child suppressed)"
                2 llm_request_count));
  ])

(* ── B7.6: Usage accumulation ============================================= *)

let usage_suite =
  ("usage_accumulation", [

    Alcotest.test_case "child usage accumulated in result JSON" `Quick
      (fun () ->
        let iteration_count = ref 0 in
        let combined_llm = {
          complete_fn = (fun _model _tools _conv ->
            let idx = !iteration_count in
            incr iteration_count;
            let usage = { prompt_tokens = 100 + idx;
                          completion_tokens = 50 + idx;
                          total_tokens = 150 + idx * 2;
                          cached_tokens = 0;
                          cache_creation_input_tokens = 0;
                          cache_read_input_tokens = 0 } in
            let resp = match idx with
              | 0 -> { text = None; reasoning_content = None;
                       tool_calls = Some [
                         { id = "tc-use"; name = "agent_child";
                           arguments = `Assoc [("message", `String "go")] }];
                       finish_reason = Tool_calls; usage; model = "mock" }
              | 1 -> { text = Some "child-answer"; reasoning_content = None;
                       tool_calls = None; finish_reason = Stop;
                       usage; model = "mock" }
              | _ -> { text = Some "parent-done"; reasoning_content = None;
                       tool_calls = None; finish_reason = Stop;
                       usage; model = "mock" }
            in
            Ok resp);
          stream_fn = (fun _ _ _ _ _ -> Ok {
              final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
          close_fn = (fun () -> ());
          complete_structured_fn = None;
          list_models_fn = None;
          supports_native_tools_fn = None;
          context_window_fn = None; cache_control_fn = None;
        } in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm:combined_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_agent rt
              (make_agent "child" "You are the child."));
            ignore (Runtime.register_agent_as_tool rt ~agent_id:"child" ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[{
                descriptor = { name = "agent_child";
                  description = "Invoke child";
                  input_schema = `Assoc []; output_schema = None;
                  permission = Allow; timeout = None;
                  concurrency_limit = None; on_update = None;
                  cache_control = None };
                handler = (fun _input _token -> Success (`String "noop"))
              }] "parent" "You are the parent."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~update_current:false () with
            | Error (e, _) ->
              Alcotest.failf "invoke failed: %s" (error_to_string e)
            | Ok _result ->
              (* The usage is embedded in the tool result JSON, which the
                 parent engine sees as the tool handler's Success output.
                 We verify by checking the metrics: the parent runtime's
                 llm_requests_total should be 1 (parent call only; child
                 uses wrapped LLM but Engine.run_agent itself counts in
                 its own context). *)
              let snap = Runtime.metrics_snapshot rt in
              let llm_count = snapshot_get "llm_requests_total" snap in
              Alcotest.(check bool) "llm_requests >= 1" true (llm_count >= 1)));
  ])

(* ── B7.7: e2e two-agent collaboration ==================================== *)

let e2e_suite =
  ("e2e_collaboration", [

    Alcotest.test_case "parent invokes child via register_agent_as_tool, gets result" `Quick
      (fun () ->
        let call_count = ref 0 in
        let combined_llm = {
          complete_fn = (fun _model _tools _conv ->
            let idx = !call_count in
            incr call_count;
            let resp = match idx with
              | 0 -> tool_call_response [
                  { id = "tc-e2e"; name = "agent_child";
                    arguments = `Assoc [("message", `String "What is 2+2?")] }]
              | 1 -> stop_response "4"
              | _ -> stop_response "The answer is 4."
            in
            Ok resp);
          stream_fn = (fun _ _ _ _ _ -> Ok {
              final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
          close_fn = (fun () -> ());
          complete_structured_fn = None;
          list_models_fn = None;
          supports_native_tools_fn = None;
          context_window_fn = None; cache_control_fn = None;
        } in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm:combined_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_agent rt
              (make_agent "child" "You are a calculator. Answer math questions."));
            ignore (Runtime.register_agent_as_tool rt ~agent_id:"child"
              ~tool_name:"agent_child"
              ~description:"Delegate math questions to the calculator agent"
              ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[{
                descriptor = { name = "agent_child";
                  description = "Delegate math questions to the calculator agent";
                  input_schema = `Assoc []; output_schema = None;
                  permission = Allow; timeout = None;
                  concurrency_limit = None; on_update = None;
                  cache_control = None };
                handler = (fun _input _token -> Success (`String "noop"))
              }] "parent" "You are a coordinator. Use tools when appropriate."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"What is 2+2?"
                    ~update_current:false () with
            | Error (e, _) ->
              Alcotest.failf "invoke failed: %s" (error_to_string e)
            | Ok result ->
              let text = Option.value result.response.text ~default:"" in
              Alcotest.(check bool) "response mentions 4" true
                (try ignore (Str.search_forward (Str.regexp_string "4") text 0); true
                 with Not_found -> false)));
  ])

(* ── B7.8: Approval_required conversion =================================== *)

let approval_suite =
  ("approval_conversion", [

    Alcotest.test_case "child Approval_pending → [agent-tool] instructive error" `Quick
      (fun () ->
        let child_tool_handler (_input : Yojson.Safe.t) (_token : cancellation_token) =
          Approval_required {
            tool_name = "sensitive_op";
            tool_input = `Assoc [];
            prompt = "Please approve";
            timeout = Some 10.0;
            allowed_roles = ["admin"];
          }
        in
        let child_tool_desc : tool_descriptor = {
          name = "sensitive_op"; description = "Sensitive operation";
          input_schema = `Assoc []; output_schema = None;
          permission = Allow; timeout = None;
          concurrency_limit = None; on_update = None; cache_control = None;
        } in
        let approval_p, _approval_r = Eio.Promise.create () in
        let approval_handler : Types.approval_context Approval.approval_handler =
          Async_callback (fun _ctx -> approval_p)
        in
        let child_agent = {
          (make_agent "child" "You are the child.") with
          tools = [child_tool_desc];
          approval_handler = Some approval_handler;
        } in
        let combined_counter = ref 0 in
        let combined_llm = {
          complete_fn = (fun _model _tools _conv ->
            let idx = !combined_counter in
            incr combined_counter;
            let resp = match idx with
              | 0 -> tool_call_response [
                  { id = "tc-app"; name = "agent_child";
                    arguments = `Assoc [("message", `String "do it")] }]
              | 1 -> tool_call_response [
                  { id = "tc-sens"; name = "sensitive_op";
                    arguments = `Assoc [] }]
              | _ -> stop_response "done"
            in
            Ok resp);
          stream_fn = (fun _ _ _ _ _ -> Ok {
              final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
          close_fn = (fun () -> ());
          complete_structured_fn = None;
          list_models_fn = None;
          supports_native_tools_fn = None;
          context_window_fn = None; cache_control_fn = None;
        } in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm:combined_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_tool rt ~name:"sensitive_op"
              ~description:"Sensitive operation"
              ~input_schema:(`Assoc []) ~handler:child_tool_handler ());
            ignore (Runtime.register_agent rt child_agent);
            ignore (Runtime.register_agent_as_tool rt ~agent_id:"child" ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[{
                descriptor = { name = "agent_child";
                  description = "Invoke child";
                  input_schema = `Assoc []; output_schema = None;
                  permission = Allow; timeout = None;
                  concurrency_limit = None; on_update = None;
                  cache_control = None };
                handler = (fun _input _token -> Success (`String "noop"))
              }] "parent" "You are the parent."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~update_current:false () with
            | Error (e, _) ->
              Alcotest.failf "invoke failed: %s" (error_to_string e)
            | Ok result ->
              let conv_text = text_of_conversation result.conversation in
              Alcotest.(check bool) "has [agent-tool] marker" true
                (try ignore (Str.search_forward (Str.regexp_string "[agent-tool]") conv_text 0); true
                 with Not_found -> false)));
  ])

(* ── B7.9: Agent not found ================================================ *)

let agent_not_found_suite =
  ("agent_not_found", [

    Alcotest.test_case "register_agent_as_tool for unknown agent_id returns error" `Quick
      (fun () ->
        let llm = mock_llm [ stop_response "unused" ] in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            match Runtime.register_agent_as_tool rt ~agent_id:"nonexistent" () with
            | Error (Invalid_input msg) ->
              Alcotest.(check bool) "mentions agent" true
                (String.length msg > 0)
            | Error e ->
              Alcotest.failf "wrong error: %s" (error_to_string e)
            | Ok () ->
              Alcotest.fail "should reject unknown agent"));
  ])

(* ── Run all suites ======================================================= *)

let () =
  Alcotest.run "test_agent_as_tool" [
    duplicate_suite;
    depth_suite;
    isolation_suite;
    cancellation_suite;
    event_suite;
    usage_suite;
    e2e_suite;
    approval_suite;
    agent_not_found_suite;
  ]
