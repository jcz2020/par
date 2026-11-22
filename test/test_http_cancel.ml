(* test/test_http_cancel.ml — PAR-9km / GitHub #44.

   A server accepts the connection and never sends a byte. With the owned-socket
   transport, [Cancellation.request_cancel] shuts the socket down and the
   provider call returns promptly instead of waiting for the next chunk. *)

open Par
open Types

let model : model_config =
  { provider = `Openai; model_name = "gpt-4o"; api_base = None;
    temperature = 0.0; max_tokens = Some 8; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None; context_window = None }

let conversation : conversation =
  { messages = [{ role = User;
                  content_blocks = Message.content_of_string "hi";
                  tool_calls = None; tool_call_id = None; name = None }];
    metadata = [] }

let stream_config : stream_config =
  { chunk_timeout = 30.0; total_timeout = None; buffer_size = 4096 }

let with_hanging_server env f =
  let net = Eio.Stdenv.net env in
  Eio.Switch.run (fun sw ->
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
    let server = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:5 addr in
    let port = match Eio.Net.listening_addr server with
      | `Tcp (_, p) -> p | _ -> failwith "expected TCP"
    in
    let accepted = ref [] in
    Eio.Fiber.fork ~sw (fun () ->
      try
        let flow, _ = Eio.Net.accept ~sw server in
        accepted := flow :: !accepted
      with _ -> ());
    Fun.protect ~finally:(fun () ->
      List.iter (fun flow -> try Eio.Flow.close flow with _ -> ()) !accepted)
      (fun () -> f sw net port))

let with_provider env _sw port f =
  let url = Printf.sprintf "http://127.0.0.1:%d/v1" port in
  match Openai_provider.create (Types.Openai {
    api_key = "sk-test"; base_url = Some url; organization = None;
    embedding_model = None; prompt_cache_key = None }) with
  | Error e -> Alcotest.failf "provider: %s" (string_of_error_category e)
  | Ok provider ->
    Openai_provider.set_network provider
      (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t);
    f (Openai_provider.to_llm_service provider)

let cancel_after env sw seconds token =
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Time.sleep (Eio.Stdenv.clock env) seconds;
    Cancellation.request_cancel token User_cancelled)

let run_case env sw net port ~stream =
  with_provider env sw port (fun llm ->
    let token = Cancellation.create_token sw in
    cancel_after env sw 0.2 token;
    let ctx = Invoke_context.create
        ~cancellation_token:token
        ~session_id:"cancel-fixture"
        () in
    let started = Unix.gettimeofday () in
    Invoke_context.with_context ctx (fun () ->
      if stream then
        ignore (llm.stream_fn model [] conversation stream_config (fun _ -> ()))
      else
        ignore (llm.complete_fn model [] conversation));
    ignore net;
    let elapsed = Unix.gettimeofday () -. started in
    Alcotest.(check bool) "returns within 2s" true (elapsed < 2.0);
    Alcotest.(check bool) "token cancelled" true (Cancellation.is_cancelled token))

let test_complete_cancels () =
  Eio_main.run (fun env ->
    with_hanging_server env (fun sw net port ->
      Http_client.set_clock (Eio.Stdenv.clock env);
      Http_client.set_request_timeout 60.0;
      run_case env sw net port ~stream:false))

let runtime_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  mcp_sampling = Disabled;
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = false;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
  max_tool_schema_tokens = None;
  max_tool_result_chars = 100_000;
}

let test_runtime_invoke_reports_cancelled () =
  Eio_main.run (fun env ->
    with_hanging_server env (fun sw _net port ->
      Http_client.set_clock (Eio.Stdenv.clock env);
      Http_client.set_request_timeout 60.0;
      with_provider env sw port (fun llm ->
        match Runtime.create ~llm ~config:runtime_config sw with
        | Error e -> Alcotest.failf "create: %s" (string_of_error_category e)
        | Ok rt ->
          Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () ->
            let agent =
              match Runtime.make_agent ~id:"silent"
                      ~system_prompt:(stable_prompt "silent fixture")
                      ~model () with
              | Ok a -> a
              | Error e -> Alcotest.failf "make_agent: %s"
                             (string_of_error_category e)
            in
            (match Runtime.register_agent rt agent with
             | Ok () -> ()
             | Error e -> Alcotest.failf "register_agent: %s"
                            (string_of_error_category e));
            let token = Cancellation.create_token sw in
            cancel_after env sw 0.2 token;
            let started = Unix.gettimeofday () in
            let result = Runtime.invoke rt ~agent_id:"silent" ~message:"hi"
                ~cancellation_token:token () in
            let elapsed = Unix.gettimeofday () -. started in
            Alcotest.(check bool) "returns within 2s" true (elapsed < 2.0);
            (match result with
             | Error (Cancelled _, _) -> ()
             | Error (e, _) ->
               Alcotest.failf "expected Cancelled, got %s"
                 (string_of_error_category e)
             | Ok _ -> Alcotest.fail "expected Cancelled, got Ok"))))
  )

let test_stream_cancels () =
  Eio_main.run (fun env ->
    with_hanging_server env (fun sw net port ->
      Http_client.set_clock (Eio.Stdenv.clock env);
      Http_client.set_request_timeout 60.0;
      run_case env sw net port ~stream:true))

let () =
  Alcotest.run "http_cancel" [
    ("cancel", [
      Alcotest.test_case "non-streaming silent provider" `Quick
        test_complete_cancels;
      Alcotest.test_case "streaming silent provider" `Quick
        test_stream_cancels;
      Alcotest.test_case "Runtime.invoke reports Cancelled" `Quick
        test_runtime_invoke_reports_cancelled;
    ]);
  ]
