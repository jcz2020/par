(* Tests for Runtime.invoke_generate (plan §3.2).
   Wave 3 Task G — 6 tests covering the public long-output generation API.

   All 6 tests use Runtime.invoke_generate (Pattern B). Pattern A (direct
   Generate.run) is not viable here because the Generate module is not
   re-exported in lib/par.ml, so it is not externally accessible.

   Fixtures copied verbatim from test/test_integration.ml and
   test/test_truncation_config.ml per project convention
   (ROADMAP §Test Conventions point 3: no shared helpers). *)
open Par
open Types

(* -------------------------------------------------------------------------- *)
(* Fixtures (copy from test_integration.ml + test_truncation_config.ml)       *)
(* -------------------------------------------------------------------------- *)

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let max_tokens_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Max_tokens;
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
  }

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"

(* Runtime config: event_bus and shutdown defaults. The `\`Sqlite ":memory:"`
   field is only honored by the FFI layer; the OCaml SDK takes persistence
   as an explicit argument (see with_persisted_runtime below). *)
let test_runtime_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
}

let make_agent id system_prompt =
  match Runtime.make_agent ~id ~system_prompt ~model:dummy_model () with
  | Ok a -> a
  | Error e -> Alcotest.failf "make_agent failed: %s" (error_to_string e)

(* No-persistence helper. Uses Runtime's default noop_persistence. *)
let with_invoke_runtime ~llm ~agent (f : Par.Runtime.runtime -> 'a) : 'a =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      match Runtime.create ~llm ~config:test_runtime_config sw with
      | Error e ->
        Alcotest.failf "Runtime.create failed: %s" (error_to_string e)
      | Ok rt ->
        (match Runtime.register_agent rt agent with
         | Error e ->
           ignore (Runtime.close rt);
           Alcotest.failf "register_agent failed: %s" (error_to_string e)
         | Ok () ->
           let result =
             try f rt
             with exn ->
               ignore (Runtime.close rt);
               raise exn
           in
           ignore (Runtime.close rt);
           result)))

(* Persisted helper. Opens a real SQLite :memory: handle, wraps it as a
   persistence_service, and lets Runtime.close call the close_fn. Note:
   :memory: SQLite requires a single connection — we must NOT open a second
   handle in the same test (unlike the on-disk variant in
   test_session_resume_cli.ml). *)
let with_persisted_runtime ~llm ~agent (f : Par.Runtime.runtime -> 'a) : 'a =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      match Sqlite_persistence.create ":memory:" with
      | Error _ ->
        Alcotest.fail "Sqlite_persistence.create :memory: failed"
      | Ok sqlt ->
        let persist : persistence_service = {
          save_events_fn = (fun envs -> Sqlite_persistence.save_events sqlt envs);
          load_events_fn = (fun tid -> Sqlite_persistence.load_events sqlt tid);
          load_events_by_session_fn =
            (fun sid -> Sqlite_persistence.load_events_by_session sqlt sid);
          load_sessions_fn = (fun lim -> Sqlite_persistence.load_sessions sqlt lim);
          save_task_state_fn =
            (fun ts -> Sqlite_persistence.save_task_state sqlt ts);
          load_task_state_fn =
            (fun tid -> Sqlite_persistence.load_task_state sqlt tid);
          save_workflow_state_fn =
            (fun id st cp ->
              Sqlite_persistence.save_workflow_state sqlt id st cp);
          load_workflow_state_fn =
            (fun id -> Sqlite_persistence.load_workflow_state sqlt id);
          load_all_suspended_workflows_fn =
            (fun () -> Sqlite_persistence.load_all_suspended_workflows sqlt);
          save_workflow_def_fn =
            (fun id def -> Sqlite_persistence.save_workflow_def sqlt id def);
          load_all_workflow_defs_fn =
            (fun () -> Sqlite_persistence.load_all_workflow_defs sqlt);
          save_conversation_fn =
            (fun sid conv -> Sqlite_persistence.save_conversation sqlt sid conv);
          load_conversation_fn =
            (fun sid -> Sqlite_persistence.load_conversation sqlt sid);
          load_most_recent_conversation_fn =
            (fun () -> Sqlite_persistence.load_most_recent_conversation sqlt);
          close_fn = (fun () -> Sqlite_persistence.close sqlt);
        } in
        (match Runtime.create ~llm ~persistence:persist
                ~config:test_runtime_config sw with
         | Error e ->
           (try Sqlite_persistence.close sqlt with _ -> ());
           Alcotest.failf "Runtime.create failed: %s" (error_to_string e)
         | Ok rt ->
           (match Runtime.register_agent rt agent with
            | Error e ->
              ignore (Runtime.close rt);
              Alcotest.failf "register_agent failed: %s" (error_to_string e)
            | Ok () ->
              let result =
                try f rt
                with exn ->
                  ignore (Runtime.close rt);
                  raise exn
              in
              ignore (Runtime.close rt);
              result))))

(* -------------------------------------------------------------------------- *)
(* Test 1: invoke_generate_basic — single Stop response                       *)
(* -------------------------------------------------------------------------- *)

let test_invoke_generate_basic () =
  let counter = ref 0 in
  let llm = mock_llm_tracked counter [ text_response "hello world" ] in
  let agent = make_agent "basic-agent" "You are a test agent." in
  with_invoke_runtime ~llm ~agent (fun rt ->
    match Runtime.invoke_generate rt ~agent_id:"basic-agent" ~message:"hi" () with
    | Error (e, _) ->
      Alcotest.failf "invoke_generate failed: %s" (error_to_string e)
    | Ok result ->
      Alcotest.(check string) "text matches" "hello world" result.text;
      Alcotest.(check bool) "finish_reason is Stop"
        true (result.finish_reason = Stop);
      Alcotest.(check int) "no continuations" 0 result.continuations;
      Alcotest.(check int) "exactly one LLM call" 1 !counter)

(* -------------------------------------------------------------------------- *)
(* Test 2: invoke_generate_auto_continue — Max_tokens triggers Continue      *)
(* -------------------------------------------------------------------------- *)

let test_invoke_generate_auto_continue () =
  let counter = ref 0 in
  let long_text = String.make 600 'x' in
  let llm = mock_llm_tracked counter [
    max_tokens_response long_text;
    text_response "part2";
  ] in
  let agent = make_agent "auto-continue-agent" "You are a test agent." in
  with_invoke_runtime ~llm ~agent (fun rt ->
    match Runtime.invoke_generate rt ~agent_id:"auto-continue-agent"
        ~message:"hi" () with
    | Error (e, _) ->
      Alcotest.failf "invoke_generate failed: %s" (error_to_string e)
    | Ok result ->
      (* After fix: result.text is the CONCATENATED text across all
         continuations (matches Engine.run_agent's Continue behavior).
         The full output IS the artifact the caller asked for, not
         just the last chunk. *)
      let expected = long_text ^ "part2" in
      Alcotest.(check int) "exactly one continuation" 1 result.continuations;
      Alcotest.(check bool) "finish_reason is Stop (after Continue)"
        true (result.finish_reason = Stop);
      Alcotest.(check int) "two LLM calls (chunk1 Max_tokens + chunk2 Stop)"
        2 !counter;
      Alcotest.(check string) "result.text is concatenated (long_text + part2)"
        expected result.text)

(* -------------------------------------------------------------------------- *)
(* Test 3: invoke_generate_total_timeout — wall-clock cap fires              *)
(* -------------------------------------------------------------------------- *)

let test_invoke_generate_total_timeout () =
  let counter = ref 0 in
  let long_text = String.make 600 'y' in
  (* Mock returns Max_tokens forever. Once text is accumulated, the timeout
     branch in Generate.run fires finalize_ok Max_tokens (the timeout
     branch only returns Error Timeout if NO text has accumulated yet). *)
  let always_max_tokens _model _tools _conv =
    incr counter;
    Ok (max_tokens_response long_text)
  in
  let llm : llm_service = {
    complete_fn = always_max_tokens;
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
  } in
  let agent = make_agent "timeout-agent" "You are a test agent." in
  with_invoke_runtime ~llm ~agent (fun rt ->
    let result = Runtime.invoke_generate rt ~agent_id:"timeout-agent"
      ~message:"hi" ~total_timeout:0.001 () in
    match result with
    | Ok gen ->
      Alcotest.(check bool)
        "Ok finish_reason is Max_tokens (text was accumulated)"
        true (gen.finish_reason = Max_tokens);
      Alcotest.(check bool) "result.text non-empty (accumulated text)"
        true (String.length gen.text > 0)
    | Error (Timeout, _) ->
      Alcotest.(check bool) "Timeout error is acceptable per spec" true true
    | Error (e, _) ->
      Alcotest.failf "expected Ok Max_tokens or Timeout, got: %s"
        (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Test 4: invoke_generate_event_emission                                    *)
(* -------------------------------------------------------------------------- *)

let test_invoke_generate_event_emission () =
  let counter = ref 0 in
  let events : event list ref = ref [] in
  let collector evt = events := evt :: !events in
  let long_text = String.make 600 'z' in
  let llm = mock_llm_tracked counter [
    max_tokens_response long_text;
    text_response "part2";
  ] in
  let agent = make_agent "event-agent" "You are a test agent." in
  with_invoke_runtime ~llm ~agent (fun rt ->
    (match Runtime.invoke_generate rt ~agent_id:"event-agent"
        ~message:"hi" ~on_tool_event:collector () with
     | Ok _ -> ()
     | Error (e, _) -> Alcotest.failf "invoke_generate failed: %s"
         (error_to_string e));
    let evts = List.rev !events in
    let has_request = List.exists (function
      | Llm_request_sent _ -> true | _ -> false) evts in
    let has_response = List.exists (function
      | Llm_response_received _ -> true | _ -> false) evts in
    let has_truncated = List.exists (function
      | Llm_response_truncated _ -> true | _ -> false) evts in
    let has_continuation = List.exists (function
      | Generate_continuation _ -> true | _ -> false) evts in
    Alcotest.(check bool) "Llm_request_sent emitted" true has_request;
    Alcotest.(check bool) "Llm_response_received emitted" true has_response;
    Alcotest.(check bool) "Llm_response_truncated emitted (auto_continue case)"
      true has_truncated;
    Alcotest.(check bool) "Generate_continuation emitted (auto_continue case)"
      true has_continuation)

(* -------------------------------------------------------------------------- *)
(* Test 5: invoke_generate_session_persisted                                 *)
(* -------------------------------------------------------------------------- *)

let test_invoke_generate_session_persisted () =
  let counter = ref 0 in
  let llm = mock_llm_tracked counter [ text_response "persisted answer" ] in
  let agent = make_agent "session-agent" "You are a persistable agent." in
  with_persisted_runtime ~llm ~agent (fun rt ->
    match Runtime.invoke_generate rt ~agent_id:"session-agent"
        ~message:"remember this" () with
    | Error (e, _) ->
      Alcotest.failf "invoke_generate failed: %s" (error_to_string e)
    | Ok _ ->
      match Runtime.load_most_recent_conversation rt with
      | Ok None ->
        Alcotest.fail "load_most_recent_conversation returned None after invoke_generate"
      | Ok (Some (_sid, conv)) ->
        Alcotest.(check bool) "persisted conversation has >= 2 messages"
          true (List.length conv.messages >= 2);
        (match conv.messages with
         | sys_msg :: _ ->
           Alcotest.(check bool) "first message is System role"
             true (sys_msg.role = System);
           Alcotest.(check (option string))
             "system prompt preserved"
             (Some "You are a persistable agent.")
             sys_msg.content
         | [] -> Alcotest.fail "empty conversation list")
      | Error e ->
        Alcotest.failf "load_most_recent_conversation errored: %s"
          (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Test 6: invoke_generate_skill_overlay_applied                             *)
(* -------------------------------------------------------------------------- *)
(* A capturing llm_service stashes the system prompt from the conversation
   it receives. After registering a skill with system_prompt_override and an
   agent with system_prompt="original", invoke_generate must activate the
   skill and pass "OVERRIDDEN" to the LLM. *)

module Capturing_llm = struct
  type capture = {
    mutable captured_system : string option;
    mutable call_count : int;
  }

  let create () = {
    captured_system = None;
    call_count = 0;
  }

  let make_service capture =
    let complete_fn _model _tools (conv : conversation) =
      capture.call_count <- capture.call_count + 1;
      (match conv.messages with
       | sys_msg :: _ ->
         if sys_msg.role = System then
           capture.captured_system <- sys_msg.content
       | [] -> ());
      Ok (text_response "captured response")
    in
    { complete_fn;
      stream_fn = (fun _ _tools _ _ _ -> Ok {
          final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
      close_fn = (fun () -> ());
      complete_structured_fn = None;
      list_models_fn = None;
      supports_native_tools_fn = None;
    }
end

let test_invoke_generate_skill_overlay_applied () =
  let capture = Capturing_llm.create () in
  let llm = Capturing_llm.make_service capture in
  let agent = make_agent "overlay-agent" "original" in
  with_invoke_runtime ~llm ~agent (fun rt ->
    let skill =
      match Runtime.make_skill ~id:"override"
        ~description:"applies override"
        ~system_prompt_override:"OVERRIDDEN"
        ~trigger:Auto () with
      | Ok s -> s
      | Error e -> Alcotest.failf "make_skill failed: %s" (error_to_string e)
    in
    (match Runtime.register_skill rt skill with
     | Error e -> Alcotest.failf "register_skill failed: %s" (error_to_string e)
     | Ok _binding -> ());
    (match Runtime.invoke_generate rt ~agent_id:"overlay-agent"
        ~message:"hi" () with
     | Error (e, _) ->
       Alcotest.failf "invoke_generate failed: %s" (error_to_string e)
     | Ok _ -> ());
    Alcotest.(check int) "exactly one LLM call" 1 capture.call_count;
    Alcotest.(check (option string))
      "LLM was called with OVERRIDDEN system prompt"
      (Some "OVERRIDDEN") capture.captured_system)

(* -------------------------------------------------------------------------- *)
(* Test suite                                                                *)
(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "test_generate" [
    ("invoke_generate_basic", [
      Alcotest.test_case "single Stop response" `Quick test_invoke_generate_basic;
    ]);
    ("invoke_generate_auto_continue", [
      Alcotest.test_case "Max_tokens triggers Continue" `Quick
        test_invoke_generate_auto_continue;
    ]);
    ("invoke_generate_total_timeout", [
      Alcotest.test_case "wall-clock cap fires" `Quick
        test_invoke_generate_total_timeout;
    ]);
    ("invoke_generate_event_emission", [
      Alcotest.test_case "events emitted correctly" `Quick
        test_invoke_generate_event_emission;
    ]);
    ("invoke_generate_session_persisted", [
      Alcotest.test_case "conversation saved to SQLite" `Quick
        test_invoke_generate_session_persisted;
    ]);
    ("invoke_generate_skill_overlay_applied", [
      Alcotest.test_case "skill system_prompt_override applied" `Quick
        test_invoke_generate_skill_overlay_applied;
    ]);
  ]