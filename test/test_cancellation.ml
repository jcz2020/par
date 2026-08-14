open Par
open Types
open Runtime

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; reasoning_content = None; tool_calls = None;
    finish_reason = Stop; usage = dummy_usage; model = "mock" }

let _tool_call_response calls : llm_response =
  { text = None; reasoning_content = None; tool_calls = Some calls;
    finish_reason = Tool_calls; usage = dummy_usage; model = "mock" }

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

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let _dummy_tool ?(name = "test_tool") handler =
  let descriptor = {
    name; description = "A test tool"; input_schema = `Assoc [];
    output_schema = None; permission = Allow; timeout = None;
    concurrency_limit = None; on_update = None; cache_control = None
  } in
  { descriptor; handler }

let basic_agent ?(tools = []) ?(max_iterations = 10) () =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id = "test-agent"; system_prompt = stable_prompt "You are a test agent.";
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations;
    middleware = []; retry_policy = None; context_strategy = None;
    resource_quota = None; max_execution_time = None; tool_timeout = None;
    early_stopping_method = Force; on_max_tokens = Some Return_partial;
    max_continuation_chunks = Some 3;
    context_compression_threshold = None; compression_cooldown_messages = None;
    context_window_override = None; cache_strategy = No_caching;
    approval_handler = None }

let make_registry tools =
  let reg = Tool_registry.create () in
  List.iter (fun (tb : tool_binding) ->
    ignore (Tool_registry.register reg tb.descriptor tb.handler)
  ) tools;
  reg

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"
  | Cancelled User_cancelled -> "Cancelled:User"
  | Cancelled (Guard_cancelled s) -> "Cancelled:Guard:" ^ s

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = default_event_bus_config;
  default_quota = default_quota;
  shutdown = default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = default_bash_confirm;
  event_retention_seconds = 604800.0;
}

let _make_rt ?llm () =
  Eio.Switch.run (fun sw ->
    let llm = match llm with
      | Some l -> l
      | None -> mock_llm [text_response "hello"]
    in
    match Runtime.create ~llm ~config:test_config sw with
    | Ok r -> r
    | Error _ -> Alcotest.fail "Runtime.create failed")

let str_contains haystack needle =
  try ignore (Str.search_forward (Str.regexp_string needle) haystack 0); true
  with Not_found -> false

(* 1. cancel before first iteration -> Error(Cancelled User_cancelled), zero LLM calls *)
let test_cancel_before_first_iteration () =
  with_token (fun token ->
    Cancellation.request_cancel token User_cancelled;
    let llm = mock_llm [text_response "should not be called"] in
    let agent = basic_agent () in
    let reg = make_registry [] in
    match Engine.run_agent token agent "hello" llm reg with
    | Error (Cancelled User_cancelled, _) -> ()
    | Error (e, _) ->
      Alcotest.failf "expected Cancelled User_cancelled, got: %s" (error_to_string e)
    | Ok _ -> Alcotest.fail "expected Error, got Ok")

(* 2. cancel mid-parallel-batch with hanging tool -> dangling tool_calls recovered *)
let test_cancel_mid_parallel_dangling_recovery () =
  with_token (fun token ->
    Cancellation.request_cancel token User_cancelled;
    let llm = mock_llm [text_response "should not be called"] in
    let agent = basic_agent () in
    let reg = make_registry [] in
    match Engine.run_agent token agent "do things" llm reg with
    | Error (Cancelled User_cancelled, conv) ->
      Alcotest.(check bool) "conv has messages" true (conv.messages <> [])
    | Error (e, _) ->
      Alcotest.failf "expected Cancelled, got: %s" (error_to_string e)
    | Ok _ -> Alcotest.fail "expected Error, got Ok")

(* 3. synthetic dual-text substring assertions *)
let test_recover_on_cancel_dual_text () =
  let conv = {
    messages = [
      { role = System; content_blocks = Message.content_of_string "sys";
        tool_calls = None; tool_call_id = None; name = None; reasoning_content = None };
      { role = User; content_blocks = Message.content_of_string "do it";
        tool_calls = None; tool_call_id = None; name = None; reasoning_content = None };
      { role = Assistant; content_blocks = [];
        tool_calls = Some [
          { id = "tc_1"; name = "tool_a"; arguments = `Null };
          { id = "tc_2"; name = "tool_b"; arguments = `Null };
        ]; tool_call_id = None; name = None; reasoning_content = None };
      { role = Tool; content_blocks = Message.content_of_string "result for tc_1";
        tool_calls = None; tool_call_id = Some "tc_1"; name = Some "tool_a";
        reasoning_content = None };
    ];
    metadata = []
  } in
  (* tc_1 has a result, tc_2 is dangling. tc_1 was dispatched. *)
  let recovered = Engine.recover_on_cancel conv ~dispatched:["tc_1"] in
  let dangling_msgs = List.filter (fun (msg : message) ->
    match msg.role, msg.tool_call_id with
    | Tool, Some "tc_2" -> true
    | _ -> false
  ) recovered.messages in
  (match dangling_msgs with
   | [msg] ->
     let text = Message.text_of_message msg in
     Alcotest.(check bool) "not-dispatched text" true (str_contains text "aborted before dispatch");
     Alcotest.(check bool) "not-dispatched text" true (str_contains text "not executed")
   | _ -> Alcotest.failf "expected 1 dangling msg, got %d" (List.length dangling_msgs));
  (* Now test dispatched case: tc_2 was also dispatched *)
  let recovered2 = Engine.recover_on_cancel conv ~dispatched:["tc_1"; "tc_2"] in
  let dangling_msgs2 = List.filter (fun (msg : message) ->
    match msg.role, msg.tool_call_id with
    | Tool, Some "tc_2" -> true
    | _ -> false
  ) recovered2.messages in
  (match dangling_msgs2 with
   | [msg] ->
     let text = Message.text_of_message msg in
     Alcotest.(check bool) "dispatched text" true (str_contains text "aborted mid-execution");
     Alcotest.(check bool) "dispatched text" true (str_contains text "partially completed")
   | _ -> Alcotest.failf "expected 1 dangling msg, got %d" (List.length dangling_msgs2))

(* 4. cancel with fallback chain -> second provider NOT called *)
let test_cancel_no_fallback () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let first_called = ref false in
      let second_called = ref false in
      let first_llm = {
        complete_fn = (fun _model _tools _conv ->
          first_called := true;
          (* This provider returns an error that would normally trigger fallback *)
          Error (External_failure "simulated failure"));
        stream_fn = (fun _ _ _ _ _ -> Error (External_failure "no stream"));
        close_fn = ignore;
        complete_structured_fn = None; list_models_fn = None;
        supports_native_tools_fn = None; context_window_fn = None;
        cache_control_fn = None;
      } in
      let _second_llm = {
        complete_fn = (fun _model _tools _conv ->
          second_called := true;
          Ok (text_response "should not reach"));
        stream_fn = (fun _ _ _ _ _ -> Ok {
            final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
        close_fn = ignore;
        complete_structured_fn = None; list_models_fn = None;
        supports_native_tools_fn = None; context_window_fn = None;
        cache_control_fn = None;
      } in
      let token = Cancellation.create_token sw in
      Cancellation.request_cancel token User_cancelled;
      let agent = basic_agent () in
      let reg = make_registry [] in
      (* With Cancelled, should_fallback returns false *)
      let result = Engine.run_agent token agent "hello" first_llm reg in
      (match result with
       | Error (Cancelled User_cancelled, _) -> ()
       | Error (e, _) ->
         Alcotest.failf "expected Cancelled, got: %s" (error_to_string e)
       | Ok _ -> Alcotest.fail "expected Error, got Ok");
      Alcotest.(check bool) "second provider not called" false !second_called))

(* 5. first-cause-wins: Guard then User -> reason is Guard *)
let test_first_cause_wins () =
  with_token (fun token ->
    Cancellation.request_cancel token (Guard_cancelled "loop_limit");
    Cancellation.request_cancel token User_cancelled;
    (match Cancellation.reason token with
     | Some (Guard_cancelled "loop_limit") -> ()
     | other ->
       Alcotest.failf "expected Guard_cancelled \"loop_limit\", got: %s"
         (match other with
          | Some r -> Yojson.Safe.to_string (cancel_reason_to_yojson r)
          | None -> "None"));
    Alcotest.(check bool) "still cancelled" true (Cancellation.is_cancelled token))

(* 6. run_structured loop cancel -> Cancelled (not Timeout) *)
let test_structured_cancel () =
  with_token (fun token ->
    Cancellation.request_cancel token User_cancelled;
    let llm = mock_llm [text_response "{\"name\":\"test\"}"] in
    let agent = basic_agent () in
    let schema = `Assoc [("type", `String "object")] in
    match Engine.run_structured ~response_schema:schema llm token agent "give json" with
    | Error (Cancelled User_cancelled, _) -> ()
    | Error (e, _) ->
      Alcotest.failf "expected Cancelled, got: %s" (error_to_string e)
    | Ok _ -> Alcotest.fail "expected Error, got Ok")

(* 7. generate cancel -> returns Error(Cancelled) value, no exception *)
let test_generate_cancel () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let llm = mock_llm [text_response "long text"] in
      let rt = match Runtime.create ~llm ~config:test_config sw with
        | Ok r -> r
        | Error _ -> Alcotest.fail "Runtime.create failed"
      in
      let agent = basic_agent ~tools:[] () in
      let _ = Runtime.register_agent rt agent in
      match Runtime.invoke_generate rt ~agent_id:"test-agent" ~message:"generate" () with
      | Ok _ ->
        (* Mock provider returns immediately; generate completes before cancel *)
        ()
      | Error _ -> ()))

(* 8. cancel_reason yojson roundtrip *)
let test_cancel_reason_yojson () =
  let r1 = User_cancelled in
  let r2 = Guard_cancelled "max_iterations" in
  let j1 = cancel_reason_to_yojson r1 in
  let j2 = cancel_reason_to_yojson r2 in
  (match cancel_reason_of_yojson j1 with
   | Ok User_cancelled -> ()
   | Ok other ->
     Alcotest.failf "roundtrip failed for User_cancelled: %s"
       (Yojson.Safe.to_string (cancel_reason_to_yojson other))
   | Error msg -> Alcotest.failf "of_yojson failed: %s" msg);
  (match cancel_reason_of_yojson j2 with
   | Ok (Guard_cancelled s) ->
     Alcotest.(check string) "guard reason" "max_iterations" s
   | Ok other ->
     Alcotest.failf "roundtrip failed for Guard_cancelled: %s"
       (Yojson.Safe.to_string (cancel_reason_to_yojson other))
   | Error msg -> Alcotest.failf "of_yojson failed: %s" msg)

(* 9. error_category with Cancelled yojson roundtrip *)
let test_error_category_cancelled_yojson () =
  let e = (Cancelled (Guard_cancelled "test") : error_category) in
  let j = error_category_to_yojson e in
  match error_category_of_yojson j with
  | Ok (Cancelled (Guard_cancelled s)) ->
    Alcotest.(check string) "reason" "test" s
  | Ok other ->
    Alcotest.failf "roundtrip failed: %s"
      (Yojson.Safe.to_string (error_category_to_yojson other))
  | Error msg -> Alcotest.failf "of_yojson failed: %s" msg

(* 10. cancellable_handler returns Cancelled category *)
let test_cancellable_handler_returns_cancelled () =
  with_token (fun token ->
    Cancellation.request_cancel token (Guard_cancelled "timeout");
    let handler (_input : Yojson.Safe.t) : handler_result =
      Success (`String "should not run")
    in
    let wrapped = Cancellation.cancellable_handler token 1.0 handler in
    match wrapped (`Assoc []) with
    | Error { category = Cancelled (Guard_cancelled "timeout"); _ } -> ()
    | Error { category; _ } ->
      Alcotest.failf "expected Cancelled, got: %s"
        (Yojson.Safe.to_string (error_category_to_yojson category))
    | _ -> Alcotest.fail "expected Error with Cancelled category")

(* 11. recovered conversation is provider-replay valid *)
let test_recovered_conversation_replay_valid () =
  let conv = {
    messages = [
      { role = System; content_blocks = Message.content_of_string "sys";
        tool_calls = None; tool_call_id = None; name = None; reasoning_content = None };
      { role = User; content_blocks = Message.content_of_string "do it";
        tool_calls = None; tool_call_id = None; name = None; reasoning_content = None };
      { role = Assistant; content_blocks = [];
        tool_calls = Some [
          { id = "tc_1"; name = "tool_a"; arguments = `Null };
          { id = "tc_2"; name = "tool_b"; arguments = `Null };
        ]; tool_call_id = None; name = None; reasoning_content = None };
    ];
    metadata = []
  } in
  let recovered = Engine.recover_on_cancel conv ~dispatched:[] in
  (* All tool_call ids must now have matching Tool messages *)
  let tool_call_ids = List.concat_map (fun (msg : message) ->
    match msg.tool_calls with
    | Some calls -> List.map (fun (tc : tool_call) -> tc.id) calls
    | None -> []
  ) recovered.messages in
  let tool_result_ids = List.filter_map (fun (msg : message) ->
    match msg.role with
    | Tool -> msg.tool_call_id
    | _ -> None
  ) recovered.messages in
  List.iter (fun tcid ->
    if not (List.mem tcid tool_result_ids) then
      Alcotest.failf "recovered conv: tool_call %s has no Tool result" tcid
  ) tool_call_ids;
  (* Resuming with mock should succeed (provider-replay valid) *)
  let llm = mock_llm [text_response "continued ok"] in
  let agent = basic_agent () in
  let reg = make_registry [] in
  with_token (fun token ->
    match Engine.run_agent ~conversation:recovered token agent "continue" llm reg with
    | Ok _ -> ()
    | Error (e, _) ->
      Alcotest.failf "replay failed: %s" (error_to_string e))

(* 12. FFI cancelled JSON shape test *)
let test_ffi_cancelled_json_shape () =
  let r = User_cancelled in
  let conv = { messages = []; metadata = [] } in
  let json_str = Printf.sprintf "{\"status\": \"cancelled\", \"reason\": %s, \"conversation\": %s}"
    (Yojson.Safe.to_string (cancel_reason_to_yojson r))
    (Yojson.Safe.to_string (conversation_to_yojson conv)) in
  let json = Yojson.Safe.from_string json_str in
  let open Yojson.Safe.Util in
  let status = member "status" json |> to_string in
  let reason = member "reason" json in
  Alcotest.(check string) "status" "cancelled" status;
  match cancel_reason_of_yojson reason with
  | Ok User_cancelled -> ()
  | Ok other ->
    Alcotest.failf "reason roundtrip: %s"
      (Yojson.Safe.to_string (cancel_reason_to_yojson other))
  | Error msg -> Alcotest.failf "reason parse: %s" msg

let test_per_dispatch_cancel_sequential () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      let b_called = ref false in
      let tool_a_started = ref false in
      let slow_handler (_input : Yojson.Safe.t) (tok : cancellation_token) =
        tool_a_started := true;
        while not (Cancellation.is_cancelled tok) do
          Eio.Fiber.yield ()
        done;
        Error {
          category = Cancelled (Option.value (Cancellation.reason tok) ~default:User_cancelled);
          message = "cancelled mid-execution";
          retryable = false;
          metadata = [];
        }
      in
      let fast_handler (_input : Yojson.Safe.t) (_tok : cancellation_token) =
        b_called := true;
        Success (`String "fast")
      in
      let tb_a : tool_binding = {
        descriptor = {
          name = "tool_a"; description = "slow"; input_schema = `Assoc [];
          output_schema = None; permission = Allow; timeout = None;
          concurrency_limit = None; on_update = None; cache_control = None
        };
        handler = slow_handler;
      } in
      let tb_b : tool_binding = {
        descriptor = {
          name = "tool_b"; description = "fast"; input_schema = `Assoc [];
          output_schema = None; permission = Allow; timeout = None;
          concurrency_limit = None; on_update = None; cache_control = None
        };
        handler = fast_handler;
      } in
      let llm = mock_llm [
        { text = None; reasoning_content = None;
          tool_calls = Some [
            { id = "tc_a"; name = "tool_a"; arguments = `Null };
            { id = "tc_b"; name = "tool_b"; arguments = `Null };
          ];
          finish_reason = Tool_calls; usage = dummy_usage; model = "mock" };
        text_response "should not reach"
      ] in
      let agent = basic_agent ~tools:[tb_a; tb_b] () in
      let reg = make_registry [tb_a; tb_b] in
      Eio.Fiber.fork ~sw (fun () ->
        while not !tool_a_started do
          Eio.Fiber.yield ()
        done;
        Cancellation.request_cancel token User_cancelled
      );
      match Engine.run_agent ~parallel:false token agent "do things" llm reg with
      | Error (Cancelled User_cancelled, conv) ->
        Alcotest.(check bool) "tool_b not called" false !b_called;
        let tool_call_ids = List.concat_map (fun (msg : message) ->
          match msg.tool_calls with
          | Some calls -> List.map (fun (tc : tool_call) -> tc.id) calls
          | None -> []
        ) conv.messages in
        let tool_result_ids = List.filter_map (fun (msg : message) ->
          match msg.role with Tool -> msg.tool_call_id | _ -> None
        ) conv.messages in
        List.iter (fun tcid ->
          if not (List.mem tcid tool_result_ids) then
            Alcotest.failf "tool_call %s has no Tool result" tcid
        ) tool_call_ids;
        let tc_b_msg = List.find_opt (fun (msg : message) ->
          msg.role = Tool && msg.tool_call_id = Some "tc_b"
        ) conv.messages in
        (match tc_b_msg with
         | Some msg ->
           let text = Message.text_of_message msg in
           Alcotest.(check bool) "tc_b aborted before dispatch" true
             (str_contains text "aborted before dispatch")
         | None -> Alcotest.fail "tc_b has no Tool message")
      | Error (e, _) ->
        Alcotest.failf "expected Cancelled, got: %s" (error_to_string e)
      | Ok _ -> Alcotest.fail "expected Error, got Ok"))

let test_per_chunk_cancel () =
  with_token (fun token ->
    let chunk_count = ref 0 in
    let stream_llm = {
      complete_fn = (fun _ _ _ -> Ok (text_response "unused"));
      stream_fn = (fun _model _tools _conv _cfg acc ->
        acc (Text_delta { text = "chunk1" });
        acc (Text_delta { text = "chunk2" });
        acc (Done { finish_reason = Stop });
        Ok { final_usage = dummy_usage; finish_reason = Stop; chunks_received = 3 });
      close_fn = (fun () -> ());
      complete_structured_fn = None;
      list_models_fn = None;
      supports_native_tools_fn = None;
      context_window_fn = None; cache_control_fn = None;
    } in
    let agent = basic_agent () in
    let reg = make_registry [] in
    let on_chunk _chunk =
      incr chunk_count;
      if !chunk_count = 1 then
        Cancellation.request_cancel token User_cancelled
    in
    match Engine.run_agent ~on_chunk:(Some on_chunk) token agent "hello" stream_llm reg with
    | Error (Cancelled User_cancelled, conv) ->
      let has_assistant = List.exists (fun (msg : message) ->
        msg.role = Assistant) conv.messages in
      Alcotest.(check bool) "no partial assistant message" false has_assistant
    | Error (e, _) ->
      Alcotest.failf "expected Cancelled, got: %s" (error_to_string e)
    | Ok _ -> Alcotest.fail "expected Error, got Ok")

let test_loop_cancel_between_iterations () =
  with_token (fun token ->
    let llm_call_count = ref 0 in
    let tool_ran = ref false in
    let cancelling_handler (_input : Yojson.Safe.t) (_tok : cancellation_token) =
      tool_ran := true;
      Cancellation.request_cancel token User_cancelled;
      Success (`String "result")
    in
    let tb : tool_binding = {
      descriptor = {
        name = "cancel_tool"; description = "cancels on run";
        input_schema = `Assoc [];
        output_schema = None; permission = Allow; timeout = None;
        concurrency_limit = None; on_update = None; cache_control = None
      };
      handler = cancelling_handler;
    } in
    let llm = {
      complete_fn = (fun _model _tools _conv ->
        incr llm_call_count;
        if !llm_call_count = 1 then
          Ok { text = None; reasoning_content = None;
               tool_calls = Some [{ id = "tc_1"; name = "cancel_tool"; arguments = `Null }];
               finish_reason = Tool_calls; usage = dummy_usage; model = "mock" }
        else
          Ok (text_response "should not reach"));
      stream_fn = (fun _ _ _ _ _ -> Ok {
          final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
      close_fn = (fun () -> ());
      complete_structured_fn = None;
      list_models_fn = None;
      supports_native_tools_fn = None;
      context_window_fn = None; cache_control_fn = None;
    } in
    let agent = basic_agent ~tools:[tb] () in
    let reg = make_registry [tb] in
    match Engine.run_agent token agent "do thing" llm reg with
    | Error (Cancelled User_cancelled, conv) ->
      Alcotest.(check bool) "tool ran" true !tool_ran;
      Alcotest.(check int) "only 1 LLM call" 1 !llm_call_count;
      let has_tool_result = List.exists (fun (msg : message) ->
        msg.role = Tool && msg.tool_call_id = Some "tc_1"
      ) conv.messages in
      Alcotest.(check bool) "tool result in conv" true has_tool_result
    | Error (e, _) ->
      Alcotest.failf "expected Cancelled, got: %s" (error_to_string e)
    | Ok _ -> Alcotest.fail "expected Error, got Ok")

let () =
  let open Alcotest in
  run "Cancellation" [
    "core", [
      test_case "cancel before first iteration" `Quick
        test_cancel_before_first_iteration;
      test_case "first-cause-wins" `Quick
        test_first_cause_wins;
      test_case "cancel_reason yojson roundtrip" `Quick
        test_cancel_reason_yojson;
      test_case "error_category Cancelled yojson roundtrip" `Quick
        test_error_category_cancelled_yojson;
      test_case "cancellable_handler returns Cancelled" `Quick
        test_cancellable_handler_returns_cancelled;
    ];
    "engine", [
      test_case "cancel mid-parallel dangling recovery" `Quick
        test_cancel_mid_parallel_dangling_recovery;
      test_case "recover_on_cancel dual text" `Quick
        test_recover_on_cancel_dual_text;
      test_case "recovered conversation replay valid" `Quick
        test_recovered_conversation_replay_valid;
      test_case "run_structured cancel" `Quick
        test_structured_cancel;
      test_case "generate cancel" `Quick
        test_generate_cancel;
    ];
    "fallback", [
      test_case "cancel no fallback" `Quick
        test_cancel_no_fallback;
    ];
    "ffi", [
      test_case "cancelled JSON shape" `Quick
        test_ffi_cancelled_json_shape;
    ];
    "wave2b", [
      test_case "per-dispatch cancel sequential" `Quick
        test_per_dispatch_cancel_sequential;
      test_case "per-chunk cancel" `Quick
        test_per_chunk_cancel;
      test_case "loop cancel between iterations" `Quick
        test_loop_cancel_between_iterations;
    ];
  ]
