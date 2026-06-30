open Par

let dummy_msg role content =
  { Types.role = role; content = Some content;
    tool_calls = None; tool_call_id = None; name = None }

let dummy_model ~name =
  { Types.provider = `Openai; model_name = name; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

(* complete_fn is a failwith stub: the pure helpers under test never
   invoke it. If a test triggers an LLM call, the failure surfaces
   immediately instead of silently returning fake data. *)
let dummy_llm ?context_window_fn () : Types.llm_service =
  { complete_fn = (fun _ _ _ ->
       failwith "dummy_llm.complete_fn should not be called in this test");
    stream_fn = (fun _ _ _ _ _ ->
       failwith "dummy_llm.stream_fn should not be called in this test");
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = context_window_fn }

let dummy_conv () =
  { Types.messages = []; metadata = [] }

let () =
  Alcotest.run "context_manager" [
    ("estimate_tokens", [
      Alcotest.test_case "empty_conversation_zero_tokens" `Quick (fun () ->
        let conv = { Types.messages = []; metadata = [] } in
        Alcotest.(check int) "empty conv" 0 (Context_manager.estimate_tokens conv));

      Alcotest.test_case "nonempty_counts_chars" `Quick (fun () ->
        let conv = {
          Types.messages = [dummy_msg Types.User (String.make 40 'x')];
          metadata = [];
        } in
        let tokens = Context_manager.estimate_tokens conv in
        Alcotest.(check bool) "40 chars → ~10 tokens" (tokens > 0 && tokens <= 15) true);
    ]);

    ("truncate_conversation", [
      Alcotest.test_case "small_conv_unchanged" `Quick (fun () ->
        let conv = {
          Types.messages = [dummy_msg Types.User "hello"];
          metadata = [];
        } in
        let truncated = Context_manager.truncate_conversation
          ~min_messages:1 ~max_tokens:1000 conv in
        Alcotest.(check int) "still 1 message"
          1 (List.length truncated.Types.messages));

      Alcotest.test_case "drops_oldest_to_fit_budget" `Quick (fun () ->
        let msgs = List.init 10 (fun i ->
          dummy_msg Types.User (String.make 100 (char_of_int (48 + i))))
        in
        let conv = { Types.messages = msgs; metadata = [] } in
        let truncated = Context_manager.truncate_conversation
          ~min_messages:2 ~max_tokens:50 conv in
        let n = List.length truncated.Types.messages in
        Alcotest.(check bool) "dropped some messages" (n < 10) true);
    ]);

    (* ------------------------------------------------------------------ *)
    (* PAR-p70: pure helpers for auto context compression                 *)
    (* ------------------------------------------------------------------ *)

    ("default_context_window", [
      Alcotest.test_case "gpt4o_family_128k" `Quick (fun () ->
        let names = ["gpt-4o"; "gpt-4o-mini"; "gpt-4-turbo"] in
        List.iter (fun n ->
          Alcotest.(check int) (n ^ " → 128000")
            128000
            (Context_manager.default_context_window (dummy_model ~name:n)))
          names);

      Alcotest.test_case "gpt-3.5-turbo_16385" `Quick (fun () ->
        Alcotest.(check int) "gpt-3.5-turbo → 16385"
          16385
          (Context_manager.default_context_window
             (dummy_model ~name:"gpt-3.5-turbo")));

      Alcotest.test_case "claude_and_o1o3o4_200k" `Quick (fun () ->
        let names = ["claude-sonnet-4"; "claude-opus-4"; "claude-haiku-3.5";
                     "o1"; "o3"; "o4-mini"] in
        List.iter (fun n ->
          Alcotest.(check int) (n ^ " → 200000")
            200000
            (Context_manager.default_context_window (dummy_model ~name:n)))
          names);

      Alcotest.test_case "unknown_model_safe_default_8000" `Quick (fun () ->
        Alcotest.(check int) "unknown → 8000"
          8000
          (Context_manager.default_context_window
             (dummy_model ~name:"some-future-model-2027")));
    ]);

    ("resolve_context_window", [
      Alcotest.test_case "user_override_wins" `Quick (fun () ->
        (* override differs from any table value; should win *)
        let llm = dummy_llm ~context_window_fn:(fun () -> 999999) () in
        let model = dummy_model ~name:"gpt-4o" in
        Alcotest.(check int) "override=50000 wins"
          50000
          (Context_manager.resolve_context_window ~llm ~model
             ~user_override:(Some 50000)));

      Alcotest.test_case "provider_cap_wins_over_table" `Quick (fun () ->
        (* llm declares 128000, table for unknown model is 8000 → 128000 wins *)
        let llm = dummy_llm ~context_window_fn:(fun () -> 128000) () in
        let model = dummy_model ~name:"some-unknown-model" in
        Alcotest.(check int) "provider cap 128000 wins over table 8000"
          128000
          (Context_manager.resolve_context_window ~llm ~model
             ~user_override:None));

      Alcotest.test_case "falls_through_to_static_table" `Quick (fun () ->
        let llm = dummy_llm () in
        let model = dummy_model ~name:"gpt-4o" in
        Alcotest.(check int) "no fn, no override → table gpt-4o → 128000"
          128000
          (Context_manager.resolve_context_window ~llm ~model
             ~user_override:None));

      Alcotest.test_case "unknown_no_fn_no_override_returns_safe_default" `Quick (fun () ->
        (* DEVIATION NOTE: spec test list item #8 said "returns 0" here, but
           the plan's default_context_window always returns ≥8000 (safe
           conservative default), so resolve_context_window likewise returns
           the safe default rather than 0. Documented in report. *)
        let llm = dummy_llm () in
        let model = dummy_model ~name:"some-future-llm" in
        Alcotest.(check int) "unknown model, no fn, no override → 8000 (safe)"
          8000
          (Context_manager.resolve_context_window ~llm ~model
             ~user_override:None));
    ]);

    ("estimated_tokens_with_margin", [
      Alcotest.test_case "applies_1.2x_safety_margin" `Quick (fun () ->
        (* 40000 chars → raw 10000 → margin 12000 *)
        let conv = {
          Types.messages = [dummy_msg Types.User (String.make 40000 'x')];
          metadata = [];
        } in
        Alcotest.(check int) "raw=10000 → 12000"
          12000
          (Context_manager.estimated_tokens_with_margin conv));

      Alcotest.test_case "empty_conv_zero_with_margin" `Quick (fun () ->
        Alcotest.(check int) "empty → 0"
          0
          (Context_manager.estimated_tokens_with_margin (dummy_conv ())));
    ]);

    ("should_compress", [
      Alcotest.test_case "ratio_above_threshold_compresses" `Quick (fun () ->
        (* conv with 102400 chars → raw=25600 tokens (with margin=30720),
           window=128000 (gpt-4o), threshold=0.2 → ratio≈0.24 → compress *)
        let conv = {
          Types.messages = [dummy_msg Types.User (String.make 102400 'x')];
          metadata = [];
        } in
        let llm = dummy_llm () in
        let model = dummy_model ~name:"gpt-4o" in
        let should_compress, reason =
          Context_manager.should_compress
            ~threshold:(Some 0.2)
            ~cooldown:(Some 6)
            ~llm ~model ~conv
            ~iterations_since_last_compress:100
            ~window_override:None
        in
        Alcotest.(check bool) "true when ratio ≥ threshold" true should_compress;
        Alcotest.(check bool) "no skip reason" true (reason = None));

      Alcotest.test_case "ratio_below_threshold_skips_with_reason" `Quick (fun () ->
        (* conv with 40 chars → 10 raw / 12 with margin,
           window=128000 → ratio ~0.00009, threshold=0.8 → skip *)
        let conv = {
          Types.messages = [dummy_msg Types.User "hello world foo bar"];
          metadata = [];
        } in
        let llm = dummy_llm () in
        let model = dummy_model ~name:"gpt-4o" in
        let should_compress, reason =
          Context_manager.should_compress
            ~threshold:(Some 0.8)
            ~cooldown:(Some 6)
            ~llm ~model ~conv
            ~iterations_since_last_compress:0
            ~window_override:None
        in
        Alcotest.(check bool) "false when ratio < threshold" false should_compress;
        Alcotest.(check bool) "Some (`Below_threshold ratio)" true (reason <> None));

      Alcotest.test_case "cooldown_active_skips_with_remaining" `Quick (fun () ->
        (* Force ratio above threshold with small window + large conv *)
        let conv = {
          Types.messages = [dummy_msg Types.User (String.make 40000 'x')];
          metadata = [];
        } in
        let llm = dummy_llm () in
        let model = dummy_model ~name:"custom" in
        let should_compress, reason =
          Context_manager.should_compress
            ~threshold:(Some 0.01)
            ~cooldown:(Some 6)
            ~llm ~model ~conv
            ~iterations_since_last_compress:2
            ~window_override:None
        in
        Alcotest.(check bool) "false during cooldown" false should_compress;
        Alcotest.(check bool) "Some (`Cooldown_active 4)" true (reason <> None));

      Alcotest.test_case "window_zero_skips_with_no_window_size" `Quick (fun () ->
        (* Explicit override=0 → window resolves to 0 → skip *)
        let conv = {
          Types.messages = [dummy_msg Types.User (String.make 40000 'x')];
          metadata = [];
        } in
        let llm = dummy_llm () in
        let model = dummy_model ~name:"gpt-4o" in
        let should_compress, reason =
          Context_manager.should_compress
            ~threshold:(Some 0.1)
            ~cooldown:(Some 6)
            ~llm ~model ~conv
            ~iterations_since_last_compress:0
            ~window_override:(Some 0)
        in
        Alcotest.(check bool) "false when window=0" false should_compress;
        Alcotest.(check bool) "Some `No_window_size" true (reason <> None));

      Alcotest.test_case "threshold_none_is_manual_mode_no_skip_reason" `Quick (fun () ->
        (* threshold=None → manual mode → (false, None) regardless of ratio *)
        let conv = {
          Types.messages = [dummy_msg Types.User (String.make 400000 'x')];
          metadata = [];
        } in
        let llm = dummy_llm () in
        let model = dummy_model ~name:"gpt-4o" in
        let should_compress, reason =
          Context_manager.should_compress
            ~threshold:None
            ~cooldown:None
            ~llm ~model ~conv
            ~iterations_since_last_compress:0
            ~window_override:None
        in
        Alcotest.(check bool) "false when threshold=None" false should_compress;
        Alcotest.(check bool) "no skip reason (manual mode)" true (reason = None));

      Alcotest.test_case "cooldown_none_below_threshold_skips" `Quick (fun () ->
        (* cooldown=None, ratio<threshold → skip with Below_threshold *)
        let conv = {
          Types.messages = [dummy_msg Types.User "tiny"];
          metadata = [];
        } in
        let llm = dummy_llm () in
        let model = dummy_model ~name:"gpt-4o" in
        let should_compress, reason =
          Context_manager.should_compress
            ~threshold:(Some 0.8)
            ~cooldown:None
            ~llm ~model ~conv
            ~iterations_since_last_compress:0
            ~window_override:None
        in
        Alcotest.(check bool) "false when cooldown=None and ratio<threshold"
          false should_compress;
        Alcotest.(check bool) "Some `Below_threshold" true (reason <> None));
    ]);

    ("apply_default_summarize", [
      Alcotest.test_case "small_conv_passthrough" `Quick (fun () ->
        let llm = dummy_llm () in
        let model = dummy_model ~name:"gpt-4o" in
        let result =
          Context_manager.apply_default_summarize ~llm ~model ~window:128000 ~on_event:None (dummy_conv ())
        in
        Alcotest.(check int) "0 messages unchanged"
          0
          (match result with
           | Ok conv -> List.length conv.Types.messages
           | Error _ -> -1));
    ]);
  ]