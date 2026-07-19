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

let stop_resp text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let mock_llm_single resp =
  { complete_fn = (fun _ _ _ -> Ok resp);
    stream_fn = (fun _ _ _ _ _ -> Ok { final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None; }

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let agent =
  { id = "qa-agent";
    system_prompt = stable_prompt "test";
    system_prompt_template = None;
    model = dummy_model; tools = []; max_iterations = 10; middleware = [];
    retry_policy = None; context_strategy = None; resource_quota = None;
    max_execution_time = None; tool_timeout = None;
    early_stopping_method = Force;
    on_max_tokens = Some Return_partial; max_continuation_chunks = Some 3;
    context_compression_threshold = None;
    compression_cooldown_messages = None;
    context_window_override = None;
    cache_strategy = No_caching }

let () =
  let llm = mock_llm_single (stop_resp "FINAL_ANSWER") in
  let reg = Tool_registry.create () in
  with_token (fun token ->
    match Engine.run_agent token agent "what is the answer?" llm reg with
    | Result.Ok (resp, conv) ->
      Printf.printf "[QA] resp.text = %s\n" (Option.value resp.text ~default:"(none)");
      Printf.printf "[QA] conv.messages length = %d\n" (List.length conv.messages);
      List.iteri (fun i (m : message) ->
        Printf.printf "[QA] msg[%d]: role=%s text=%S\n" i
          (match m.role with
           | System -> "System" | User -> "User"
           | Assistant -> "Assistant" | Tool -> "Tool")
          (Message.text_of_message m)
      ) conv.messages;
      let last_msg = List.hd (List.rev conv.messages) in
      Printf.printf "[QA] last role = %s, last text = %s\n"
        (match last_msg.role with
         | Assistant -> "Assistant" | _ -> "NON-Assistant!")
        (Message.text_of_message last_msg);
      if last_msg.role = Assistant && Message.text_of_message last_msg = "FINAL_ANSWER" then
        Printf.printf "[QA] PASS: terminal Assistant materialized\n"
      else (
        Printf.printf "[QA] FAIL\n";
        exit 1)
    | Result.Error _ ->
      Printf.printf "[QA] FAIL: unexpected Error\n";
      exit 1)
