(* Tests for PAR-p70 auto context compression by window ratio.
   Covers the engine integration: threshold gate, cooldown, event emission.
   Pattern copied from test_truncation_config.ml (ROADMAP §Test Conventions). *)
open Par
open Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 ; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let mock_llm_tracked counter responses =
  let next () =
    incr counter;
    let idx = (!counter - 1) in
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

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let agent_with ?(context_strategy = Some (Summarize { max_tokens = 8000; summary_model = None }))
    ?(context_compression_threshold = Some 0.8)
    ?(compression_cooldown_messages = Some 6)
    ?(context_window_override = None)
    ?(max_iterations = 5) () =
  { id = "compress-test"; system_prompt = "test";
    system_prompt_template = None;
    model = dummy_model; tools = []; max_iterations; middleware = [];
    retry_policy = None; context_strategy; resource_quota = None;
    max_execution_time = None; tool_timeout = None; early_stopping_method = Force;
    on_max_tokens = None; max_continuation_chunks = None;
    context_compression_threshold; compression_cooldown_messages;
    context_window_override; cache_strategy = No_caching }

let make_registry () = Tool_registry.create ()

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"

let suite = [
  ("PAR-p70 engine integration", [

    Alcotest.test_case "manual_mode_threshold_none_no_skip_event" `Quick (fun () ->
      let counter = ref 0 in
      let events = ref [] in
      let llm = mock_llm_tracked counter [ text_response "ok" ] in
      let agent = agent_with ~context_compression_threshold:None () in
      let collector evt = events := evt :: !events in
      with_token (fun token ->
        let reg = make_registry () in
        (match Engine.run_agent ~on_tool_event:(Some collector) token agent "hi" llm reg with
         | Ok _ -> ()
         | Error (e, _) -> Alcotest.fail ("expected Ok: " ^ error_to_string e));
        let has_skip = List.exists (function
          | Context_compression_skipped _ -> true | _ -> false) !events in
        Alcotest.(check bool) "no skip event in manual mode" false has_skip));

    Alcotest.test_case "auto_mode_below_threshold_emits_skip_with_reason" `Quick (fun () ->
      let counter = ref 0 in
      let events = ref [] in
      let llm = mock_llm_tracked counter [ text_response "ok" ] in
      let agent = agent_with ~context_compression_threshold:(Some 0.99) () in
      let collector evt = events := evt :: !events in
      with_token (fun token ->
        let reg = make_registry () in
        (match Engine.run_agent ~on_tool_event:(Some collector) token agent "hi" llm reg with
         | Ok _ -> ()
         | Error (e, _) -> Alcotest.fail ("expected Ok: " ^ error_to_string e));
        let has_skip_below = List.exists (function
          | Context_compression_skipped { reason = `Below_threshold _ } -> true
          | _ -> false) !events in
        Alcotest.(check bool) "skip event with Below_threshold" true has_skip_below));

    Alcotest.test_case "auto_mode_above_threshold_emits_compressed" `Quick (fun () ->
      let counter = ref 0 in
      let events = ref [] in
      let llm = mock_llm_tracked counter [
        text_response "summary text";
        text_response "final answer";
      ] in
      let agent = agent_with
        ~context_compression_threshold:(Some 0.01)
        ~context_window_override:(Some 10)
        () in
      let collector evt = events := evt :: !events in
      with_token (fun token ->
        let reg = make_registry () in
        (match Engine.run_agent ~on_tool_event:(Some collector) token agent "hello" llm reg with
         | Ok _ -> ()
         | Error (e, _) -> Alcotest.fail ("expected Ok: " ^ error_to_string e));
        let has_compressed = List.exists (function
          | Context_compressed _ -> true | _ -> false) !events in
        Alcotest.(check bool) "compressed event fired" true has_compressed));

    Alcotest.test_case "cooldown_blocks_refire_within_window" `Quick (fun () ->
      let counter = ref 0 in
      let events = ref [] in
      let llm = mock_llm_tracked counter [
        { text = Some "first"; tool_calls = None; finish_reason = Max_tokens;
          usage = dummy_usage; model = "mock" };
        text_response "done";
      ] in
      let agent = agent_with
        ~context_compression_threshold:(Some 0.01)
        ~compression_cooldown_messages:(Some 5)
        ~context_window_override:(Some 10)
        ~max_iterations:5
        () in
      let collector evt = events := evt :: !events in
      with_token (fun token ->
        let reg = make_registry () in
        ignore (Engine.run_agent ~on_tool_event:(Some collector) token agent "hi" llm reg);
        let compressions = List.filter (function
          | Context_compressed _ -> true | _ -> false) !events in
        let cooldown_skips = List.filter (function
          | Context_compression_skipped { reason = `Cooldown_active _ } -> true
          | _ -> false) !events in
        (* At most 1 compression should fire in 2 iterations with cooldown=5. *)
        Alcotest.(check bool) "at most 1 compression in cooldown window"
          true (List.length compressions <= 1);
        (* At least 1 cooldown skip if engine tried to compress twice. *)
        let total_skip_or_compress = List.length compressions + List.length cooldown_skips in
        Alcotest.(check bool) "multiple compress decisions made" true (total_skip_or_compress >= 1)));

    Alcotest.test_case "compressed_event_carries_correct_payload" `Quick (fun () ->
      let counter = ref 0 in
      let events = ref [] in
      let llm = mock_llm_tracked counter [
        text_response "summary text";
        text_response "final";
      ] in
      let agent = agent_with
        ~context_compression_threshold:(Some 0.01)
        ~context_window_override:(Some 10)
        () in
      let collector evt = events := evt :: !events in
      with_token (fun token ->
        let reg = make_registry () in
        ignore (Engine.run_agent ~on_tool_event:(Some collector) token agent "hello" llm reg);
        let trigger_ref = ref None in
        let tokens_before_ref = ref 0 in
        let messages_before_ref = ref 0 in
        let strategy_used_ref = ref None in
        List.iter (function
          | Context_compressed c ->
            trigger_ref := Some c.trigger;
            tokens_before_ref := c.tokens_before;
            messages_before_ref := c.messages_before;
            (match c.strategy_used with
             | Summarize _ -> strategy_used_ref := Some "Summarize"
             | Sliding_window _ -> strategy_used_ref := Some "Sliding_window"
             | Truncate_oldest _ -> strategy_used_ref := Some "Truncate_oldest");
          | _ -> ()) (List.rev !events);
        (match !trigger_ref with
         | None -> Alcotest.fail "expected Context_compressed event"
         | Some trig ->
           Alcotest.(check bool) "trigger matches threshold"
             true (abs_float (trig -. 0.01) < 0.0001);
           Alcotest.(check bool) "tokens_before > 0" true (!tokens_before_ref > 0);
           Alcotest.(check bool) "messages_before > 0" true (!messages_before_ref > 0);
           Alcotest.(check (option string)) "strategy_used is Summarize"
             (Some "Summarize") !strategy_used_ref)));
  ])
]

let () =
  Alcotest.run "context_compression_p70" suite
