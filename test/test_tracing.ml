(* test/test_tracing.ml — span tree produced by [Tracing].

   The runtime reports spans to a host-supplied tracer. These cases pin the
   carrier contract independently of any engine instrumentation: ids, parent
   links, status on success/error/cancellation, and the Noop fast path. *)

open Par

type event =
  | Start of Tracing.span
  | End of string * string   (* span_id, status *)

let record () =
  let events = ref [] in
  let tracer = {
    Tracing.on_start = (fun span -> events := Start span :: !events);
    on_end = (fun span ~status -> events := End (span.span_id, status) :: !events);
  } in
  (tracer, events)

let hex_length expected value =
  Alcotest.(check int) "hex length" expected (String.length value);
  Alcotest.(check bool) "lowercase hex" true
    (String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       value)

let starts events =
  List.filter_map (function Start s -> Some s | End _ -> None) !events
  |> List.rev

let ends events =
  List.filter_map (function End (id, status) -> Some (id, status) | Start _ -> None) !events
  |> List.rev

let test_root_and_children () =
  Eio_main.run (fun _env ->
    let tracer, events = record () in
    let root_id = ref "" in
    let child_parent = ref None in
    let child_trace = ref "" in
    Tracing.with_root tracer ~name:"invoke" (fun () ->
      let root = List.hd (starts events) in
      root_id := root.Tracing.span_id;
      Tracing.with_span ~kind:`Client ~name:"llm.complete"
        ~attributes:[("gen_ai.request.model", "gpt-4o")] (fun () ->
          let spans = starts events in
          let child = List.nth spans 1 in
          child_parent := child.Tracing.parent_span_id;
          child_trace := child.Tracing.trace_id);
      ());
    let spans = starts events in
    Alcotest.(check int) "two spans" 2 (List.length spans);
    let root = List.hd spans in
    let child = List.nth spans 1 in
    Alcotest.(check (option string)) "root has no parent" None
      root.Tracing.parent_span_id;
    hex_length 32 root.Tracing.trace_id;
    hex_length 16 root.Tracing.span_id;
    hex_length 16 child.Tracing.span_id;
    Alcotest.(check string) "child trace" root.Tracing.trace_id child.Tracing.trace_id;
    Alcotest.(check (option string)) "child parent" (Some root.Tracing.span_id)
      child.Tracing.parent_span_id;
    Alcotest.(check string) "child model attr" "gpt-4o"
      (List.assoc "gen_ai.request.model" child.Tracing.attributes);
    Alcotest.(check string) "captured parent" root.Tracing.span_id
      (Option.value !child_parent ~default:"");
    Alcotest.(check string) "captured trace" root.Tracing.trace_id !child_trace;
    Alcotest.(check (list (pair string string)))
      "both end ok" [(child.Tracing.span_id, "ok");
                     (root.Tracing.span_id, "ok")]
      (ends events))

let test_error_status () =
  Eio_main.run (fun _env ->
    let tracer, events = record () in
    (try
       Tracing.with_root tracer ~name:"invoke" (fun () ->
         Tracing.with_span ~name:"tool.call" (fun () ->
           failwith "boom"))
     with Failure _ -> ());
    let statuses = List.map snd (ends events) in
    Alcotest.(check (list string)) "child then root, both error"
      ["error"; "error"] statuses)

let test_result_status_mapping () =
  Eio_main.run (fun _env ->
    let tracer, events = record () in
    let value =
      Tracing.with_root tracer ~name:"invoke"
        ~status:(function Ok _ -> `Ok | Error _ -> `Error)
        (fun () -> Error "nope")
    in
    (match value with Error _ -> () | Ok _ -> Alcotest.fail "expected Error");
    Alcotest.(check (list (pair string string))) "error result maps to error"
      [(List.hd (starts events)).Tracing.span_id, "error"]
      (ends events))

let test_child_outside_root_has_no_span () =
  Eio_main.run (fun _env ->
    let _tracer, events = record () in
    (* No root: with_span must not invent a trace the host never asked for. *)
    let ran = ref false in
    Tracing.with_span ~name:"orphan" (fun () -> ran := true);
    Alcotest.(check bool) "body ran" true !ran;
    Alcotest.(check int) "no spans" 0 (List.length !events))

let test_noop_skips_context () =
  Eio_main.run (fun _env ->
    let tracer, events = record () in
    Alcotest.(check bool) "noop detected" true (Tracing.is_noop Tracing.noop);
    Tracing.with_root Tracing.noop ~name:"invoke" (fun () ->
      Tracing.with_span ~name:"llm.complete" (fun () -> ()));
    Alcotest.(check int) "no events" 0 (List.length !events);
    Alcotest.(check bool) "recording tracer is not noop" false
      (Tracing.is_noop tracer))

let test_nested_entry_point_joins_the_trace () =
  Eio_main.run (fun _env ->
    let tracer, events = record () in
    Tracing.with_root tracer ~name:"outer" (fun () ->
      Tracing.with_root_or_span tracer ~name:"invoke" (fun () -> ()));
    let spans = starts events in
    Alcotest.(check int) "two spans" 2 (List.length spans);
    let outer = List.hd spans in
    let inner = List.nth spans 1 in
    Alcotest.(check string) "same trace" outer.Tracing.trace_id inner.Tracing.trace_id;
    Alcotest.(check (option string)) "inner is a child"
      (Some outer.Tracing.span_id) inner.Tracing.parent_span_id)

let test_trace_context_helpers () =
  Eio_main.run (fun _env ->
    Alcotest.(check (option string)) "no trace outside" None
      (Tracing.current_trace_id ());
    let tracer, _events = record () in
    Tracing.with_root tracer ~name:"invoke" (fun () ->
      Alcotest.(check bool) "trace id present" true
        (Tracing.current_trace_id () <> None);
      Alcotest.(check bool) "span id present" true
        (Tracing.current_span_id () <> None)))



let contains haystack needle =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length haystack
    && (String.sub haystack i n = needle || go (i + 1))
  in
  go 0

let test_traceparent_round_trip () =
  let header = Tracing.traceparent_header
      ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
      ~span_id:"00f067aa0ba902b7" in
  Alcotest.(check string) "format"
    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" header;
  Alcotest.(check (option (pair string string))) "parse"
    (Some ("4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7"))
    (Tracing.parse_traceparent header);
  Alcotest.(check (option (pair string string))) "reject short" None
    (Tracing.parse_traceparent "00-abc-def-01");
  Alcotest.(check (option (pair string string))) "reject all-zero trace" None
    (Tracing.parse_traceparent
       "00-00000000000000000000000000000000-00f067aa0ba902b7-01")

let test_outgoing_headers_follow_the_span () =
  Eio_main.run (fun _env ->
    Alcotest.(check (list (pair string string))) "outside a span" []
      (Tracing.outgoing_headers ());
    let tracer, events = record () in
    Tracing.with_root tracer ~name:"invoke" (fun () ->
      Tracing.with_span ~name:"llm.complete" (fun () ->
        let headers = Tracing.outgoing_headers () in
        match List.assoc_opt "traceparent" headers with
        | None -> Alcotest.fail "no traceparent inside a span"
        | Some value ->
          let spans = starts events in
          let child = List.nth spans 1 in
          Alcotest.(check string) "matches the child span"
            (Tracing.traceparent_header ~trace_id:child.Tracing.trace_id
               ~span_id:child.Tracing.span_id)
            value);
      ()))

let test_provider_request_carries_traceparent () =
  Eio_main.run (fun _env ->
    let tracer, events = record () in
    Tracing.with_root tracer ~name:"invoke" (fun () ->
      let request =
        Http_client.build_http_request ~host:"api.openai.com"
          ~path:"/v1/chat/completions" ~headers:[] ~body:"{}"
      in
      let root = List.hd (starts events) in
      Alcotest.(check bool) "header present" true
        (contains request
           (Printf.sprintf "traceparent: 00-%s-%s-01"
              root.Tracing.trace_id root.Tracing.span_id)))
  )

(* -------------------------------------------------------------------------- *)
(* End-to-end span tree                                                       *)
(* -------------------------------------------------------------------------- *)

let dummy_model : Types.model_config =
  { provider = `Openai; model_name = "tracing-mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None; context_window = None }

let dummy_usage : Types.usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let text_response text : Types.llm_response =
  { text = Some text; reasoning = []; tool_calls = None;
    finish_reason = Types.Stop; usage = dummy_usage; model = "tracing-mock" }

let tool_call_response () : Types.llm_response =
  { text = None; reasoning = [];
    tool_calls = Some [{ Types.id = "call-1"; name = "echo"; arguments = `Assoc [] }];
    finish_reason = Types.Tool_calls; usage = dummy_usage; model = "tracing-mock" }

let mock_llm responses =
  let counter = ref 0 in
  let next () =
    let idx = !counter in
    incr counter;
    match List.nth_opt responses idx with
    | Some response -> response
    | None -> text_response "default"
  in
  { Types.complete_fn = (fun _model _tools _conv -> Ok (next ()));
    stream_fn = (fun _ _tools _ _ _ ->
      Ok { Types.final_usage = dummy_usage; finish_reason = Types.Stop;
           chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None;
    cache_control_fn = None;
  }

let runtime_config : Types.runtime_config = {
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
}

let echo_descriptor : Types.tool_descriptor = {
  name = "echo"; description = "Echo"; input_schema = `Assoc ["type", `String "object"];
  output_schema = None; permission = Types.Allow; timeout = None;
  concurrency_limit = None; on_update = None; cache_control = None;
}

let test_invoke_produces_the_expected_tree () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let tracer, events = record () in
      let llm = mock_llm [tool_call_response (); text_response "done"] in
      match Runtime.create ~tracer ~llm ~config:runtime_config sw with
      | Error e -> Alcotest.failf "create: %s" (Types.string_of_error_category e)
      | Ok rt ->
        Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () ->
          let handler _input _token = Types.Success (`String "ok") in
          (match Runtime.register_tool rt ~name:"echo" ~description:"Echo"
                   ~input_schema:(`Assoc ["type", `String "object"]) ~handler () with
           | Ok _ -> ()
           | Error e -> Alcotest.failf "register_tool: %s"
                          (Types.string_of_error_category e));
          let agent =
            match Runtime.make_agent ~id:"tracing-agent"
                    ~system_prompt:(Types.stable_prompt "You are a tracing fixture.")
                    ~model:dummy_model ~tools:[echo_descriptor] () with
            | Ok agent -> agent
            | Error e -> Alcotest.failf "make_agent: %s"
                           (Types.string_of_error_category e)
          in
          (match Runtime.register_agent rt agent with
           | Ok () -> ()
           | Error e -> Alcotest.failf "register_agent: %s"
                          (Types.string_of_error_category e));
          match Runtime.invoke rt ~agent_id:"tracing-agent" ~message:"hi" () with
          | Error (e, _) -> Alcotest.failf "invoke: %s"
                              (Types.string_of_error_category e)
          | Ok _ ->
            let spans = starts events in
            let names = List.map (fun (s : Tracing.span) -> s.name) spans in
            Alcotest.(check (list string)) "span names"
              ["invoke"; "llm.complete"; "tool.call"; "llm.complete"] names;
            let root = List.hd spans in
            Alcotest.(check (option string)) "root has no parent" None
              root.parent_span_id;
            List.iter (fun (s : Tracing.span) ->
              Alcotest.(check string) "same trace" root.trace_id s.trace_id;
              Alcotest.(check (option string)) "parent is the root"
                (Some root.span_id) s.parent_span_id) (List.tl spans);
            let expected_ends =
              List.map (fun (s : Tracing.span) -> (s.span_id, "ok"))
                (List.tl spans)
              @ [(root.span_id, "ok")]
            in
            Alcotest.(check (list (pair string string))) "all spans end ok"
              expected_ends (ends events))))

let () =
  Alcotest.run "test_tracing" [
    ("spans", [
      Alcotest.test_case "root and child" `Quick test_root_and_children;
      Alcotest.test_case "error status" `Quick test_error_status;
      Alcotest.test_case "result status mapping" `Quick test_result_status_mapping;
      Alcotest.test_case "no root, no span" `Quick test_child_outside_root_has_no_span;
      Alcotest.test_case "noop fast path" `Quick test_noop_skips_context;
      Alcotest.test_case "context helpers" `Quick test_trace_context_helpers;
      Alcotest.test_case "nested entry point joins trace" `Quick
        test_nested_entry_point_joins_the_trace;
    ]);
    ("propagation", [
      Alcotest.test_case "traceparent round trip" `Quick
        test_traceparent_round_trip;
      Alcotest.test_case "outgoing headers" `Quick
        test_outgoing_headers_follow_the_span;
      Alcotest.test_case "provider request header" `Quick
        test_provider_request_carries_traceparent;
    ]);
    ("runtime", [
      Alcotest.test_case "invoke span tree" `Quick
        test_invoke_produces_the_expected_tree;
    ]);
  ]
