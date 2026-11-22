(* test/test_trace_propagation.ml — W2-S3 wire test.

   A local HTTP provider records the request headers. The outbound
   [traceparent] must carry the id of the [llm.complete] span, not a random or
   stale trace. *)

open Par
open Types

let model : model_config =
  { provider = `Openai; model_name = "trace-test"; api_base = None;
    temperature = 0.0; max_tokens = Some 8; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None; context_window = None }

let config : runtime_config = {
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

let record () =
  let events = ref [] in
  let tracer = {
    Tracing.on_start = (fun span -> events := `Start span :: !events);
    on_end = (fun span ~status -> events := `End (span, status) :: !events);
  } in
  (tracer, events)

let test_traceparent_carries_the_llm_span () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let recorded = ref None in
      let net = Eio.Stdenv.net env in
      let server = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:5
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
      let port = match Eio.Net.listening_addr server with
        | `Tcp (_, p) -> p | _ -> failwith "port"
      in
      Eio.Fiber.fork ~sw (fun () ->
        let flow, _ = Eio.Net.accept ~sw server in
        let buf = Eio.Buf_read.of_flow flow ~max_size:(1024 * 1024) in
        let rec headers acc =
          let line = Eio.Buf_read.line buf in
          let line =
            let n = String.length line in
            if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line
          in
          if line = "" then List.rev acc
          else
            match String.index_opt line ':' with
            | Some i ->
              headers ((String.lowercase_ascii (String.trim (String.sub line 0 i)),
                        String.trim (String.sub line (i + 1) (String.length line - i - 1)))
                       :: acc)
            | None -> headers acc
        in
        let hdrs = headers [] in
        recorded := List.assoc_opt "traceparent" hdrs;
        let body = Yojson.Safe.to_string (`Assoc [
          "model", `String "trace-test";
          "choices", `List [`Assoc [
            "message", `Assoc ["role", `String "assistant"; "content", `String "ok"];
            "finish_reason", `String "stop";
          ]];
          "usage", `Assoc ["prompt_tokens", `Int 1; "completion_tokens", `Int 1;
                           "total_tokens", `Int 2];
        ]) in
        Eio.Flow.copy_string
          (Printf.sprintf
             "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
             (String.length body) body)
          flow;
        Eio.Flow.close flow);
      let provider = match Openai_provider.create (Types.Openai {
        api_key = "sk-test";
        base_url = Some (Printf.sprintf "http://127.0.0.1:%d/v1" port);
        organization = None; embedding_model = None; prompt_cache_key = None;
      }) with
      | Ok p -> p
      | Error e -> Alcotest.failf "provider: %s" (string_of_error_category e)
      in
      Openai_provider.set_network provider
        (net :> [ `Generic ] Eio.Net.ty Eio.Net.t);
      let llm = Openai_provider.to_llm_service provider in
      let tracer, events = record () in
      match Runtime.create ~tracer ~llm ~config sw with
      | Error e -> Alcotest.failf "create: %s" (string_of_error_category e)
      | Ok rt ->
        Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () ->
          let agent = match Runtime.make_agent ~id:"trace-agent"
              ~system_prompt:(stable_prompt "trace fixture")
              ~model () with
            | Ok a -> a
            | Error e -> Alcotest.failf "make_agent: %s"
                           (string_of_error_category e)
          in
          (match Runtime.register_agent rt agent with
           | Ok () -> ()
           | Error e -> Alcotest.failf "register_agent: %s"
                          (string_of_error_category e));
          (match Runtime.invoke rt ~agent_id:"trace-agent" ~message:"hi" () with
           | Ok _ -> ()
           | Error (e, _) -> Alcotest.failf "invoke: %s"
                               (string_of_error_category e));
          let spans = List.filter_map (function
            | `Start span -> Some span | `End _ -> None) !events in
          let root = List.find (fun (s : Tracing.span) -> s.name = "invoke") spans in
          let llm_span =
            List.find (fun (s : Tracing.span) -> s.name = "llm.complete") spans
          in
          match !recorded with
          | None -> Alcotest.fail "provider request had no traceparent"
          | Some header ->
            (match Tracing.parse_traceparent header with
             | None -> Alcotest.failf "invalid traceparent: %s" header
             | Some (trace_id, parent_id) ->
               Alcotest.(check string) "trace id" root.trace_id trace_id;
               Alcotest.(check string) "llm span id" llm_span.span_id parent_id)))
  )

let () =
  Alcotest.run "trace_propagation" [
    ("http", [
      Alcotest.test_case "traceparent matches llm.complete" `Quick
        test_traceparent_carries_the_llm_span;
    ]);
  ]
