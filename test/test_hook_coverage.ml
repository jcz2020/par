(* Runtime tool-call hooks must gate every agent-running entry point, not only
   Runtime.invoke. GitHub #33: workflow Agent_call steps and invoke_parallel
   used to run Engine.run_agent without hooks, so an application approval gate
   was silently bypassed. The same class of gap existed on invoke_structured,
   agent-as-tool children and workflow Tool_call steps; this suite covers those
   five paths, and test_engine_hitl.ml covers the resume_approval re-dispatch.

   Every case asserts that the tool *handler did not run* when the hook
   blocked it. A test that only checks the returned text would pass even when
   the gate is missing. *)

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
  | Cancelled _ -> "cancelled"

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

let tool_call_response calls : llm_response =
  { text = None; reasoning = []; tool_calls = Some calls;
    finish_reason = Tool_calls; usage = dummy_usage; model = "mock" }

let tool_call ?(id = "tc-1") name : tool_call =
  { id; name; arguments = `Assoc [] }

let mock_llm_dynamic f : llm_service =
  { complete_fn = (fun _model _tools conv -> Ok (f conv));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None }

let runtime_config () : runtime_config =
  { persistence = `Sqlite ":memory:";
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = true;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = 604800.0;
    max_tool_schema_tokens = None }

let with_switch f = Eio_main.run (fun _env -> Eio.Switch.run f)

let create_runtime ?(llm = mock_llm_dynamic (fun _ -> text_response "default")) sw =
  match Runtime.create ~llm ~config:(runtime_config ()) sw with
  | Ok rt -> rt
  | Error e -> Alcotest.failf "create_runtime: %s" (error_to_string e)

let make_agent ?(tools = []) ?approval_handler id system_prompt : agent_config =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id; system_prompt = stable_prompt system_prompt;
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations = 10;
    middleware = []; retry_policy = None; context_strategy = None;
    resource_quota = None; max_execution_time = None; tool_timeout = None;
    early_stopping_method = Force; on_max_tokens = Some Return_partial;
    max_continuation_chunks = Some 3;
    context_compression_threshold = None; compression_cooldown_messages = None;
    context_window_override = None; cache_strategy = No_caching;
    approval_handler }

let descriptor ?(name = "danger_tool") () : tool_descriptor =
  { name; description = "A tool the hook must block";
    input_schema = `Assoc []; output_schema = None;
    permission = Allow; timeout = None; concurrency_limit = None;
    on_update = None; cache_control = None }

let danger_binding executed : tool_binding =
  { descriptor = descriptor ();
    handler = (fun _input _tok ->
      executed := true;
      Success (`String "danger-ran")) }

let register_danger_tool rt executed =
  match Runtime.register_tool rt ~name:"danger_tool"
          ~description:"A tool the hook must block"
          ~input_schema:(`Assoc [])
          ~handler:(fun _input _tok ->
            executed := true;
            Success (`String "danger-ran")) () with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "register danger_tool: %s" (error_to_string e)

let block_danger_hook rt =
  Runtime.register_tool_call_hook rt (fun (ctx : Hook.tool_call_context) ->
    if ctx.tool_name = "danger_tool" then
      Hook.Block { reason = "approval required" }
    else Hook.Allow)

let register_agent rt agent =
  match Runtime.register_agent rt agent with
  | Ok () -> ()
  | Error e -> Alcotest.failf "register_agent %s: %s" agent.id
               (error_to_string e)

let has_tool_message conv =
  List.exists (fun (m : message) -> m.role = Tool) conv.messages

let workflow_status_to_string = function
  | Wf_pending -> "Wf_pending"
  | Wf_running -> "Wf_running"
  | Wf_suspended _ -> "Wf_suspended"
  | Wf_completed _ -> "Wf_completed"
  | Wf_failed _ -> "Wf_failed"

(* -------------------------------------------------------------------------- *)
(* invoke_parallel                                                           *)
(* -------------------------------------------------------------------------- *)

let test_invoke_parallel_honors_hooks () =
  with_switch (fun sw ->
    let executed = ref false in
    let llm = mock_llm_dynamic (fun conv ->
      if has_tool_message conv then text_response "done"
      else tool_call_response [ tool_call "danger_tool" ]) in
    let rt = create_runtime ~llm sw in
    register_danger_tool rt executed;
    register_agent rt (make_agent ~tools:[danger_binding executed] "A" "Agent A");
    block_danger_hook rt;
    let spec : Runtime.agent_dispatch_spec =
      { agent_id = "A"; input = Some "go"; workspace = None;
        approval_handler = None; blocking_approval = false;
        conversation = None } in
    (match Runtime.invoke_parallel ~rt ~specs:[spec] () with
     | Ok result ->
       Alcotest.(check int) "one success" 1 (List.length result.successes);
       Alcotest.(check bool) "danger tool handler did not run" false !executed
     | Error e -> Alcotest.failf "invoke_parallel: %s" (error_to_string e));
    ignore (Runtime.close rt))

(* -------------------------------------------------------------------------- *)
(* Workflow Agent_call step                                                  *)
(* -------------------------------------------------------------------------- *)

let workflow_with_agent_call () : workflow =
  { def = { id = "wf-hook-gate"; name = "Hook gate";
            version = 1;
            steps = Sequential [
              Agent_call { agent_id = "A"; prompt_template = "go";
                           response_schema = None };
            ];
            variables = []; failure_policy = Fail_fast;
            parallel_limit = 4; timeout = 300.0 };
    on_complete = None }

let test_workflow_agent_call_honors_hooks () =
  with_switch (fun sw ->
    let executed = ref false in
    let llm = mock_llm_dynamic (fun conv ->
      if has_tool_message conv then text_response "done"
      else tool_call_response [ tool_call "danger_tool" ]) in
    let rt = create_runtime ~llm sw in
    register_danger_tool rt executed;
    register_agent rt (make_agent ~tools:[danger_binding executed] "A" "Agent A");
    block_danger_hook rt;
    let wf = workflow_with_agent_call () in
    (match Runtime.register_workflow rt wf with
     | Ok () -> ()
     | Error e -> Alcotest.failf "register_workflow: %s" (error_to_string e));
    (match Runtime.submit_workflow rt wf with
     | Ok _ -> ()
     | Error e -> Alcotest.failf "submit_workflow: %s" (error_to_string e));
    Alcotest.(check bool) "danger tool handler did not run" false !executed;
    ignore (Runtime.close rt))

(* -------------------------------------------------------------------------- *)
(* Workflow Tool_call step                                                   *)
(* -------------------------------------------------------------------------- *)

let test_workflow_tool_call_honors_hooks () =
  with_switch (fun sw ->
    let executed = ref false in
    let rt = create_runtime sw in
    register_danger_tool rt executed;
    register_agent rt (make_agent ~tools:[danger_binding executed] "A" "Agent A");
    block_danger_hook rt;
    let wf : workflow =
      { def = { id = "wf-tool-hook"; name = "Tool hook gate";
                version = 1;
                steps = Sequential [
                  Tool_call { tool_name = "danger_tool"; input = `Assoc [] };
                ];
                variables = []; failure_policy = Fail_fast;
                parallel_limit = 4; timeout = 300.0 };
        on_complete = None } in
    (match Runtime.register_workflow rt wf with
     | Ok () -> ()
     | Error e -> Alcotest.failf "register_workflow: %s" (error_to_string e));
    (match Runtime.submit_workflow rt wf with
     | Ok run_id ->
       (match Runtime.get_workflow_status rt run_id with
        | Ok (Wf_failed (Permission_denied _)) -> ()
        | Ok (Wf_failed err) ->
          Alcotest.failf "expected Permission_denied, got %s" (error_to_string err)
        | Ok other ->
          Alcotest.failf "expected Wf_failed (Permission_denied), got %s"
            (workflow_status_to_string other)
        | Error e -> Alcotest.failf "get_workflow_status: %s" (error_to_string e))
     | Error e -> Alcotest.failf "submit_workflow: %s" (error_to_string e));
    Alcotest.(check bool) "danger tool handler did not run" false !executed;
    ignore (Runtime.close rt))

(* -------------------------------------------------------------------------- *)
(* invoke_structured (Phase 1 ReAct loop with tools)                         *)
(* -------------------------------------------------------------------------- *)

let test_invoke_structured_honors_hooks () =
  with_switch (fun sw ->
    let executed = ref false in
    let llm = mock_llm_dynamic (fun conv ->
      if has_tool_message conv then text_response "done"
      else tool_call_response [ tool_call "danger_tool" ]) in
    let rt = create_runtime ~llm sw in
    register_danger_tool rt executed;
    register_agent rt (make_agent ~tools:[danger_binding executed] "A" "Agent A");
    block_danger_hook rt;
    (* Phase 2 cannot produce structured JSON with this mock; only Phase 1
       matters here. The assertion is that the blocked handler never ran. *)
    ignore (Runtime.invoke_structured rt ~agent_id:"A" ~message:"go"
              ~response_schema:(`Assoc [("type", `String "object")]) ());
    Alcotest.(check bool) "danger tool handler did not run" false !executed;
    ignore (Runtime.close rt))

(* -------------------------------------------------------------------------- *)
(* Agent-as-tool child                                                       *)
(* -------------------------------------------------------------------------- *)

(* The parent and the child share the runtime's LLM service. The tool list
   distinguishes the two runs: the parent sees [agent_child], the child sees
   [danger_tool]. *)
let mock_llm_for_agent_tool () : llm_service =
  { complete_fn = (fun _model tools conv ->
      let is_child =
        List.exists (fun (d : tool_descriptor) -> d.name = "danger_tool") tools
      in
      let resp =
        if is_child then
          if has_tool_message conv then text_response "child done"
          else tool_call_response [ tool_call "danger_tool" ]
        else if has_tool_message conv then text_response "parent done"
        else tool_call_response [ tool_call ~id:"tc-parent" "agent_child" ]
      in
      Ok resp);
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None }

let test_agent_as_tool_child_honors_hooks () =
  with_switch (fun sw ->
    let executed = ref false in
    let rt = create_runtime ~llm:(mock_llm_for_agent_tool ()) sw in
    register_danger_tool rt executed;
    register_agent rt (make_agent ~tools:[danger_binding executed] "child"
                         "You are the child.");
    (match Runtime.register_agent_as_tool rt ~agent_id:"child" () with
     | Ok () -> ()
     | Error e -> Alcotest.failf "register_agent_as_tool: %s" (error_to_string e));
    let child_tool : tool_binding =
      { descriptor = { (descriptor ()) with name = "agent_child";
                       description = "Invoke child" };
        handler = (fun _input _tok -> Success (`String "noop")) } in
    register_agent rt (make_agent ~tools:[child_tool] "parent"
                         "You are the parent.");
    block_danger_hook rt;
    (match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
             ~update_current:false () with
     | Ok _ -> ()
     | Error (e, _) -> Alcotest.failf "invoke parent: %s" (error_to_string e));
    Alcotest.(check bool) "child danger tool handler did not run" false !executed;
    ignore (Runtime.close rt))

let () =
  Alcotest.run "hook_coverage" [
    ("hook_coverage", [
      Alcotest.test_case "invoke_parallel honors runtime hooks" `Quick
        test_invoke_parallel_honors_hooks;
      Alcotest.test_case "workflow Agent_call honors runtime hooks" `Quick
        test_workflow_agent_call_honors_hooks;
      Alcotest.test_case "workflow Tool_call honors runtime hooks" `Quick
        test_workflow_tool_call_honors_hooks;
      Alcotest.test_case "invoke_structured honors runtime hooks" `Quick
        test_invoke_structured_honors_hooks;
      Alcotest.test_case "agent-as-tool child honors runtime hooks" `Quick
        test_agent_as_tool_child_honors_hooks;
    ]);
  ]
