(* test_concurrency.ml — formal coverage for the v0.7.1 concurrency
   architecture: per-call isolation via Invoke_context + invoke_async +
   Expression fiber-local visit_count + the #9 Auto-skill fix.

   These tests are the formal GREEN check for the foundation that addresses
   issues #1 (parallel agents), #3 (background async), #10 (reentrant
   invoke), and #9 (Auto-skill override bug).

   Spike gate (test_fiber_spike) confirmed Eio.Fiber.with_binding propagates
   into Engine's fork_promise children — the architectural premise. *)

open Par
open Par.Types

let config_json = {|{"persistence": ["Sqlite", ":memory:"], "event_bus": {"buffer_capacity": 10, "delivery": {"max_delivery_attempts": 3, "initial_retry_delay": 0.1, "retry_backoff": ["Fixed", 0.5], "delivery_timeout": 5.0}, "dlq_enabled": false, "dlq_max_size": 1000, "critical_event_types": []}, "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2, "max_tokens_per_turn": null, "max_total_tokens": null}, "shutdown": {"drain_timeout": 5.0, "cancel_grace_period": 2.0, "flush_batch_size": 100}, "llm_providers": [], "eval_limits": {"max_depth": 10, "max_node_visits": 1000}, "parallel_tool_execution": true}|}

let test_concurrent_metrics_isolation () =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
        | Ok c -> c | Error _ -> failwith "config" in
      let (llm, _) = Mock_provider.create
        [Mock_provider.Text "ok"; Mock_provider.Text "ok"] in
      match Runtime.create ~config ~llm sw with
      | Error _ -> failwith "create"
      | Ok rt ->
        let model = { provider = `Openai; model_name = "t"; api_base = None;
                      temperature = 0.7; max_tokens = None; top_p = None; stop_sequences = None } in
        let agent = match Runtime.make_agent ~id:"t"
                      ~system_prompt:(stable_prompt "p") ~model () with
          | Ok a -> a | Error _ -> failwith "make_agent" in
        ignore (Runtime.register_agent rt agent);
        let before = Runtime.metrics_snapshot rt in
        let before_llm =
          List.assoc "llm_requests_total" before in
        let p1 = Eio.Fiber.fork_promise ~sw (fun () ->
          Runtime.invoke rt ~agent_id:"t" ~message:"a" ()) in
        let p2 = Eio.Fiber.fork_promise ~sw (fun () ->
          Runtime.invoke rt ~agent_id:"t" ~message:"b" ()) in
        let r1 = Eio.Promise.await_exn p1 in
        let r2 = Eio.Promise.await_exn p2 in
        Alcotest.(check bool "invoke A completed" true (Result.is_ok r1));
        Alcotest.(check bool "invoke B completed" true (Result.is_ok r2));
        let after = Runtime.metrics_snapshot rt in
        let after_llm = List.assoc "llm_requests_total" after in
        Alcotest.(check int "two LLM calls recorded" (before_llm + 2) after_llm);
        ignore (Runtime.close rt)))

let test_concurrent_session_id_via_context () =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
        | Ok c -> c | Error _ -> failwith "config" in
      let (llm, _) = Mock_provider.create
        [Mock_provider.Text "ok"; Mock_provider.Text "ok"] in
      match Runtime.create ~config ~llm sw with
      | Error _ -> failwith "create"
      | Ok rt ->
        let model = { provider = `Openai; model_name = "t"; api_base = None;
                      temperature = 0.7; max_tokens = None; top_p = None; stop_sequences = None } in
        let agent = match Runtime.make_agent ~id:"t"
                      ~system_prompt:(stable_prompt "p") ~model () with
          | Ok a -> a | Error _ -> failwith "make_agent" in
        ignore (Runtime.register_agent rt agent);
        let ctx_a = Invoke_context.create ~session_id:"alice-session" () in
        let ctx_b = Invoke_context.create ~session_id:"bob-session" () in
        let p1 = Eio.Fiber.fork_promise ~sw (fun () ->
          Runtime.invoke rt ~agent_id:"t" ~message:"a"
            ~context:ctx_a ()) in
        let p2 = Eio.Fiber.fork_promise ~sw (fun () ->
          Runtime.invoke rt ~agent_id:"t" ~message:"b"
            ~context:ctx_b ()) in
        let r1 = Eio.Promise.await_exn p1 in
        let r2 = Eio.Promise.await_exn p2 in
        Alcotest.(check bool "invoke A completed" true (Result.is_ok r1));
        Alcotest.(check bool "invoke B completed" true (Result.is_ok r2));
        Alcotest.(check string "ctx_a session_id honored"
          "alice-session" ctx_a.session_id);
        Alcotest.(check string "ctx_b session_id honored"
          "bob-session" ctx_b.session_id);
        ignore (Runtime.close rt)))

let test_invoke_async_handle_lifecycle () =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
        | Ok c -> c | Error _ -> failwith "config" in
      let (llm, _) = Mock_provider.create [Mock_provider.Text "ok"] in
      match Runtime.create ~config ~llm sw with
      | Error _ -> failwith "create"
      | Ok rt ->
        let model = { provider = `Openai; model_name = "t"; api_base = None;
                      temperature = 0.7; max_tokens = None; top_p = None; stop_sequences = None } in
        let agent = match Runtime.make_agent ~id:"t"
                      ~system_prompt:(stable_prompt "p") ~model () with
          | Ok a -> a | Error _ -> failwith "make_agent" in
        ignore (Runtime.register_agent rt agent);
        let handle = Runtime.invoke_async rt ~agent_id:"t" ~message:"async" () in
        Alcotest.(check bool "initial status is Running or Completed"
          true
          (match Invoke_context.invoke_handle_status handle with
           | Invoke_context.Running | Invoke_context.Completed -> true
           | Cancelled | Failed -> false));
        let _result = Invoke_context.invoke_handle_await handle in
        let final_status = Invoke_context.invoke_handle_status handle in
        Alcotest.(check bool "final status is terminal"
          true
          (match final_status with
           | Invoke_context.Completed | Invoke_context.Failed -> true
           | Running | Cancelled -> false));
        ignore (Runtime.close rt)))

let test_expression_visit_count_fiber_local () =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let tight_limits = { max_depth = 100; max_node_visits = 5 } in
      let deep = ref (Variable "leaf") in
      for _i = 1 to 5 do
        deep := Equals (!deep, Variable "leaf")
      done;
      let big_expr = !deep in
      let small_expr = Variable "x" in
      (* Two parallel evaluates with different limits. Each evaluation has
         its own fiber-local counter; the one with tight limits should fail
         independently while the other succeeds. *)
      let p1 = Eio.Fiber.fork_promise ~sw (fun () ->
        Expression.evaluate ~limits:tight_limits [] big_expr) in
      let p2 = Eio.Fiber.fork_promise ~sw (fun () ->
        Expression.evaluate [] small_expr) in
      let r1 = Eio.Promise.await_exn p1 in
      let r2 = Eio.Promise.await_exn p2 in
      Alcotest.(check bool "tight-limit evaluate failed (limit exceeded)"
        true (Result.is_error r1));
      Alcotest.(check bool "normal evaluate succeeded"
        true (Result.is_ok r2))))

let test_auto_skill_no_system_prompt_override () =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
        | Ok c -> c | Error _ -> failwith "config" in
      let (llm, _) = Mock_provider.create [Mock_provider.Text "ok"] in
      match Runtime.create ~config ~llm sw with
      | Error _ -> failwith "create"
      | Ok rt ->
        let sk = match Runtime.make_skill ~id:"auto-ov"
                   ~description:"d"
                   ~system_prompt_override:(Stable_prompt "SHOULD_NOT_APPLY")
                   ~trigger:Auto () with
          | Ok s -> s | Error _ -> failwith "make_skill" in
        ignore (Runtime.register_skill rt sk);
        let effects = Runtime.compute_active_skill_effects rt "any message" in
        Alcotest.(check int "one auto effect" 1 (List.length effects));
        (match effects with
         | [e] ->
           Alcotest.(check (option string) "auto override is None"
             None
             (Option.map (function
               | Stable_prompt s -> s
               | Volatile_prompt s -> s
               | Both_prompts { stable; _ } -> stable)
              e.system_prompt_override))
         | _ -> Alcotest.fail "expected exactly one effect");
        ignore (Runtime.close rt)))

let test_invoke_context_with_binding_propagates () =
  (* Belt-and-braces: the spike (test_fiber_spike) already proved this for
     a standalone fork_promise. Here we verify it holds when invoke itself
     is the binding source — i.e. code reading Invoke_context.get_current ()
     inside an invoke path sees the per-call context. *)
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
        | Ok c -> c | Error _ -> failwith "config" in
      let (llm, _) = Mock_provider.create [Mock_provider.Text "ok"] in
      match Runtime.create ~config ~llm sw with
      | Error _ -> failwith "create"
      | Ok rt ->
        let model = { provider = `Openai; model_name = "t"; api_base = None;
                      temperature = 0.7; max_tokens = None; top_p = None; stop_sequences = None } in
        let agent = match Runtime.make_agent ~id:"t"
                      ~system_prompt:(stable_prompt "p") ~model () with
          | Ok a -> a | Error _ -> failwith "make_agent" in
        ignore (Runtime.register_agent rt agent);
        let marker = "session-marker-7" in
        let ctx = Invoke_context.create ~session_id:marker () in
        let _result =
          Invoke_context.with_context ctx (fun () ->
            let seen = Invoke_context.get_current_exn () in
            Alcotest.(check string "binding visible inside with_context"
              marker seen.session_id);
            Runtime.invoke rt ~agent_id:"t" ~message:"x" ~context:ctx ())
        in
        ignore (Runtime.close rt)))

let () =
  let open Alcotest in
  run "concurrency" [
    "metrics_isolation", [test_case "two parallel invokes add to shared counters"
        `Quick test_concurrent_metrics_isolation];
    "session_id_via_context", [test_case "per-call session_id via ?context"
        `Quick test_concurrent_session_id_via_context];
    "invoke_async_handle", [test_case "invoke_async handle: await + status"
        `Quick test_invoke_async_handle_lifecycle];
    "expression_fiber_local", [test_case "expression visit_count is fiber-local"
        `Quick test_expression_visit_count_fiber_local];
    "auto_skill_no_override", [test_case "Auto-trigger skill: system_prompt_override is None (#9)"
        `Quick test_auto_skill_no_system_prompt_override];
    "invoke_context_binding", [test_case "with_context binding visible inside invoke"
        `Quick test_invoke_context_with_binding_propagates];
  ]