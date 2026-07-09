open Par
open Par.Types

let zone_str = function
  | Stable_prompt s | Volatile_prompt s -> s
  | Both_prompts { stable; _ } -> stable

(* test/test_skill_user_activation.ml — v0.5.4 PAR-bd8
   Coverage: Runtime.set_user_activated_skills / clear / get and
   compute_active_skill_effects' resolution of manually-activated skills
   (Manual-trigger skills are dead weight without this path).

   Pattern mirrors test_skill_e2e.ml: real runtime + Mock_provider,
   inspect the conversation sent to the LLM to verify the skill effect. *)

let config_json = {|{"persistence": ["Sqlite", ":memory:"], "event_bus": {"buffer_capacity": 10, "delivery": {"max_delivery_attempts": 3, "initial_retry_delay": 0.1, "retry_backoff": ["Fixed", 0.5], "delivery_timeout": 5.0}, "dlq_enabled": false, "dlq_max_size": 1000, "critical_event_types": []}, "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2, "max_tokens_per_turn": null, "max_total_tokens": null}, "shutdown": {"drain_timeout": 5.0, "cancel_grace_period": 2.0, "flush_batch_size": 100}, "llm_providers": [], "eval_limits": {"max_depth": 10, "max_node_visits": 1000}, "parallel_tool_execution": true}|}

let first_message_content (conv : conversation) =
  match conv.messages with
  | { content_blocks = [Text_block { text = p; cache_control = None }]; _ } :: _ -> p
  | _ -> "<none>"

let with_runtime f =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
        | Ok c -> c
        | Error msg -> prerr_endline ("config parse: " ^ msg); exit 1
      in
      let (llm, history) = Mock_provider.create [Mock_provider.Text "ok"] in
      match Runtime.create ~config ~llm sw with
      | Error _ -> prerr_endline "create failed"; exit 1
      | Ok rt ->
        let model = { provider = `Openai; model_name = "t"; api_base = None;
                      temperature = 0.7; max_tokens = None; top_p = None;
                      stop_sequences = None } in
        let agent = match Runtime.make_agent ~id:"t" ~system_prompt:(stable_prompt "ORIGINAL") ~model () with
          | Ok a -> a | Error _ -> prerr_endline "make_agent"; exit 1 in
        ignore (Runtime.register_agent rt agent);
        f rt history;
        ignore (Runtime.close rt)))

let () =
  let open Alcotest in
  let tests = [
    test_case "manual skill NOT active without user_activated_skills" `Quick (fun () ->
      with_runtime (fun rt _history ->
        (* A Manual-trigger skill is never auto-activated *)
        let sk = match Runtime.make_skill ~id:"m1" ~description:"d"
                   ~system_prompt_override:(Stable_prompt "MANUAL_OVERRIDE") ~trigger:Manual () with
          | Ok s -> s | Error _ -> failwith "make_skill" in
        ignore (Runtime.register_skill rt sk);
        let effects = Runtime.compute_active_skill_effects rt "hello" in
        check int "no manual effect when not user-activated" 0 (List.length effects)));

    test_case "manual skill active via set_user_activated_skills" `Quick (fun () ->
      with_runtime (fun rt _history ->
        let sk = match Runtime.make_skill ~id:"m2" ~description:"d"
                   ~system_prompt_override:(Stable_prompt "MANUAL_OVERRIDE") ~trigger:Manual () with
          | Ok s -> s | Error _ -> failwith "make_skill" in
        ignore (Runtime.register_skill rt sk);
        Runtime.set_user_activated_skills rt ["m2"];
        check (list string) "get reflects set" ["m2"]
          (Runtime.get_user_activated_skills rt);
        let effects = Runtime.compute_active_skill_effects rt "hello" in
        check int "manual effect now present" 1 (List.length effects);
        let composed = Runtime.compose_skill_effects effects in
        check (option string) "override applied" (Some "MANUAL_OVERRIDE")
          (Option.map zone_str composed.system_prompt_override)));

    test_case "clear_user_activated_skills removes activation" `Quick (fun () ->
      with_runtime (fun rt _history ->
        let sk = match Runtime.make_skill ~id:"m3" ~description:"d"
                   ~system_prompt_override:(Stable_prompt "X") ~trigger:Manual () with
          | Ok s -> s | Error _ -> failwith "make_skill" in
        ignore (Runtime.register_skill rt sk);
        Runtime.set_user_activated_skills rt ["m3"];
        Runtime.clear_user_activated_skills rt;
        check (list string) "empty after clear" [] (Runtime.get_user_activated_skills rt);
        let effects = Runtime.compute_active_skill_effects rt "hello" in
        check int "no effect after clear" 0 (List.length effects)));

    test_case "user_activated composes with auto-triggered" `Quick (fun () ->
      with_runtime (fun rt _history ->
        (* Manual skill only via user_activated_skills *)
        let manual = match Runtime.make_skill ~id:"manual-skill" ~description:"d"
                      ~system_prompt_override:(Stable_prompt "FROM_MANUAL") ~trigger:Manual () with
          | Ok s -> s | Error _ -> failwith "make_skill" in
        ignore (Runtime.register_skill rt manual);
        (* Auto skill always active *)
        let auto = match Runtime.make_skill ~id:"auto-skill" ~description:"d"
                    ~system_prompt_override:(Stable_prompt "FROM_AUTO") ~trigger:Auto () with
          | Ok s -> s | Error _ -> failwith "make_skill" in
        ignore (Runtime.register_skill rt auto);
        Runtime.set_user_activated_skills rt ["manual-skill"];
        let effects = Runtime.compute_active_skill_effects rt "anything" in
        check int "both effects present" 2 (List.length effects);
        let ids = List.map (fun (e : skill_effect) ->
          Option.value (Option.map zone_str e.system_prompt_override) ~default:"") effects in
        check bool "manual present" true (List.mem "FROM_MANUAL" ids);
        (* #9 fix: Auto-trigger skills MUST NOT apply system_prompt_override.
           The auto skill contributes an effect, but its override is None. *)
        check bool "auto override stripped (#9 fix)" true
          (List.exists (fun (e : skill_effect) ->
             e.system_prompt_override = None) effects)));

    test_case "end-to-end: invoke with manual activation overrides system prompt" `Quick (fun () ->
      with_runtime (fun rt history ->
        let sk = match Runtime.make_skill ~id:"m-e2e" ~description:"d"
                   ~system_prompt_override:(Stable_prompt "OVERRIDDEN_VIA_USE") ~trigger:Manual () with
          | Ok s -> s | Error _ -> failwith "make_skill" in
        ignore (Runtime.register_skill rt sk);
        (* Without activation: Manual skill is dead, original prompt used *)
        (match Runtime.invoke rt ~agent_id:"t" ~message:"hi" () with
         | Error _ -> failwith "invoke 1 failed"
         | Ok _ ->
           match Mock_provider.last_complete_call history with
           | None -> failwith "no call recorded"
           | Some r ->
             check string "original prompt when not activated" "ORIGINAL"
               (first_message_content r.Mock_provider.conversation));
        (* With activation: override applied *)
        Runtime.set_user_activated_skills rt ["m-e2e"];
        (match Runtime.invoke rt ~agent_id:"t" ~message:"hi" () with
         | Error _ -> failwith "invoke 2 failed"
         | Ok _ ->
           (* Mock prepends records; last_complete_call = most recent = invoke 2 *)
           match Mock_provider.last_complete_call history with
           | None -> failwith "no second call recorded"
           | Some r ->
             check string "override applied after /skill use"
               "OVERRIDDEN_VIA_USE" (first_message_content r.Mock_provider.conversation))));

    test_case "user_activated_skills survives across invokes (persistent)" `Quick (fun () ->
      with_runtime (fun rt _history ->
        let sk = match Runtime.make_skill ~id:"persist" ~description:"d"
                   ~system_prompt_override:(Stable_prompt "PERSIST") ~trigger:Manual () with
          | Ok s -> s | Error _ -> failwith "make_skill" in
        ignore (Runtime.register_skill rt sk);
        Runtime.set_user_activated_skills rt ["persist"];
        let e1 = Runtime.compute_active_skill_effects rt "msg1" in
        let e2 = Runtime.compute_active_skill_effects rt "msg2" in
        check int "active on invoke 1" 1 (List.length e1);
        check int "still active on invoke 2" 1 (List.length e2)));

    test_case "unknown id in user_activated_skills is silently ignored" `Quick (fun () ->
      with_runtime (fun rt _history ->
        Runtime.set_user_activated_skills rt ["does-not-exist"];
        let effects = Runtime.compute_active_skill_effects rt "hello" in
        check int "unknown id ignored" 0 (List.length effects)));

    test_case "set_user_activated_skills replaces (not appends)" `Quick (fun () ->
      with_runtime (fun rt _history ->
        let s1 = match Runtime.make_skill ~id:"s1" ~description:"d" ~trigger:Manual () with
          | Ok s -> s | Error _ -> failwith "make_skill" in
        let s2 = match Runtime.make_skill ~id:"s2" ~description:"d" ~trigger:Manual () with
          | Ok s -> s | Error _ -> failwith "make_skill" in
        ignore (Runtime.register_skill rt s1);
        ignore (Runtime.register_skill rt s2);
        Runtime.set_user_activated_skills rt ["s1"];
        Runtime.set_user_activated_skills rt ["s2"];
        check (list string) "replaced not appended" ["s2"]
          (Runtime.get_user_activated_skills rt)));
  ] in
  run "skill_user_activation" [ "skill_user_activation", tests ]
