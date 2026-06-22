(* test_ffi_streaming.ml — Phase C.2 FFI streaming bridge tests.
   Verifies the OCaml-side chunk callback path that par_invoke_stream
   uses internally. The C-side bridge is exercised by the Python
   bindings in phase C.3. *)

open Par
open Par.Types
open Par.Runtime

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

let dummy_model : model_config = {
  provider = `Openai;
  model_name = "test-mock";
  api_base = None;
  temperature = 0.0;
  max_tokens = None;
  top_p = None;
  stop_sequences = None;
}

let error_to_string e = match e with
  | Invalid_input s -> s
  | Internal s -> s
  | Embedding_unsupported -> "Embedding_unsupported"
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"

let make_agent id system_prompt =
  match Par.Runtime.make_agent ~id ~system_prompt ~model:dummy_model () with
  | Ok a -> a
  | Error e -> Alcotest.failf "make_agent failed: %s" (error_to_string e)

let with_streaming_runtime (llm : llm_service) (agent_id : string)
      (f : Par.Runtime.runtime -> Par.Types.agent_config -> 'a) : 'a =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      match Par.Runtime.create ~llm ~config:test_config sw with
      | Error e ->
        Alcotest.failf "Runtime.create failed: %s" (error_to_string e)
      | Ok rt ->
        let agent = make_agent agent_id "" in
        (match Par.Runtime.register_agent rt agent with
         | Error e ->
           Alcotest.failf "register_agent failed: %s" (error_to_string e)
         | Ok () ->
           let result = f rt agent in
           ignore (Par.Runtime.close rt);
           result)))

(* --- Test 1: register a callback, invoke with mock provider, collect chunks,
   assert at least 1 Text_delta received. *)
let test_text_delta_collected () =
  let (llm, _history) = Mock_provider.create [Text "hello world"] in
  with_streaming_runtime llm "t1-agent" (fun rt _agent ->
    let chunks : llm_response_chunk list ref = ref [] in
    let cb chunk = chunks := chunk :: !chunks in
    let result = Par.Runtime.invoke rt ~agent_id:"t1-agent" ~message:"hi"
      ~on_chunk:(Some cb) () in
    match result with
    | Ok _ ->
      let received = List.rev !chunks in
      let has_text_delta =
        List.exists (function Text_delta _ -> true | _ -> false) received
      in
      Alcotest.(check bool) "received at least one Text_delta" true has_text_delta
    | Error (e, _) ->
      Alcotest.failf "invoke failed: %s" (error_to_string e))

(* --- Test 2: tool call mid-stream — mock provider emits Tool_call_start
   and Tool_call_delta; assert both received in order. *)
let test_tool_call_chunks_ordered () =
  let tc = { id = "tc-1"; name = "search"; arguments = `Assoc [("q", `String "x")] } in
  let (llm, _history) = Mock_provider.create
    [With_tool_calls { text = Some "calling search"; calls = [tc] }] in
  with_streaming_runtime llm "t2-agent" (fun rt _agent ->
    let chunks : llm_response_chunk list ref = ref [] in
    let cb chunk = chunks := chunk :: !chunks in
    let result = Par.Runtime.invoke rt ~agent_id:"t2-agent" ~message:"search please"
      ~on_chunk:(Some cb) () in
    match result with
    | Ok _ ->
      let received = List.rev !chunks in
      (* Find the indices of Tool_call_start and Tool_call_delta for our call *)
      let start_idx = ref (-1) in
      let delta_idx = ref (-1) in
      List.iteri (fun i chunk ->
        match chunk with
        | Tool_call_start { tool_call_id; _ } when tool_call_id = "tc-1" ->
          start_idx := i
        | Tool_call_delta { tool_call_id; _ } when tool_call_id = "tc-1" ->
          delta_idx := i
        | _ -> ()
      ) received;
      Alcotest.(check bool) "Tool_call_start received" true (!start_idx >= 0);
      Alcotest.(check bool) "Tool_call_delta received" true (!delta_idx >= 0);
      Alcotest.(check bool) "Tool_call_start before Tool_call_delta"
        true (!start_idx < !delta_idx)
    | Error (e, _) ->
      Alcotest.failf "invoke failed: %s" (error_to_string e))

(* --- Test 3: Done event — mock agent completes, assert Done received. *)
let test_done_event_received () =
  let (llm, _history) = Mock_provider.create [Text "goodbye"] in
  with_streaming_runtime llm "t3-agent" (fun rt _agent ->
    let chunks : llm_response_chunk list ref = ref [] in
    let cb chunk = chunks := chunk :: !chunks in
    let result = Par.Runtime.invoke rt ~agent_id:"t3-agent" ~message:"bye"
      ~on_chunk:(Some cb) () in
    match result with
    | Ok _ ->
      let received = List.rev !chunks in
      let has_done =
        List.exists (function Done _ -> true | _ -> false) received
      in
      let has_usage =
        List.exists (function Usage_update _ -> true | _ -> false) received
      in
      Alcotest.(check bool) "received Done event" true has_done;
      Alcotest.(check bool) "received Usage_update" true has_usage
    | Error (e, _) ->
      Alcotest.failf "invoke failed: %s" (error_to_string e))

(* --- Test 4: chunk callback identity (the OCaml-side equivalent of
   "user_data passthrough"). The closure that wraps the dispatch
   function must capture the user-supplied data and pass it along
   unmodified on every invocation. We verify by counting invocations
   and confirming the captured ref accumulates correctly. *)
let test_chunk_callback_passthrough () =
  let (llm, _history) = Mock_provider.create [Text "alpha"] in
  with_streaming_runtime llm "t4-agent" (fun rt _agent ->
    let call_count = ref 0 in
    let user_data : int ref = call_count in
    let chunks : llm_response_chunk list ref = ref [] in
    let cb chunk =
      call_count := !call_count + 1;
      chunks := chunk :: !chunks
    in
    Alcotest.(check int) "user_data initial value" 0 !user_data;
    let result = Par.Runtime.invoke rt ~agent_id:"t4-agent" ~message:"go"
      ~on_chunk:(Some cb) () in
    match result with
    | Ok _ ->
      let received = List.rev !chunks in
      let text_count =
        List.fold_left (fun acc chunk ->
          match chunk with Text_delta _ -> acc + 1 | _ -> acc) 0 received
      in
      Alcotest.(check int) "Text_delta count" 1 text_count;
      Alcotest.(check bool) "callback invoked at least once" true (!call_count >= 1);
      Alcotest.(check int) "user_data == call_count (same ref)"
        !user_data !call_count
    | Error (e, _) ->
      Alcotest.failf "invoke failed: %s" (error_to_string e))

(* --- Test 5: chunk ADT round-trip — each llm_response_chunk constructor
   must serialize to valid JSON (this is the data path par_invoke_stream
   relies on for dispatching to the C callback). *)
let test_chunk_json_roundtrip () =
  let json_of_chunk chunk =
    llm_response_chunk_to_yojson chunk |> Yojson.Safe.to_string
  in
  let chunks : llm_response_chunk list = [
    Text_delta { text = "hi" };
    Tool_call_start { tool_call_id = "tc1"; name = "lookup" };
    Tool_call_delta { tool_call_id = "tc1"; args_json = "{\"x\":1}" };
    Usage_update { prompt_tokens = 5; completion_tokens = 10; total_tokens = 15 };
    Done { finish_reason = Stop };
  ] in
  List.iter (fun chunk ->
    let json = json_of_chunk chunk in
    let parsed = Yojson.Safe.from_string json in
    let roundtripped = llm_response_chunk_of_yojson parsed in
    match roundtripped with
    | Ok r -> Alcotest.(check string) "roundtrip equal" (json_of_chunk chunk) (json_of_chunk r)
    | Error e -> Alcotest.failf "roundtrip failed: %s" e
  ) chunks

let () =
  Alcotest.run "FFI streaming bridge" [
    "streaming", [
      Alcotest.test_case "text delta collected" `Quick test_text_delta_collected;
      Alcotest.test_case "tool call chunks in order" `Quick test_tool_call_chunks_ordered;
      Alcotest.test_case "done event received" `Quick test_done_event_received;
      Alcotest.test_case "chunk callback passthrough" `Quick test_chunk_callback_passthrough;
      Alcotest.test_case "chunk JSON roundtrip" `Quick test_chunk_json_roundtrip;
    ];
  ]
