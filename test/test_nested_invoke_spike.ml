(* ==========================================================================
   INVESTIGATION SPIKE: Nested Engine.run_agent Re-entrancy (v0.11.0 Track B)

   FINDINGS — empirically verified (7/7 tests green):

   Q1 (Invoke_context LEAKAGE — CONFIRMED):
   Child sees PARENT's invoke_context via get_current (). Observed:
     session_id         → parent's UUID (e.g. "f738d8eb-6615-4911-960a-...")
     metrics_accumulator → parent's counters (llm_requests_total=1 at child entry)
     steering_queue      → same physical object (==) as parent's
     followup_queue      → same physical object (==) as parent's
     skills_snapshot     → parent's (empty in test, would leak if non-empty)
     system_prompt_appendix → parent's (None in test, would leak if set)
   All 7 fields leak because the child runs in the parent's fiber —
   Eio.Fiber.with_binding propagates to same-fiber and forked-fiber calls.

   Q2 (RE-ENTRANCY — CONFIRMED SAFE):
   Synchronous Engine.run_agent inside tool handler:
     NO deadlock (no locks, same fiber)
     NO exception (child completes normally)
     NO metrics double-count (Engine never touches Metrics; parent sees 1 LLM call)
   Isolation demo: fresh Invoke_context with with_context gives child its own
   session_id ("child-session-99"), confirming the recommended fix works.
   WARNING: shared task_semaphore can deadlock at max_concurrent_tasks=1;
   pass ~quota:None for child.

   Q3 (CANCELLATION — CONFIRMED):
   Cancellation.create_token(parent.switch) creates SEPARATE record.
   request_cancel(parent_token) does NOT propagate to child_token.
   Child runs to completion; parent returns Error(Cancelled User_cancelled).
   With parent_token passed to child: loop-top check returns Cancelled
   gracefully (no Eio.Cancel exception).

   RECOMMENDATION for v0.11 Track B: "Explicit Context Fork" —
   Invoke_context.with_context fresh_ctx before Engine.run_agent child.
   Pass parent token for cancel-propagation or fresh token for independence.
   Pass ~quota:None to avoid semaphore deadlock.
   ========================================================================== *)

open Par
open Types

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"
  | Cancelled r ->
    (match r with
     | User_cancelled -> "User_cancelled"
     | Guard_cancelled s -> "Guard_cancelled:" ^ s)

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let stop_response text : llm_response =
  { text = Some text; reasoning_content = None; tool_calls = None;
    finish_reason = Stop; usage = dummy_usage; model = "mock" }

let tool_call_response calls : llm_response =
  { text = None; reasoning_content = None; tool_calls = Some calls;
    finish_reason = Tool_calls; usage = dummy_usage; model = "mock" }

let mock_llm responses =
  let counter = ref 0 in
  let next () =
    let idx = !counter in
    incr counter;
    match List.nth_opt responses idx with
    | Some resp -> resp
    | None -> stop_response "default"
  in
  { complete_fn = (fun _model _tools _conv -> Ok (next ()));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None }

let snapshot_get key snap =
  match List.assoc_opt key snap with
  | Some n -> n
  | None -> 0

let make_agent ?(tools = []) id sys_prompt =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id;
    system_prompt = stable_prompt sys_prompt;
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations = 10;
    middleware = []; retry_policy = None; context_strategy = None;
    resource_quota = None; max_execution_time = None; tool_timeout = None;
    early_stopping_method = Force;
    on_max_tokens = Some Return_partial; max_continuation_chunks = Some 3;
    context_compression_threshold = None;
    compression_cooldown_messages = None;
    context_window_override = None;
    cache_strategy = No_caching; approval_handler = None }

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = false;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
    max_tool_schema_tokens = None;
  }

let run_test f = Eio_main.run (fun _env -> Eio.Switch.run (fun sw -> f sw))

let make_tool_binding ~name ~desc handler =
  ({ descriptor = { name; description = desc;
                    input_schema = `Assoc []; output_schema = None;
                    permission = Allow; timeout = None;
                    concurrency_limit = None; on_update = None;
                    cache_control = None };
     handler } : tool_binding)

(* ── Q1: Invoke_context leakage =========================================== *)

let q1_suite =
  ("Q1_invoke_context_leakage", [

    Alcotest.test_case "child observes PARENT invoke_context (leakage)" `Quick
      (fun () ->
        let child_observed_ctx = ref None in
        let parent_observed_ctx = ref None in
        let child_llm = mock_llm [ stop_response "child-done" ] in
        let parent_llm = mock_llm [
          tool_call_response [
            { id = "tc-child"; name = "child_tool"; arguments = `Assoc [] }
          ];
          stop_response "parent-done"
        ] in
        let child_handler (_input : Yojson.Safe.t) (token : cancellation_token) =
          parent_observed_ctx := Invoke_context.get_current ();
          let child_token = Cancellation.create_token token.switch in
          let child_reg = Tool_registry.create () in
          match Engine.run_agent child_token
                  (make_agent "child" "You are the child.")
                  "hi child" child_llm child_reg with
          | Ok (_resp, _conv) ->
            child_observed_ctx := Invoke_context.get_current ();
            Success (`String "child done")
          | Error (e, _) ->
            Error { category = e; message = "child failed"; retryable = false;
                    metadata = [] }
        in
        let tb = make_tool_binding ~name:"child_tool" ~desc:"Runs child agent"
          child_handler in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm:parent_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_tool rt
              ~name:"child_tool" ~description:"Runs child agent"
              ~input_schema:(`Assoc []) ~handler:child_handler ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[tb] "parent" "You are the parent."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~update_current:false
                    ~system_prompt_appendix:"spike-appendix"
                    ~skills:["alpha"; "beta"]
                    () with
            | Error (e, _) ->
              Alcotest.failf "parent invoke failed: %s" (error_to_string e)
            | Ok _ ->
              match !child_observed_ctx, !parent_observed_ctx with
              | None, _ -> Alcotest.fail "child never observed invoke_context"
              | _, None -> Alcotest.fail "parent context not captured"
              | Some child_ctx, Some parent_ctx ->
                Alcotest.(check string) "session_id leaked"
                  parent_ctx.session_id child_ctx.session_id;
                Alcotest.(check bool) "metrics_accumulator same object"
                  true (child_ctx.metrics_accumulator == parent_ctx.metrics_accumulator);
                Alcotest.(check (option string)) "appendix leaked"
                  (Some "spike-appendix") child_ctx.system_prompt_appendix;
                Alcotest.(check (list string)) "skills leaked"
                  ["alpha"; "beta"] child_ctx.user_activated_skills_snapshot;
                Alcotest.(check bool) "steering_queue same object"
                  true (child_ctx.steering_queue == parent_ctx.steering_queue);
                Alcotest.(check bool) "followup_queue same object"
                  true (child_ctx.followup_queue == parent_ctx.followup_queue);
                Printf.printf "[Q1] session=%s appendix=%s skills=[%s]\n"
                  child_ctx.session_id
                  (match child_ctx.system_prompt_appendix with
                   | Some s -> s | None -> "None")
                  (String.concat "; " child_ctx.user_activated_skills_snapshot)));
  ])

(* ── Q2: Re-entrancy ====================================================== *)

let q2_suite =
  ("Q2_reentrancy", [

    Alcotest.test_case "synchronous re-entrant Engine.run_agent — no deadlock" `Quick
      (fun () ->
        let child_llm = mock_llm [ stop_response "child-answer" ] in
        let parent_llm = mock_llm [
          tool_call_response [
            { id = "tc-r"; name = "reentrant_tool"; arguments = `Assoc [] }
          ];
          stop_response "parent-answer"
        ] in
        let handler (_input : Yojson.Safe.t) (token : cancellation_token) =
          let child_reg = Tool_registry.create () in
          match Engine.run_agent token
                  (make_agent "child" "You are the child.")
                  "child msg" child_llm child_reg with
          | Ok _ -> Success (`String "reentrant done")
          | Error (e, _) ->
            Error { category = e; message = "reentrant failed";
                    retryable = false; metadata = [] }
        in
        let tb = make_tool_binding ~name:"reentrant_tool"
          ~desc:"Re-entrant child call" handler in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm:parent_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_tool rt
              ~name:"reentrant_tool" ~description:"Re-entrant child call"
              ~input_schema:(`Assoc []) ~handler:handler ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[tb] "parent" "You are the parent."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~update_current:false () with
            | Error (e, _) ->
              Alcotest.failf "Q2 invoke failed: %s" (error_to_string e)
            | Ok resp ->
              Alcotest.(check (option string)) "parent response"
                (Some "parent-answer") resp.response.text;
              let snap = Runtime.metrics_snapshot rt in
              Alcotest.(check int) "runtime llm_requests=1"
                1 (snapshot_get "llm_requests_total" snap);
              Alcotest.(check int) "runtime errors=0"
                0 (snapshot_get "task_failed_total" snap)));

    Alcotest.test_case "re-entrant with fresh Invoke_context (isolated child)" `Quick
      (fun () ->
        let child_session_id = ref "" in
        let child_llm = mock_llm [ stop_response "child-answer" ] in
        let parent_llm = mock_llm [
          tool_call_response [
            { id = "tc-iso"; name = "isolated_tool"; arguments = `Assoc [] }
          ];
          stop_response "parent-answer"
        ] in
        let isolated_handler (_input : Yojson.Safe.t) (token : cancellation_token) =
          let child_ctx = Invoke_context.create
            ~session_id:"child-session-99"
            ~metrics:(Metrics.empty ())
            ()
          in
          Invoke_context.with_context child_ctx (fun () ->
            let child_reg = Tool_registry.create () in
            match Engine.run_agent token
                    (make_agent "child" "You are the isolated child.")
                    "child msg" child_llm child_reg with
            | Ok _ ->
              (match Invoke_context.get_current () with
               | Some ctx -> child_session_id := ctx.session_id
               | None -> child_session_id := "<none>");
              Success (`String "isolated child done")
            | Error (e, _) ->
              Error { category = e; message = "child failed";
                      retryable = false; metadata = [] })
        in
        run_test (fun sw ->
          match Runtime.create ~config:test_config ~llm:parent_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_tool rt
              ~name:"isolated_tool" ~description:"Isolated child call"
              ~input_schema:(`Assoc []) ~handler:isolated_handler ());
            let parent_agent = make_agent
              ~tools:[{
                descriptor = { name = "isolated_tool"; description = "Isolated child call";
                               input_schema = `Assoc []; output_schema = None;
                               permission = Allow; timeout = None;
                               concurrency_limit = None; on_update = None;
                               cache_control = None };
                handler = isolated_handler
              }]
              "parent" "You are the parent."
            in
            ignore (Runtime.register_agent rt parent_agent);
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~update_current:false () with
            | Error (e, _) ->
              Alcotest.failf "invoke failed: %s" (error_to_string e)
            | Ok _resp ->
              Alcotest.(check string)
                "child session_id is its own (not parent's)"
                "child-session-99" !child_session_id;
              Printf.printf "[Q2-iso] isolated child saw session_id=%S\n"
                !child_session_id;
              let snap = Runtime.metrics_snapshot rt in
              Alcotest.(check int)
                "runtime metrics: 1 LLM call"
                1 (snapshot_get "llm_requests_total" snap)));
  ])

(* ── Q3: Cancellation ===================================================== *)

let q3_suite =
  ("Q3_cancellation", [

    Alcotest.test_case "request_cancel parent does NOT affect fresh child_token" `Quick
      (fun () ->
        run_test (fun sw ->
          let parent_token = Cancellation.create_token sw in
          let child_token = Cancellation.create_token sw in
          Cancellation.request_cancel parent_token User_cancelled;
          Alcotest.(check bool) "child NOT cancelled" false
            (Cancellation.is_cancelled child_token);
          Alcotest.(check bool) "parent IS cancelled" true
            (Cancellation.is_cancelled parent_token);
          Alcotest.(check bool) "child reason is None" true
            (Cancellation.reason child_token = None)));

    Alcotest.test_case "child with fresh token runs despite parent cancelled" `Quick
      (fun () ->
        let child_llm = mock_llm [ stop_response "child survived" ] in
        run_test (fun sw ->
          let parent_token = Cancellation.create_token sw in
          Cancellation.request_cancel parent_token User_cancelled;
          let child_token = Cancellation.create_token sw in
          match Engine.run_agent child_token
                  (make_agent "child" "You are child.")
                  "go" child_llm (Tool_registry.create ()) with
          | Ok (resp, _) ->
            Alcotest.(check (option string)) "child completed"
              (Some "child survived") resp.text
          | Error (e, _) ->
            Alcotest.fail ("child should succeed: " ^ error_to_string e)));

    Alcotest.test_case "child with parent's cancelled token returns Cancelled gracefully" `Quick
      (fun () ->
        let child_llm = mock_llm [ stop_response "should not reach" ] in
        run_test (fun sw ->
          let token = Cancellation.create_token sw in
          Cancellation.request_cancel token (Guard_cancelled "parent says stop");
          match Engine.run_agent token
                  (make_agent "child" "You are child.")
                  "go" child_llm (Tool_registry.create ()) with
          | Ok _ -> Alcotest.fail "should have been cancelled"
          | Error (Cancelled (Guard_cancelled s), _) ->
            Alcotest.(check string) "cancel reason" "parent says stop" s
          | Error (e, _) ->
            Alcotest.fail ("expected Cancelled: " ^ error_to_string e)));

    Alcotest.test_case "full integration: parent cancel propagates gracefully" `Quick
      (fun () ->
        let child_cancelled = ref false in
        let parent_cancelled = ref false in
        let child_llm = mock_llm [ stop_response "child-finished" ] in
        let parent_llm = mock_llm [
          tool_call_response [
            { id = "tc-cancel"; name = "cancel_tool"; arguments = `Assoc [] }
          ];
          stop_response "should-not-reach"
        ] in
        let cancel_done_p, cancel_done_r = Eio.Promise.create () in
        let handler (_input : Yojson.Safe.t) (token : cancellation_token) =
          let child_token = Cancellation.create_token token.switch in
          Eio.Promise.resolve cancel_done_r ();
          Eio.Fiber.yield ();
          Eio.Fiber.yield ();
          child_cancelled := Cancellation.is_cancelled child_token;
          parent_cancelled := Cancellation.is_cancelled token;
          let child_reg = Tool_registry.create () in
          match Engine.run_agent child_token
                  (make_agent "child" "You are the child.")
                  "child msg" child_llm child_reg with
          | Ok _ -> Success (`String "child-completed")
          | Error (e, _) ->
            Error { category = e; message = "child error";
                    retryable = false; metadata = [] }
        in
        let tb = make_tool_binding ~name:"cancel_tool"
          ~desc:"Cancel test" handler in
        run_test (fun sw ->
          let parent_token = Cancellation.create_token sw in
          Eio.Fiber.fork ~sw (fun () ->
            Eio.Promise.await cancel_done_p;
            Cancellation.request_cancel parent_token User_cancelled);
          match Runtime.create ~config:test_config ~llm:parent_llm sw with
          | Error e -> Alcotest.failf "runtime create: %s" (error_to_string e)
          | Ok rt ->
            ignore (Runtime.register_tool rt
              ~name:"cancel_tool" ~description:"Cancel test"
              ~input_schema:(`Assoc []) ~handler:handler ());
            ignore (Runtime.register_agent rt
              (make_agent ~tools:[tb] "parent" "You are the parent."));
            match Runtime.invoke rt ~agent_id:"parent" ~message:"go"
                    ~cancellation_token:parent_token ~update_current:false () with
            | Ok _ -> Alcotest.fail "parent should have been cancelled"
            | Error (err_cat, _) ->
              Alcotest.(check bool) "child token NOT cancelled"
                false !child_cancelled;
              Alcotest.(check bool) "parent token IS cancelled"
                true !parent_cancelled;
              let is_cancelled = match err_cat with
                | Cancelled _ -> true | _ -> false in
              Alcotest.(check bool) "parent got Cancelled error" true is_cancelled;
              (match err_cat with
               | Cancelled User_cancelled -> ()
               | other ->
                 Alcotest.failf "expected Cancelled User_cancelled, got %s"
                   (error_to_string other));
              Printf.printf "[Q3] child_cancelled=%b parent_cancelled=%b\n"
                !child_cancelled !parent_cancelled));
  ])

let () =
  Alcotest.run "test_nested_invoke_spike" [
    q1_suite;
    q2_suite;
    q3_suite;
  ]
