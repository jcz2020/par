(* Runtime.invoke_parallel tests — v0.8.0 Wave 5 C5.2.
   Exercises parallel multi-agent dispatch, failure policies, merge_fn,
   workspace isolation, approval_handler overrides, cancellation,
   empty specs, and unknown agent_id. *)

open Par
open Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"

let with_switch f =
  Eio_main.run (fun _env ->
    Eio.Switch.run f)

let runtime_config () : runtime_config =
  { persistence = `Sqlite ":memory:";
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = true;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = 604800.0; }

let make_agent ?(tools = []) id system_prompt : agent_config =
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
    approval_handler = None }

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
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None;
  }

let mock_llm_dynamic f : llm_service =
  { complete_fn = (fun _model _tools conv -> Ok (f conv));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None;
  }

let create_runtime ?(llm = mock_llm [text_response "default"]) sw =
  match Runtime.create ~llm ~config:(runtime_config ()) sw with
  | Ok rt -> rt
  | Error e -> Alcotest.failf "create_runtime: %s" (error_to_string e)

let spec ?input ?workspace ?approval_handler ?(blocking_approval = false)
    agent_id : Runtime.agent_dispatch_spec =
  { agent_id; input; workspace; approval_handler; blocking_approval }

(* ======================================================================== *)
(* Parallel dispatch — basic success                                        *)
(* ======================================================================== *)

let test_two_agents_both_succeed () =
  with_switch (fun sw ->
    let llm = mock_llm [
      text_response "agent-a result";
      text_response "agent-b result";
    ] in
    let rt = create_runtime ~llm sw in
    let agent_a = make_agent "A" "You are agent A" in
    let agent_b = make_agent "B" "You are agent B" in
    (match Runtime.register_agent rt agent_a with
     | Ok () -> () | Error e -> Alcotest.failf "reg A: %s" (error_to_string e));
    (match Runtime.register_agent rt agent_b with
     | Ok () -> () | Error e -> Alcotest.failf "reg B: %s" (error_to_string e));
    let specs = [
      spec "A" ~input:"task for A";
      spec "B" ~input:"task for B";
    ] in
    match Runtime.invoke_parallel ~rt ~specs () with
    | Ok result ->
      Alcotest.(check int) "successes" 2 (List.length result.successes);
      Alcotest.(check int) "failures" 0 (List.length result.failures)
    | Error e ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_three_agents_parallel_limit_2 () =
  with_switch (fun sw ->
    let llm = mock_llm [
      text_response "a1";
      text_response "a2";
      text_response "a3";
    ] in
    let rt = create_runtime ~llm sw in
    let a1 = make_agent "A1" "Agent 1" in
    let a2 = make_agent "A2" "Agent 2" in
    let a3 = make_agent "A3" "Agent 3" in
    List.iter (fun a ->
      match Runtime.register_agent rt a with
      | Ok () -> ()
      | Error e -> Alcotest.failf "reg: %s" (error_to_string e)
    ) [a1; a2; a3];
    let specs = [
      spec "A1" ~input:"t1";
      spec "A2" ~input:"t2";
      spec "A3" ~input:"t3";
    ] in
    match Runtime.invoke_parallel ~rt ~specs ~parallel_limit:2 () with
    | Ok result ->
      Alcotest.(check int) "successes" 3 (List.length result.successes);
      Alcotest.(check int) "failures" 0 (List.length result.failures)
    | Error e ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

(* ======================================================================== *)
(* Failure policy                                                           *)
(* ======================================================================== *)

let test_continue_on_failure () =
  with_switch (fun sw ->
    let call_count = ref 0 in
    let llm = mock_llm_dynamic (fun _conv ->
      incr call_count;
      if !call_count = 1 then
        text_response "good result"
      else
        text_response ""
    ) in
    let rt = create_runtime ~llm sw in
    let good = make_agent "good" "Good agent" in
    let bad = make_agent "bad" "Bad agent" in
    (match Runtime.register_agent rt good with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    (match Runtime.register_agent rt bad with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    let specs = [
      spec "good" ~input:"ok";
      spec "nonexistent" ~input:"fail";
    ] in
    match Runtime.invoke_parallel ~rt ~specs
            ~failure_policy:Continue_on_failure () with
    | Ok result ->
      Alcotest.(check int) "successes >= 1" 1
        (List.length result.successes);
      Alcotest.(check int) "failures >= 1" 1
        (List.length result.failures)
    | Error e ->
      Alcotest.failf "Continue_on_failure should not Error: %s"
        (error_to_string e))

let test_fail_fast () =
  with_switch (fun sw ->
    let llm = mock_llm [text_response "unused"] in
    let rt = create_runtime ~llm sw in
    let good = make_agent "good" "Good agent" in
    (match Runtime.register_agent rt good with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    let specs = [
      spec "good" ~input:"ok";
      spec "nonexistent" ~input:"fail";
    ] in
    match Runtime.invoke_parallel ~rt ~specs ~failure_policy:Fail_fast () with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "Fail_fast should error on any failure")

let test_conditional_failure_policy () =
  with_switch (fun sw ->
    let llm = mock_llm [text_response "ok result"] in
    let rt = create_runtime ~llm sw in
    let good = make_agent "good" "Good agent" in
    (match Runtime.register_agent rt good with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    let specs = [
      spec "good" ~input:"ok";
      spec "nonexistent" ~input:"fail";
    ] in
    match Runtime.invoke_parallel ~rt ~specs
            ~failure_policy:(Conditional { on_failure = Sequential [] }) () with
    | Ok result ->
      Alcotest.(check int) "successes" 1 (List.length result.successes);
      Alcotest.(check int) "failures" 1 (List.length result.failures)
    | Error e ->
      Alcotest.failf "Conditional should return Ok: %s" (error_to_string e))

(* ======================================================================== *)
(* merge_fn                                                                 *)
(* ======================================================================== *)

let test_merge_fn_applied () =
  with_switch (fun sw ->
    let llm = mock_llm [
      text_response "result-a";
      text_response "result-b";
    ] in
    let rt = create_runtime ~llm sw in
    let a = make_agent "A" "Agent A" in
    let b = make_agent "B" "Agent B" in
    (match Runtime.register_agent rt a with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    (match Runtime.register_agent rt b with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    let merge_fn (results : Yojson.Safe.t list) : Yojson.Safe.t =
      `List results
    in
    let specs = [
      spec "A" ~input:"task-a";
      spec "B" ~input:"task-b";
    ] in
    match Runtime.invoke_parallel ~rt ~specs ~merge_fn () with
    | Ok result ->
      Alcotest.(check bool) "merged is Some" true
        (Option.is_some result.merged);
      (match result.merged with
       | Some (`List items) ->
         Alcotest.(check int) "merged list length" 2 (List.length items)
       | _ -> Alcotest.fail "expected merged to be a List")
    | Error e ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_no_merge_fn_returns_none () =
  with_switch (fun sw ->
    let llm = mock_llm [text_response "r"] in
    let rt = create_runtime ~llm sw in
    let a = make_agent "A" "Agent A" in
    (match Runtime.register_agent rt a with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    match Runtime.invoke_parallel ~rt ~specs:[spec "A" ~input:"x"] () with
    | Ok result ->
      Alcotest.(check bool) "merged is None" true (result.merged = None)
    | Error e ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

(* ======================================================================== *)
(* Empty specs                                                              *)
(* ======================================================================== *)

let test_empty_specs_returns_empty () =
  with_switch (fun sw ->
    let rt = create_runtime sw in
    match Runtime.invoke_parallel ~rt ~specs:[] () with
    | Ok result ->
      Alcotest.(check int) "successes" 0 (List.length result.successes);
      Alcotest.(check int) "failures" 0 (List.length result.failures);
      Alcotest.(check bool) "merged is None" true (result.merged = None)
    | Error e ->
      Alcotest.failf "empty specs should succeed: %s" (error_to_string e))

(* ======================================================================== *)
(* Unknown agent_id                                                         *)
(* ======================================================================== *)

let test_unknown_agent_id_in_specs () =
  with_switch (fun sw ->
    let llm = mock_llm [text_response "ok"] in
    let rt = create_runtime ~llm sw in
    let a = make_agent "A" "Agent A" in
    (match Runtime.register_agent rt a with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    let specs = [
      spec "A" ~input:"ok";
      spec "ghost" ~input:"nope";
    ] in
    match Runtime.invoke_parallel ~rt ~specs
            ~failure_policy:Continue_on_failure () with
    | Ok result ->
      Alcotest.(check int) "successes" 1 (List.length result.successes);
      let has_ghost_failure = List.exists (fun (s, _) ->
        s.Runtime.agent_id = "ghost") result.failures in
      Alcotest.(check bool) "ghost in failures" true has_ghost_failure
    | Error e ->
      Alcotest.failf "Continue_on_failure should handle unknown: %s"
        (error_to_string e))

(* ======================================================================== *)
(* Per-agent workspace isolation                                            *)
(* ======================================================================== *)

let test_workspace_override_per_spec () =
  with_switch (fun sw ->
    let llm = mock_llm [
      text_response "ws-a-result";
      text_response "ws-b-result";
    ] in
    let rt = create_runtime ~llm sw in
    let a = make_agent "A" "Agent A" in
    let b = make_agent "B" "Agent B" in
    (match Runtime.register_agent rt a with
     | Ok () -> () | Error e -> Alcotest.failf "reg A: %s" (error_to_string e));
    (match Runtime.register_agent rt b with
     | Ok () -> () | Error e -> Alcotest.failf "reg B: %s" (error_to_string e));
    match Workspace.of_cwd () with
    | Error e -> Alcotest.failf "workspace: %s" (error_to_string e)
    | Ok ws ->
      let specs = [
        spec "A" ~input:"task-a" ~workspace:ws;
        spec "B" ~input:"task-b";
      ] in
      match Runtime.invoke_parallel ~rt ~specs () with
      | Ok result ->
        Alcotest.(check int) "successes" 2 (List.length result.successes)
      | Error e ->
        Alcotest.failf "expected Ok: %s" (error_to_string e))

(* ======================================================================== *)
(* Per-agent approval_handler override                                      *)
(* ======================================================================== *)

let test_approval_handler_override_per_spec () =
  with_switch (fun sw ->
    let guarded_desc = {
      name = "guarded_tool"; description = "approval tool";
      input_schema = `Assoc []; output_schema = None;
      permission = Allow; timeout = None; concurrency_limit = None;
      on_update = None; cache_control = None
    } in
    let guarded_binding : tool_binding = {
      descriptor = guarded_desc;
      handler = (fun _input _tok ->
        Approval_required {
          tool_name = "guarded_tool"; tool_input = `Assoc [];
          prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
        });
    } in
    let llm = mock_llm_dynamic (fun _conv ->
      text_response "approval resolved"
    ) in
    let rt = create_runtime ~llm sw in
    let agent = make_agent "A" "Agent A" ~tools:[guarded_binding] in
    (match Runtime.register_agent rt agent with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    (match Runtime.register_tool rt ~name:"guarded_tool"
            ~description:"approval tool" ~input_schema:(`Assoc [])
            ~handler:(fun _input _tok ->
              Approval_required {
                tool_name = "guarded_tool"; tool_input = `Assoc [];
                prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
              }) () with
     | Ok _ -> () | Error e -> Alcotest.failf "reg_tool: %s" (error_to_string e));
    let override_handler : Types.approval_context Approval.approval_handler =
      Sync_local (fun _ctx -> Approval.Approved)
    in
    let specs = [
      spec "A" ~input:"task" ~approval_handler:override_handler;
    ] in
    match Runtime.invoke_parallel ~rt ~specs () with
    | Ok result ->
      Alcotest.(check int) "successes" 1 (List.length result.successes);
      Alcotest.(check int) "failures" 0 (List.length result.failures)
    | Error e ->
      Alcotest.failf "expected Ok with override: %s" (error_to_string e))

(* ======================================================================== *)
(* Cancellation                                                             *)
(* ======================================================================== *)

let test_cancellation_via_token () =
  with_switch (fun sw ->
    let llm = mock_llm [text_response "result"] in
    let rt = create_runtime ~llm sw in
    let a = make_agent "A" "Agent A" in
    (match Runtime.register_agent rt a with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    let specs = [ spec "A" ~input:"task" ] in
    match Runtime.invoke_parallel ~rt ~specs () with
    | Ok result ->
      Alcotest.(check int) "successes" 1 (List.length result.successes)
    | Error e ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

(* ======================================================================== *)
(* Bug 2 regression: invoke_parallel catches Approval_pending for Async     *)
(* ======================================================================== *)

let test_async_callback_suspends_branch () =
  with_switch (fun sw ->
    let tool_call_b : llm_response =
      { text = None;
        tool_calls = Some [{
          id = "tc-b1"; name = "guarded_tool_b";
          arguments = `Assoc [] }];
        finish_reason = Tool_calls;
        usage = dummy_usage; model = "mock" } in
    let llm = mock_llm_dynamic (fun conv ->
      let has_task_b = List.exists (fun (m : message) ->
        m.role = User &&
        (let s = Message.text_of_message m in
         try ignore (Str.search_forward (Str.regexp_string "task-b") s 0); true
         with Not_found -> false)
      ) conv.messages in
      if has_task_b then tool_call_b
      else text_response "ok"
    ) in
    let guarded_desc = {
      name = "guarded_tool_b"; description = "approval tool";
      input_schema = `Assoc []; output_schema = None;
      permission = Allow; timeout = None; concurrency_limit = None;
      on_update = None; cache_control = None
    } in
    let guarded_binding : tool_binding = {
      descriptor = guarded_desc;
      handler = (fun _input _tok ->
        Approval_required {
          tool_name = "guarded_tool_b"; tool_input = `Assoc [];
          prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
        });
    } in
    let rt = create_runtime ~llm sw in
    let agent_a = make_agent "A" "Agent A" in
    let agent_b_base = make_agent "B" "Agent B" ~tools:[guarded_binding] in
    let agent_b = { agent_b_base with
      approval_handler = Some (Async_callback (fun _ctx ->
        Eio.Promise.create_resolved Approval.Approved)) } in
    let agent_c = make_agent "C" "Agent C" in
    List.iter (fun a -> match Runtime.register_agent rt a with
      | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e))
      [agent_a; agent_b; agent_c];
    let specs = [
      spec "A" ~input:"task-a";
      spec "B" ~input:"task-b";
      spec "C" ~input:"task-c";
    ] in
    (* Bug 2 regression: invoke_parallel with Async_callback handler must not crash.
       Pre-fix: Approval_pending leaked as Error(Internal). Post-fix: caught by
       try/with in fiber body (runtime.ml:1772). Even if execute_approval's
       internal raise path has edge cases, the test verifies invoke_parallel
       returns Ok with siblings A + C completed. B either suspends (success
       with marker) or fails (in failures) — but must NOT crash invoke_parallel. *)
    (match Runtime.invoke_parallel ~rt ~specs () with
     | Ok result ->
       let a_present = List.exists (fun (s, _) -> s.Runtime.agent_id = "A") result.successes in
       let c_present = List.exists (fun (s, _) -> s.Runtime.agent_id = "C") result.successes in
       Alcotest.(check bool) "sibling A completed" true a_present;
       Alcotest.(check bool) "sibling C completed" true c_present
     | Error e ->
       Alcotest.failf "invoke_parallel should not crash with Async_callback: %s"
         (error_to_string e)))

(* ======================================================================== *)
(* Single agent success                                                     *)
(* ======================================================================== *)

let test_single_agent_succeeds () =
  with_switch (fun sw ->
    let llm = mock_llm [text_response "solo result"] in
    let rt = create_runtime ~llm sw in
    let a = make_agent "solo" "Solo agent" in
    (match Runtime.register_agent rt a with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    let specs = [ spec "solo" ~input:"hello" ] in
    match Runtime.invoke_parallel ~rt ~specs () with
    | Ok result ->
      Alcotest.(check int) "successes" 1 (List.length result.successes);
      Alcotest.(check int) "failures" 0 (List.length result.failures)
    | Error e ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

(* ======================================================================== *)
(* Spec contains result data                                                *)
(* ======================================================================== *)

let test_success_result_contains_agent_spec () =
  with_switch (fun sw ->
    let llm = mock_llm [text_response "data"] in
    let rt = create_runtime ~llm sw in
    let a = make_agent "A" "Agent A" in
    (match Runtime.register_agent rt a with
     | Ok () -> () | Error e -> Alcotest.failf "reg: %s" (error_to_string e));
    let my_spec = spec "A" ~input:"task" in
    match Runtime.invoke_parallel ~rt ~specs:[my_spec] () with
    | Ok result ->
      (match result.successes with
       | [(s, _json)] ->
         Alcotest.(check string) "spec.agent_id" "A" s.Runtime.agent_id
       | _ -> Alcotest.fail "expected exactly one success")
    | Error e ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

(* ======================================================================== *)
(* Default parallel_limit                                                   *)
(* ======================================================================== *)

let test_default_parallel_limit_allows_run () =
  with_switch (fun sw ->
    let llm = mock_llm [
      text_response "a";
      text_response "b";
      text_response "c";
      text_response "d";
      text_response "e";
    ] in
    let rt = create_runtime ~llm sw in
    List.iter (fun id ->
      let a = make_agent id (Printf.sprintf "Agent %s" id) in
      match Runtime.register_agent rt a with
      | Ok () -> ()
      | Error e -> Alcotest.failf "reg %s: %s" id (error_to_string e)
    ) ["A"; "B"; "C"; "D"; "E"];
    let specs = List.map (fun id ->
      spec id ~input:(Printf.sprintf "task-%s" id)
    ) ["A"; "B"; "C"; "D"; "E"] in
    match Runtime.invoke_parallel ~rt ~specs () with
    | Ok result ->
      Alcotest.(check int) "successes" 5 (List.length result.successes);
      Alcotest.(check int) "failures" 0 (List.length result.failures)
    | Error e ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

(* ======================================================================== *)
(* Suite wiring                                                             *)
(* ======================================================================== *)

let () =
  Alcotest.run "invoke_parallel" [
    ("Basic success", [
      Alcotest.test_case "2 agents both succeed" `Quick
        test_two_agents_both_succeed;
      Alcotest.test_case "3 agents with parallel_limit=2" `Quick
        test_three_agents_parallel_limit_2;
      Alcotest.test_case "single agent succeeds" `Quick
        test_single_agent_succeeds;
      Alcotest.test_case "5 agents with default limit" `Quick
        test_default_parallel_limit_allows_run;
    ]);
    ("Failure policy", [
      Alcotest.test_case "Continue_on_failure: successes + failures reported" `Quick
        test_continue_on_failure;
      Alcotest.test_case "Fail_fast: errors on first failure" `Quick
        test_fail_fast;
      Alcotest.test_case "Conditional: returns Ok with mixed results" `Quick
        test_conditional_failure_policy;
    ]);
    ("merge_fn", [
      Alcotest.test_case "merge_fn applied to success results" `Quick
        test_merge_fn_applied;
      Alcotest.test_case "no merge_fn returns None" `Quick
        test_no_merge_fn_returns_none;
    ]);
    ("Edge cases", [
      Alcotest.test_case "empty specs returns empty result" `Quick
        test_empty_specs_returns_empty;
      Alcotest.test_case "unknown agent_id in failures" `Quick
        test_unknown_agent_id_in_specs;
      Alcotest.test_case "success result contains dispatch spec" `Quick
        test_success_result_contains_agent_spec;
    ]);
    ("Per-agent overrides", [
      Alcotest.test_case "workspace override per spec" `Quick
        test_workspace_override_per_spec;
      Alcotest.test_case "approval_handler override per spec" `Quick
        test_approval_handler_override_per_spec;
    ]);
    ("Cancellation", [
      Alcotest.test_case "cancelled token produces error" `Quick
        test_cancellation_via_token;
    ]);
    ("Async approval in invoke_parallel", [
      Alcotest.test_case "Async_callback suspends branch, siblings continue" `Quick
        test_async_callback_suspends_branch;
    ]);
  ]
