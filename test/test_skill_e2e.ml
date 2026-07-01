open Par
open Par.Types

let config_json = {|{"persistence": ["Sqlite", ":memory:"], "event_bus": {"buffer_capacity": 10, "delivery": {"max_delivery_attempts": 3, "initial_retry_delay": 0.1, "retry_backoff": ["Fixed", 0.5], "delivery_timeout": 5.0}, "dlq_enabled": false, "dlq_max_size": 1000, "critical_event_types": []}, "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2, "max_tokens_per_turn": null, "max_total_tokens": null}, "shutdown": {"drain_timeout": 5.0, "cancel_grace_period": 2.0, "flush_batch_size": 100}, "llm_providers": [], "eval_limits": {"max_depth": 10, "max_node_visits": 1000}, "parallel_tool_execution": true}|}

let () =
  let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
    | Ok c -> c
    | Error msg -> prerr_endline ("config parse: " ^ msg); exit 1
  in
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let (llm, history) = Mock_provider.create [Mock_provider.Text "ok"] in
      match Runtime.create ~config ~llm sw with
      | Error _ -> prerr_endline "create failed"; exit 1
      | Ok rt ->
        let model = { provider = `Openai; model_name = "t"; api_base = None; temperature = 0.7; max_tokens = None; top_p = None; stop_sequences = None } in
        let agent = match Runtime.make_agent ~id:"t" ~system_prompt:(stable_prompt "ORIGINAL") ~model () with Ok a -> a | Error _ -> prerr_endline "make_agent"; exit 1 in
        ignore (Runtime.register_agent rt agent);
        let skill = match Runtime.make_skill ~id:"ov" ~description:"d" ~system_prompt_override:(Stable_prompt "OVERRIDDEN") ~trigger:Auto () with Ok s -> s | Error _ -> prerr_endline "make_skill"; exit 1 in
        ignore (Runtime.register_skill rt skill);
        (match Runtime.invoke rt ~agent_id:"t" ~message:"hi" () with
         | Error _ -> prerr_endline "invoke failed"; exit 1
         | Ok _ ->
           match Mock_provider.last_complete_call history with
           | None -> prerr_endline "FAIL: no call"; exit 1
           | Some r ->
             match r.Mock_provider.conversation.messages with
             | f :: _ ->
                let p = Option.value (Message.content_opt f) ~default:"<none>" in
               Printf.printf "system_prompt_sent = %S\n" p;
               if p = "OVERRIDDEN" then print_endline "ALL 3 RISKS VERIFIED"
               else (Printf.eprintf "FAIL: expected OVERRIDDEN got %S\n" p; exit 1)
             | [] -> prerr_endline "FAIL: empty msgs"; exit 1);
        ignore (Runtime.close rt)))
