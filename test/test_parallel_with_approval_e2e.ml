(* test_parallel_with_approval_e2e.ml — end-to-end tests for parallel
   multi-agent dispatch combined with HITL approval. Exercises:
   - 3 agents parallel: A,B no approval; C sync approval → all complete
   - Per-agent approval_handler override in invoke_parallel
   - Empty specs and unknown agent_id edge cases *)

open Par
open Types

let config_json = {|{"persistence": ["Sqlite", ":memory:"], "event_bus": {"buffer_capacity": 10, "delivery": {"max_delivery_attempts": 3, "initial_retry_delay": 0.1, "retry_backoff": ["Fixed", 0.5], "delivery_timeout": 5.0}, "dlq_enabled": false, "dlq_max_size": 1000, "critical_event_types": []}, "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2, "max_tokens_per_turn": null, "max_total_tokens": null}, "shutdown": {"drain_timeout": 5.0, "cancel_grace_period": 2.0, "flush_batch_size": 100}, "llm_providers": [], "eval_limits": {"max_depth": 10, "max_node_visits": 1000}, "parallel_tool_execution": true}|}

let error_to_string (e : error_category) =
  match e with
  | Timeout -> "Timeout"
  | Invalid_input s -> Printf.sprintf "Invalid_input: %s" s
  | External_failure s -> Printf.sprintf "External_failure: %s" s
  | Rate_limited -> "Rate_limited"
  | Permission_denied s -> Printf.sprintf "Permission_denied: %s" s
  | Internal s -> Printf.sprintf "Internal: %s" s
  | Embedding_unsupported -> "Embedding_unsupported"
  | Cancelled _ -> "cancelled"

let dummy_model : model_config = {
  provider = `Openai; model_name = "mock"; api_base = None;
  temperature = 0.0; max_tokens = None; top_p = None; stop_sequences = None;
}

let make_config () =
  match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
  | Ok c -> c
  | Error msg -> failwith ("config parse: " ^ msg)

let make_agent_simple id prompt =
  match Runtime.make_agent ~id ~system_prompt:(stable_prompt prompt)
          ~model:dummy_model () with
  | Ok a -> a
  | Error e -> Alcotest.failf "make_agent %s: %s" id (error_to_string e)

let make_approval_agent id prompt handler =
  match Runtime.make_agent ~id ~system_prompt:(stable_prompt prompt)
          ~model:dummy_model ~approval_handler:(Some handler) () with
  | Ok a -> a
  | Error e -> Alcotest.failf "make_agent %s: %s" id (error_to_string e)

let make_spec ?input ?approval_handler agent_id : Runtime.agent_dispatch_spec =
  { agent_id; input; workspace = None; approval_handler; blocking_approval = false }

let _make_blocking_spec ?input ?approval_handler agent_id : Runtime.agent_dispatch_spec =
  { agent_id; input; workspace = None; approval_handler; blocking_approval = true }

let test_parallel_three_agents_no_approval () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let config = make_config () in
      let (llm, _history) = Mock_provider.create [
        Mock_provider.Text "agent A done";
        Mock_provider.Text "agent B done";
        Mock_provider.Text "agent C done";
      ] in
      match Runtime.create ~config ~llm sw with
      | Error e -> Alcotest.failf "Runtime.create: %s" (error_to_string e)
      | Ok rt ->
        let a = make_agent_simple "agent_a" "You are agent A" in
        let b = make_agent_simple "agent_b" "You are agent B" in
        let c = make_agent_simple "agent_c" "You are agent C" in
        ignore (Runtime.register_agent rt a);
        ignore (Runtime.register_agent rt b);
        ignore (Runtime.register_agent rt c);
        let specs = [
          make_spec "agent_a";
          make_spec "agent_b";
          make_spec "agent_c";
        ] in
        (match Runtime.invoke_parallel ~rt ~specs () with
         | Error e ->
           Alcotest.failf "invoke_parallel failed: %s" (error_to_string e)
         | Ok result ->
           Alcotest.(check int) "3 successes" 3 (List.length result.successes);
           Alcotest.(check int) "0 failures" 0 (List.length result.failures));
        ignore (Runtime.close rt)))

let test_parallel_with_sync_approval_handler () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let config = make_config () in
      let (llm, _history) = Mock_provider.create [
        Mock_provider.Text "agent A done";
        Mock_provider.Text "agent B done";
        Mock_provider.Text "agent C done with approval";
      ] in
      match Runtime.create ~config ~llm sw with
      | Error e -> Alcotest.failf "Runtime.create: %s" (error_to_string e)
      | Ok rt ->
        let a = make_agent_simple "agent_a" "You are agent A" in
        let b = make_agent_simple "agent_b" "You are agent B" in
        let approval_h : approval_context Approval.approval_handler =
          Approval.Sync_local (fun _ctx -> Approval.Approved) in
        let c = make_approval_agent "agent_c" "You are agent C" approval_h in
        ignore (Runtime.register_agent rt a);
        ignore (Runtime.register_agent rt b);
        ignore (Runtime.register_agent rt c);
        let specs = [
          make_spec "agent_a";
          make_spec "agent_b";
          make_spec ~approval_handler:approval_h "agent_c";
        ] in
        (match Runtime.invoke_parallel ~rt ~specs () with
         | Error e ->
           Alcotest.failf "invoke_parallel failed: %s" (error_to_string e)
         | Ok result ->
           Alcotest.(check int) "3 successes" 3 (List.length result.successes);
           Alcotest.(check int) "0 failures" 0 (List.length result.failures));
        ignore (Runtime.close rt)))

let test_parallel_unknown_agent () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let config = make_config () in
      let (llm, _history) = Mock_provider.create [
        Mock_provider.Text "ok";
      ] in
      match Runtime.create ~config ~llm sw with
      | Error e -> Alcotest.failf "Runtime.create: %s" (error_to_string e)
      | Ok rt ->
        let specs = [ make_spec "nonexistent_agent" ] in
        (match Runtime.invoke_parallel ~rt ~specs () with
         | Error e ->
           Alcotest.failf "invoke_parallel should not hard-fail, got: %s" (error_to_string e)
         | Ok result ->
           (* Unknown agent should appear in failures *)
           Alcotest.(check int) "0 successes" 0 (List.length result.successes);
           Alcotest.(check int) "1 failure" 1 (List.length result.failures));
        ignore (Runtime.close rt)))

let test_parallel_empty_specs () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let config = make_config () in
      let (llm, _history) = Mock_provider.create [] in
      match Runtime.create ~config ~llm sw with
      | Error e -> Alcotest.failf "Runtime.create: %s" (error_to_string e)
      | Ok rt ->
        (match Runtime.invoke_parallel ~rt ~specs:[] () with
         | Error e ->
           Alcotest.failf "empty specs should succeed, got: %s" (error_to_string e)
         | Ok result ->
           Alcotest.(check int) "0 successes" 0 (List.length result.successes);
           Alcotest.(check int) "0 failures" 0 (List.length result.failures);
           Alcotest.(check bool) "merged is None" true (result.merged = None));
        ignore (Runtime.close rt)))

let () =
  Alcotest.run "parallel_with_approval_e2e" [
    ("parallel_dispatch", [
      Alcotest.test_case "3 agents parallel, no approval, all complete" `Quick
        test_parallel_three_agents_no_approval;
      Alcotest.test_case "3 agents: A,B no approval; C sync approval → all complete" `Quick
        test_parallel_with_sync_approval_handler;
      Alcotest.test_case "unknown agent_id → appears in failures" `Quick
        test_parallel_unknown_agent;
      Alcotest.test_case "empty specs → empty successes/failures" `Quick
        test_parallel_empty_specs;
    ]);
  ]
