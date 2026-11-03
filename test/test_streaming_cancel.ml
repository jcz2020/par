open Par
open Types

let default_stream_config : stream_config =
  { chunk_timeout = 30.0; total_timeout = None; buffer_size = 4096 }

let openai_model : model_config =
  { provider = `Openai; model_name = "gpt-4o-mini"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None }

let anthropic_model : model_config =
  { provider = `Anthropic; model_name = "claude-3-5-sonnet-latest"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None }

let user_conv : conversation =
  { messages = [
      { role = User; content_blocks = Message.content_of_string "hi";
        tool_calls = None; tool_call_id = None; name = None };
    ]; metadata = [] }

let with_mock_http_server env ~response f =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  let server_sock = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:5 addr in
  let port =
    match Eio.Net.listening_addr server_sock with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected TCP listening address"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Net.accept_fork server_sock ~sw ~on_error:(fun _ -> ())
        (fun flow _addr ->
          try
            let buf = Eio.Buf_read.of_flow flow ~initial_size:4096 ~max_size:65536 in
            let _request_line = Eio.Buf_read.line buf in
            let rec drain_headers () =
              let line = Eio.Buf_read.line buf in
              if String.trim line <> "" then drain_headers ()
            in
            drain_headers ();
            Eio.Flow.copy (Eio.Flow.string_source response) flow
          with _ -> ())
    done);
  f (Printf.sprintf "http://127.0.0.1:%d/" port)

let http_response body =
  Printf.sprintf
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
    (String.length body) body

let openai_sse_body =
  "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\n\
   data: {\"choices\":[{\"delta\":{\"content\":\"two\"}}]}\n\n\
   data: [DONE]\n\n"

let anthropic_sse_body =
  "event: content_block_delta\n\
   data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"one\"}}\n\n\
   event: content_block_delta\n\
   data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"two\"}}\n\n\
   event: message_stop\n\
   data: {\"type\":\"message_stop\"}\n\n"

let test_openai_callback_exception_propagates () =
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run @@ fun env ->
  let response = http_response openai_sse_body in
  with_mock_http_server env ~response (fun url ->
    let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
    match Openai_provider.create
            (Openai { api_key = "sk-test"; base_url = Some url;
                      organization = None; embedding_model = None;
                      prompt_cache_key = None }) with
    | Error e -> Alcotest.failf "create: %s" (Types.string_of_error_category e)
    | Ok t ->
      Openai_provider.set_network t net;
      let chunks = ref 0 in
      let callback _ =
        incr chunks;
        if !chunks = 1 then raise Cancellation.Stream_cancelled_by_token
      in
      let outcome =
        try
          ignore (Openai_provider.stream t openai_model [] user_conv
                    default_stream_config callback);
          `Returned
        with exn -> `Raised exn
      in
      (match outcome with
       | `Raised Cancellation.Stream_cancelled_by_token ->
         Alcotest.(check int) "stopped after the first chunk" 1 !chunks
       | `Raised exn ->
         Alcotest.failf "expected Stream_cancelled_by_token, got %s"
           (Printexc.to_string exn)
       | `Returned ->
         Alcotest.failf "expected Stream_cancelled_by_token, stream returned (chunks=%d)"
           !chunks))

let test_anthropic_callback_exception_propagates () =
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run @@ fun env ->
  let response = http_response anthropic_sse_body in
  with_mock_http_server env ~response (fun url ->
    let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
    match Anthropic_provider.create
            (Anthropic { api_key = "sk-ant-test"; base_url = Some url }) with
    | Error e -> Alcotest.failf "create: %s" (Types.string_of_error_category e)
    | Ok t ->
      Anthropic_provider.set_network t net;
      let chunks = ref 0 in
      let callback _ =
        incr chunks;
        if !chunks = 1 then raise Cancellation.Stream_cancelled_by_token
      in
      let outcome =
        try
          ignore (Anthropic_provider.stream t anthropic_model [] user_conv
                    default_stream_config callback);
          `Returned
        with exn -> `Raised exn
      in
      (match outcome with
       | `Raised Cancellation.Stream_cancelled_by_token ->
         Alcotest.(check int) "stopped after the first chunk" 1 !chunks
       | `Raised exn ->
         Alcotest.failf "expected Stream_cancelled_by_token, got %s"
           (Printexc.to_string exn)
       | `Returned ->
         Alcotest.failf "expected Stream_cancelled_by_token, stream returned (chunks=%d)"
           !chunks))

let test_engine_maps_callback_cancel_to_cancelled () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let token = Cancellation.create_token sw in
  let llm : llm_service =
    { complete_fn = (fun _ _ _ -> failwith "complete_fn should not be called");
      stream_fn = (fun _ _ _ _ _ -> raise Cancellation.Stream_cancelled_by_token);
      close_fn = (fun () -> ());
      complete_structured_fn = None;
      list_models_fn = None;
      supports_native_tools_fn = None;
      context_window_fn = None; cache_control_fn = None }
  in
  let agent : agent_config =
    { id = "cancel-test"; system_prompt = stable_prompt "test";
      system_prompt_template = None; model = openai_model; tools = [];
      max_iterations = 5; middleware = []; retry_policy = None;
      context_strategy = None; resource_quota = None; max_execution_time = None;
      tool_timeout = None; early_stopping_method = Force;
      on_max_tokens = None; max_continuation_chunks = None;
      context_compression_threshold = None; compression_cooldown_messages = None;
      context_window_override = None; cache_strategy = No_caching;
      approval_handler = None }
  in
  let reg = Tool_registry.create () in
  match Engine.run_agent ~on_chunk:(Some (fun _ -> ())) token agent "hi" llm reg with
  | Error (Cancelled _, _) -> ()
  | Error (e, _) -> Alcotest.failf "expected Cancelled, got %s"
      (Types.string_of_error_category e)
  | Ok _ -> Alcotest.fail "expected Error, got Ok"

let () =
  Alcotest.run "streaming_cancel" [
    "streaming_cancel", [
      Alcotest.test_case "openai_callback_exception_propagates" `Quick
        test_openai_callback_exception_propagates;
      Alcotest.test_case "anthropic_callback_exception_propagates" `Quick
        test_anthropic_callback_exception_propagates;
      Alcotest.test_case "engine_maps_callback_cancel_to_cancelled" `Quick
        test_engine_maps_callback_cancel_to_cancelled;
    ]
  ]
