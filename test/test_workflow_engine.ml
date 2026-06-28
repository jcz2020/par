(* Workflow engine test suite — exercises the step-level execution and
   the Runtime-mediated workflow lifecycle (submit/approve/resume). *)

open Par
open Types

(* -------------------------------------------------------------------------- *)
(* Shared fixtures                                                          *)
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
  }

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let with_switch f =
  Eio_main.run (fun _env ->
    Eio.Switch.run f)

let dummy_tool ?(name = "test_tool") handler =
  let descriptor = { name; description = "A test tool"; input_schema = `Assoc []; output_schema = None;
    permission = Allow; timeout = None; concurrency_limit = None; on_update = None } in
  { descriptor; handler }

let basic_agent ?(tools = []) () =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id = "test-agent"; system_prompt = "You are a test agent.";
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations = 10;
    middleware = []; retry_policy = None;
    context_strategy = None; resource_quota = None; max_execution_time = None; tool_timeout = None; early_stopping_method = Force; on_max_tokens = Some Return_partial; max_continuation_chunks = Some 3 }

let make_registry tools =
  let reg = Tool_registry.create () in
  List.iter (fun (tb : tool_binding) ->
    ignore (Tool_registry.register reg tb.descriptor tb.handler)
  ) tools;
  reg

let make_ctx ?(variables = []) ?(failure_policy = Fail_fast)
             ?(parallel_limit = 4) ?(on_step_complete = None)
             ?(workflow_run_id = None) ?(workflow_resolver = (fun _ -> None))
             ?(agent_resolver = (fun _ -> None))
             ?(tool_resolver = (fun _ -> None))
             ~token ~llm ~registry () =
  { Workflow_engine.variables = variables;
    token;
    agent_resolver;
    tool_resolver;
    llm;
    registry;
    parallel_limit;
    failure_policy;
    workflow_resolver;
    on_step_complete;
    workflow_run_id }

let ok_or_fail msg = function
  | Ok v -> v
  | Error e -> Alcotest.fail (msg ^ ": " ^ error_to_string e)

(* -------------------------------------------------------------------------- *)
(* Sequential — left-to-right execution, Fail_fast, Continue_on_failure     *)
(* -------------------------------------------------------------------------- *)

let test_sequential_two_steps_execute_in_order () =
  let t1 = dummy_tool ~name:"tool_a" (fun _ _ -> Success (`String "a-out")) in
  let t2 = dummy_tool ~name:"tool_b" (fun _ _ -> Success (`String "b-out")) in
  let agent = basic_agent ~tools:[t1; t2] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t1; t2] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun n -> if n = "tool_a" then Some t1.descriptor
                               else if n = "tool_b" then Some t2.descriptor
                               else None)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Sequential [
      Tool_call { tool_name = "tool_a"; input = `Assoc [] };
      Tool_call { tool_name = "tool_b"; input = `Assoc [] };
    ] in
    match Workflow_engine.execute_step ctx step with
    | Ok (`List [a; b]) ->
      Alcotest.(check string) "first result" "\"a-out\"" (Yojson.Safe.to_string a);
      Alcotest.(check string) "second result" "\"b-out\"" (Yojson.Safe.to_string b)
    | Ok other -> Alcotest.failf "expected List [a; b], got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "unexpected error: %s" (error_to_string e))

let test_sequential_first_failure_stops_subsequent () =
  let failing = dummy_tool ~name:"fail_tool"
    (fun _ _ -> Error { category = Internal "boom"; message = "boom";
                        retryable = false; metadata = [] }) in
  let t2 = dummy_tool ~name:"ok_tool" (fun _ _ -> Success (`String "ok")) in
  let agent = basic_agent ~tools:[failing; t2] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [failing; t2] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun n -> if n = "fail_tool" then Some failing.descriptor
                               else Some t2.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Sequential [
      Tool_call { tool_name = "fail_tool"; input = `Assoc [] };
      Tool_call { tool_name = "ok_tool"; input = `Assoc [] };
    ] in
    match Workflow_engine.execute_step ctx step with
    | Ok json -> Alcotest.failf "expected Error from first step, got %s"
                   (Yojson.Safe.to_string json)
    | Error (Internal msg) ->
      Alcotest.(check string) "error message" "boom" msg
    | Error e -> Alcotest.failf "expected Internal, got: %s" (error_to_string e))

let test_sequential_empty_workflow_immediate_success () =
  let tool = dummy_tool (fun _ _ -> Success (`String "x")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [tool] in
    let ctx = make_ctx ~tool_resolver:(fun _ -> Some tool.descriptor)
               ~token ~llm ~registry:reg () in
    match Workflow_engine.execute_step ctx (Sequential []) with
    | Ok (`List []) -> ()
    | Ok other -> Alcotest.failf "expected empty list, got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "unexpected error: %s" (error_to_string e))

let test_sequential_continue_on_failure_keeps_going () =
  let failing = dummy_tool ~name:"fail_tool"
    (fun _ _ -> Error { category = Internal "nope"; message = "nope";
                        retryable = false; metadata = [] }) in
  let t2 = dummy_tool ~name:"ok_tool" (fun _ _ -> Success (`String "saved")) in
  let agent = basic_agent ~tools:[failing; t2] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [failing; t2] in
    let ctx = make_ctx
      ~failure_policy:Continue_on_failure
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun n -> if n = "fail_tool" then Some failing.descriptor
                               else Some t2.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Sequential [
      Tool_call { tool_name = "fail_tool"; input = `Assoc [] };
      Tool_call { tool_name = "ok_tool"; input = `Assoc [] };
    ] in
    match Workflow_engine.execute_step ctx step with
    | Ok (`List [b]) ->
      Alcotest.(check string) "continued step only" "\"saved\""
        (Yojson.Safe.to_string b)
    | Ok other -> Alcotest.failf "expected List [saved], got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok (Continue_on_failure): %s"
                   (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Parallel — Eio fibers, semaphore-limited concurrency                     *)
(* -------------------------------------------------------------------------- *)

let test_parallel_two_steps_both_complete () =
  let t1 = dummy_tool ~name:"p1" (fun _ _ -> Success (`String "p1-out")) in
  let t2 = dummy_tool ~name:"p2" (fun _ _ -> Success (`String "p2-out")) in
  let agent = basic_agent ~tools:[t1; t2] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t1; t2] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun n -> if n = "p1" then Some t1.descriptor
                               else Some t2.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Parallel [
      Tool_call { tool_name = "p1"; input = `Assoc [] };
      Tool_call { tool_name = "p2"; input = `Assoc [] };
    ] in
    match Workflow_engine.execute_step ctx step with
    | Ok (`List results) ->
      Alcotest.(check int) "two results" 2 (List.length results);
      let strs = List.map Yojson.Safe.to_string results |> List.sort String.compare in
      Alcotest.(check (list string)) "outputs" ["\"p1-out\""; "\"p2-out\""] strs
    | Ok other -> Alcotest.failf "expected List, got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "unexpected error: %s" (error_to_string e))

let test_parallel_one_failure_preserves_other_results () =
  let ok = dummy_tool ~name:"ok" (fun _ _ -> Success (`String "ok-out")) in
  let bad = dummy_tool ~name:"bad"
    (fun _ _ -> Error { category = Internal "x"; message = "x";
                        retryable = false; metadata = [] }) in
  let agent = basic_agent ~tools:[ok; bad] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [ok; bad] in
    let ctx = make_ctx
      ~failure_policy:Continue_on_failure
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun n -> if n = "ok" then Some ok.descriptor
                               else Some bad.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Parallel [
      Tool_call { tool_name = "ok"; input = `Assoc [] };
      Tool_call { tool_name = "bad"; input = `Assoc [] };
    ] in
    match Workflow_engine.execute_step ctx step with
    | Ok (`List [r]) ->
      Alcotest.(check string) "surviving result" "\"ok-out\""
        (Yojson.Safe.to_string r)
    | Ok other -> Alcotest.failf "expected single surviving result, got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok (Continue_on_failure): %s"
                   (error_to_string e))

let test_parallel_all_failures_aggregate_error () =
  let bad1 = dummy_tool ~name:"b1"
    (fun _ _ -> Error { category = External_failure "fail1";
                        message = "fail1"; retryable = false; metadata = [] }) in
  let bad2 = dummy_tool ~name:"b2"
    (fun _ _ -> Error { category = Internal "fail2";
                        message = "fail2"; retryable = false; metadata = [] }) in
  let agent = basic_agent ~tools:[bad1; bad2] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [bad1; bad2] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun n -> if n = "b1" then Some bad1.descriptor
                               else Some bad2.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Parallel [
      Tool_call { tool_name = "b1"; input = `Assoc [] };
      Tool_call { tool_name = "b2"; input = `Assoc [] };
    ] in
    match Workflow_engine.execute_step ctx step with
    | Ok _ -> Alcotest.fail "expected aggregate error from all failures"
    | Error _ -> ())

let test_parallel_empty_returns_empty_list () =
  let tool = dummy_tool (fun _ _ -> Success (`String "x")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [tool] in
    let ctx = make_ctx ~tool_resolver:(fun _ -> Some tool.descriptor)
               ~token ~llm ~registry:reg () in
    match Workflow_engine.execute_step ctx (Parallel []) with
    | Ok (`List []) -> ()
    | Ok other -> Alcotest.failf "expected empty list, got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "unexpected error: %s" (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Conditional — true/false branch, missing else, nested                    *)
(* -------------------------------------------------------------------------- *)

let test_conditional_true_branch_executes_then () =
  let t = dummy_tool (fun _ _ -> Success (`String "then-result")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("x", `Int 10)]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Conditional {
      condition = Greater_than (Variable "x", Literal (`Int 5));
      then_step = Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      else_step = Some (Tool_call { tool_name = "test_tool"; input = `String "else" });
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok json ->
      Alcotest.(check string) "then branch" "\"then-result\""
        (Yojson.Safe.to_string json)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_conditional_false_branch_executes_else () =
  let t = dummy_tool (fun input _ ->
        match input with
        | `String "else" -> Success (`String "else-result")
        | _ -> Success (`String "then-result")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("x", `Int 1)]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Conditional {
      condition = Greater_than (Variable "x", Literal (`Int 5));
      then_step = Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      else_step = Some (Tool_call { tool_name = "test_tool"; input = `String "else" });
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok json ->
      Alcotest.(check string) "else branch" "\"else-result\""
        (Yojson.Safe.to_string json)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_conditional_false_no_else_returns_null () =
  let t = dummy_tool (fun _ _ -> Success (`String "ignored")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("flag", `Bool false)]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Conditional {
      condition = Variable "flag";
      then_step = Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      else_step = None;
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok `Null -> ()
    | Ok other -> Alcotest.failf "expected Null, got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok Null: %s" (error_to_string e))

let test_conditional_nested_evaluates_inner () =
  let t = dummy_tool (fun input _ ->
        Success (`String ("branch-" ^ Yojson.Safe.to_string input))) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("outer", `Bool true); ("inner", `Bool false)]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Conditional {
      condition = Variable "outer";
      then_step = Conditional {
        condition = Variable "inner";
        then_step = Tool_call { tool_name = "test_tool"; input = `String "inner-true" };
        else_step = Some (Tool_call { tool_name = "test_tool"; input = `String "inner-false" });
      };
      else_step = Some (Tool_call { tool_name = "test_tool"; input = `String "outer-else" });
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok json ->
      Alcotest.(check string) "nested else taken" "\"branch-\\\"inner-false\\\"\""
        (Yojson.Safe.to_string json)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Map-reduce — iterate JSON array, apply reduce strategy                    *)
(* -------------------------------------------------------------------------- *)

let test_map_reduce_collect_all_three_inputs () =
  let t = dummy_tool (fun _ _ -> Success (`String "mapped")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("items", `List [
          `String "a"; `String "b"; `String "c";
        ])]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Map_reduce {
      over = "items";
      step = Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      reduce = `Collect_all;
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok (`List items) ->
      Alcotest.(check int) "3 mapped" 3 (List.length items);
      let strs = List.map Yojson.Safe.to_string items in
      Alcotest.(check bool) "all mapped values are 'mapped'"
        true (List.for_all (fun s -> s = "\"mapped\"") strs)
    | Ok other -> Alcotest.failf "expected List, got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_map_reduce_empty_list_initial_value () =
  let t = dummy_tool (fun _ _ -> Success (`String "should-not-run")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("items", `List [])]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Map_reduce {
      over = "items";
      step = Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      reduce = `Majority;
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok `Null -> ()
    | Ok other -> Alcotest.failf "expected Null (empty majority), got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok Null: %s" (error_to_string e))

let test_map_reduce_first_success_returns_first () =
  let t = dummy_tool (fun _ _ -> Success (`String "first")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("items", `List [`Int 1; `Int 2; `Int 3])]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Map_reduce {
      over = "items";
      step = Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      reduce = `First_success;
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok json ->
      Alcotest.(check string) "first result" "\"first\""
        (Yojson.Safe.to_string json)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_map_reduce_reduce_composition_majority () =
  let t = dummy_tool (fun _ _ -> Success (`String "majority-val")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("items", `List [`Int 1; `Int 2; `Int 3; `Int 4])]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Map_reduce {
      over = "items";
      step = Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      reduce = `Majority;
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok json ->
      Alcotest.(check string) "majority value" "\"majority-val\""
        (Yojson.Safe.to_string json)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Checkpoint — on_step_complete callback, partial state on failure          *)
(* -------------------------------------------------------------------------- *)

let test_checkpoint_callback_fires_per_step () =
  let t = dummy_tool (fun _ _ -> Success (`String "ok")) in
  let agent = basic_agent ~tools:[t] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"; text_response "unused"] in
    let reg = make_registry [t] in
    let captured = ref [] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~on_step_complete:(Some (fun step_id result ->
        captured := (step_id, result) :: !captured))
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Sequential [
      Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      Tool_call { tool_name = "test_tool"; input = `Assoc [] };
    ] in
    let _ = ok_or_fail "execute_step"
            (Workflow_engine.execute_step ctx step) in
    let ids = List.map fst (List.rev !captured) in
    Alcotest.(check (list string)) "step ids" ["0"; "1"; "2"] ids)

let test_checkpoint_records_partial_state_on_failure () =
  let bad = dummy_tool ~name:"bad"
    (fun _ _ -> Error { category = Internal "mid-fail"; message = "mid-fail";
                        retryable = false; metadata = [] }) in
  let ok = dummy_tool ~name:"ok" (fun _ _ -> Success (`String "good")) in
  let agent = basic_agent ~tools:[bad; ok] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"; text_response "unused"] in
    let reg = make_registry [bad; ok] in
    let captured = ref [] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun n -> if n = "bad" then Some bad.descriptor
                               else Some ok.descriptor)
      ~on_step_complete:(Some (fun step_id result ->
        captured := (step_id, result) :: !captured))
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Sequential [
      Tool_call { tool_name = "ok"; input = `Assoc [] };
      Tool_call { tool_name = "bad"; input = `Assoc [] };
      Tool_call { tool_name = "ok"; input = `Assoc [] };
    ] in
    let _ = match Workflow_engine.execute_step ctx step with
      | Ok _ | Error _ -> () in
    Alcotest.(check int) "first step recorded" 1 (List.length !captured);
    match !captured with
    | [(id, _)] ->
      Alcotest.(check string) "first step id" "0" id
    | _ -> Alcotest.fail "expected exactly one checkpoint before failure")

let test_checkpoint_make_checkpoint_preserves_state () =
  let t = dummy_tool (fun _ _ -> Success (`String "ok")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("a", `Int 1); ("b", `String "two")]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let cp = Workflow_engine.make_checkpoint
      ~step_path:[0; 1]
      ~step_results:[`String "r1"; `String "r2"]
      ctx in
    Alcotest.(check (list int)) "step_path" [0; 1] cp.step_path;
    Alcotest.(check int) "vars preserved" 2 (List.length cp.variables);
    Alcotest.(check int) "results preserved" 2 (List.length cp.step_results))

let test_checkpoint_resume_uses_loaded_checkpoint () =
  let storage : workflow_checkpoint option ref = ref None in
  let t = dummy_tool (fun _ _ -> Success (`String "resumed-ok")) in
  let agent = basic_agent ~tools:[t] () in
  with_switch (fun sw ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let token = Cancellation.create_token sw in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    (* Simulate the save/load round-trip: build checkpoint, then build a
       fresh ctx that would have been produced by resume_workflow using
       loaded checkpoint variables. *)
    let cp = Workflow_engine.make_checkpoint
      ~step_path:[0]
      ~step_results:[`String "first-step"]
      ctx in
    storage := Some cp;
    match !storage with
    | None -> Alcotest.fail "checkpoint not stored"
    | Some cp' ->
      let resumed_ctx = make_ctx
        ~variables:cp'.variables
        ~agent_resolver:(fun _ -> Some agent)
        ~tool_resolver:(fun _ -> Some t.descriptor)
        ~token ~llm ~registry:reg () in
      let step = Tool_call { tool_name = "test_tool"; input = `Assoc [] } in
      match Workflow_engine.execute_step resumed_ctx step with
      | Ok json ->
        Alcotest.(check string) "resumed tool call" "\"resumed-ok\""
          (Yojson.Safe.to_string json)
      | Error e -> Alcotest.failf "resumed execution failed: %s"
                     (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Workflow lifecycle — submit, status, approve, resume                     *)
(* -------------------------------------------------------------------------- *)

let runtime_config () : runtime_config =
  { persistence = `Sqlite ":memory:";
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = true;
     bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = 604800.0; }

let dummy_workflow ?(id = "wf-test") ?(name = "Workflow Test")
                   ?(steps : workflow_step = Sequential [])
                   ?(variables = []) ?(failure_policy = Fail_fast)
                   ?(parallel_limit = 4) ?(timeout = 300.0)
                   ?(on_complete = None) () : workflow =
  { id; name; version = 1; steps; variables; failure_policy;
    parallel_limit; timeout; on_complete }

let workflow_status_to_string = function
  | Wf_pending -> "Wf_pending"
  | Wf_running -> "Wf_running"
  | Wf_suspended _ -> "Wf_suspended"
  | Wf_completed _ -> "Wf_completed"
  | Wf_failed _ -> "Wf_failed"

let test_lifecycle_submit_running_completed () =
  with_switch (fun sw ->
    let rt = match Runtime.create ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let wf = dummy_workflow ~id:"wf-success"
      ~name:"Success Workflow"
      ~steps:(Tool_call { tool_name = "echo"; input = `String "hi" })
      ~on_complete:(Some (fun _ -> ())) () in
    let _ = Runtime.register_workflow rt wf in
    (* Register an agent that references the tool so submit_workflow
       can resolve it via find_tool_across_agents. *)
    let tool_desc = match Runtime.register_tool rt ~name:"echo"
                       ~description:"echo" ~input_schema:(`Assoc [])
                       ~handler:(fun input _ -> Success input) () with
      | Ok tb -> tb.descriptor
      | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e) in
    let agent = basic_agent ~tools:[{ descriptor = tool_desc; handler = (fun i _ -> Success i) }] () in
    let _ = Runtime.register_agent rt agent in
    let id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit_workflow: %s" (error_to_string e) in
    (match Runtime.get_workflow_status rt id with
     | Ok (Wf_completed r) ->
       Alcotest.(check int) "outputs count" 1 (List.length r.outputs);
       Alcotest.(check bool) "status Success" true (r.status = `Success)
     | Ok other ->
       Alcotest.failf "expected Wf_completed, got %s"
         (workflow_status_to_string other)
     | Error e -> Alcotest.failf "get_workflow_status: %s" (error_to_string e));
    let _ = Runtime.close rt in
    ())

let test_lifecycle_submit_running_failed () =
  with_switch (fun sw ->
    let rt = match Runtime.create ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let tool_desc = match Runtime.register_tool rt ~name:"failing"
                       ~description:"fails" ~input_schema:(`Assoc [])
                       ~handler:(fun _ _ ->
                         Error { category = Internal "fatal"; message = "fatal";
                                 retryable = false; metadata = [] }) () with
      | Ok tb -> tb.descriptor
      | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e) in
    let agent = basic_agent ~tools:[{ descriptor = tool_desc; handler = (fun _ _ ->
      Error { category = Internal "fatal"; message = "fatal";
              retryable = false; metadata = [] }) }] () in
    let _ = Runtime.register_agent rt agent in
    let wf = dummy_workflow ~id:"wf-fail"
      ~name:"Fail Workflow"
      ~steps:(Tool_call { tool_name = "failing"; input = `Assoc [] }) () in
    let _ = Runtime.register_workflow rt wf in
    let id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit_workflow: %s" (error_to_string e) in
    (match Runtime.get_workflow_status rt id with
     | Ok (Wf_failed (Internal msg)) ->
       Alcotest.(check string) "error message" "fatal" msg
     | Ok other ->
       Alcotest.failf "expected Wf_failed, got %s"
         (workflow_status_to_string other)
     | Error e -> Alcotest.failf "get_workflow_status: %s" (error_to_string e));
    let _ = Runtime.close rt in
    ())

let test_lifecycle_approve_then_resume () =
  with_switch (fun sw ->
    let rt = match Runtime.create ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let _ = Runtime.register_tool rt ~name:"echo"
              ~description:"echo" ~input_schema:(`Assoc [])
              ~handler:(fun input _ -> Success input) () in
    let wf_id_str = "wf-approval" in
    let wf = dummy_workflow ~id:wf_id_str
      ~name:"Approval Workflow"
      ~steps:(Human_approval {
        prompt_template = "Approve?";
        timeout = 60.0;
        allowed_roles = ["admin"];
      }) () in
    let _ = Runtime.register_workflow rt wf in
    let id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit_workflow: %s" (error_to_string e) in
    (* After submit, workflow should be suspended. *)
    (match Runtime.get_workflow_status rt id with
     | Ok (Wf_suspended _) -> ()
     | Ok other ->
       Alcotest.failf "expected Wf_suspended, got %s"
         (workflow_status_to_string other)
     | Error e -> Alcotest.failf "get_workflow_status: %s" (error_to_string e));
    (* Approve should succeed on a suspended workflow. *)
    (match Runtime.approve_workflow rt id ~approver:"alice" with
     | Ok () -> ()
     | Error e -> Alcotest.failf "approve_workflow: %s" (error_to_string e));
    let _ = Runtime.close rt in
    ())

let test_lifecycle_approve_rejects_non_suspended () =
  with_switch (fun sw ->
    let rt = match Runtime.create ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let _ = Runtime.register_tool rt ~name:"echo"
              ~description:"echo" ~input_schema:(`Assoc [])
              ~handler:(fun input _ -> Success input) () in
    let wf = dummy_workflow ~id:"wf-completed"
      ~name:"Completed Workflow"
      ~steps:(Tool_call { tool_name = "echo"; input = `String "x" }) () in
    let _ = Runtime.register_workflow rt wf in
    let id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit_workflow: %s" (error_to_string e) in
    (* Workflow already completed; approve must reject. *)
    match Runtime.approve_workflow rt id ~approver:"bob" with
    | Ok () -> Alcotest.fail "expected reject for non-suspended workflow"
    | Error (Invalid_input msg) ->
      Alcotest.(check bool) "mentions suspended" true
        (try ignore (Str.search_forward (Str.regexp "suspended") msg 0); true
         with Not_found -> false)
    | Error e -> Alcotest.failf "expected Invalid_input, got: %s"
                   (error_to_string e))

let test_lifecycle_cancel_sets_failed () =
  with_switch (fun sw ->
    let rt = match Runtime.create ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let _ = Runtime.register_tool rt ~name:"echo"
              ~description:"echo" ~input_schema:(`Assoc [])
              ~handler:(fun input _ -> Success input) () in
    let wf = dummy_workflow ~id:"wf-cancel"
      ~name:"Cancel Workflow"
      ~steps:(Tool_call { tool_name = "echo"; input = `String "x" }) () in
    let _ = Runtime.register_workflow rt wf in
    let id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit_workflow: %s" (error_to_string e) in
    (match Runtime.cancel_workflow rt id with
     | Ok () -> ()
     | Error e -> Alcotest.failf "cancel_workflow: %s" (error_to_string e));
    (match Runtime.get_workflow_status rt id with
     | Ok (Wf_failed (Internal _)) -> ()
     | Ok other ->
       Alcotest.failf "expected Wf_failed, got %s"
         (workflow_status_to_string other)
     | Error e -> Alcotest.failf "get_workflow_status: %s" (error_to_string e)))

(* -------------------------------------------------------------------------- *)
(* Edge cases — single step, deeply nested, empty workflow                  *)
(* -------------------------------------------------------------------------- *)

let test_edge_single_step_tool_call () =
  let t = dummy_tool (fun _ _ -> Success (`String "single")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx ~tool_resolver:(fun _ -> Some t.descriptor)
               ~token ~llm ~registry:reg () in
    let step = Tool_call { tool_name = "test_tool"; input = `Assoc [] } in
    match Workflow_engine.execute_step ctx step with
    | Ok json ->
      Alcotest.(check string) "single step" "\"single\""
        (Yojson.Safe.to_string json)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_edge_deeply_nested_workflow () =
  let t = dummy_tool (fun input _ ->
        match input with
        | `String "leaf" -> Success (`String "leaf-result")
        | _ -> Success `Null) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("go", `Bool true)]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    (* Sequential [ Conditional [ Sequential [ Tool_call leaf ] ] ] *)
    let leaf = Tool_call { tool_name = "test_tool"; input = `String "leaf" } in
    let step : workflow_step = Sequential [
      Conditional {
        condition = Variable "go";
        then_step = Sequential [
          Tool_call { tool_name = "test_tool"; input = `String "x" };
          Conditional {
            condition = Equals (Variable "go", Literal (`Bool true));
            then_step = leaf;
            else_step = None;
          };
        ];
        else_step = None;
      };
    ] in
    match Workflow_engine.execute_step ctx step with
    | Ok (`List [`List [_; `String "leaf-result"]]) ->
      Alcotest.(check bool) "deeply nested leaf found" true true
    | Ok other -> Alcotest.failf "expected List [List [_; leaf-result]], got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_edge_workflow_with_no_variables () =
  let t = dummy_tool (fun _ _ -> Success (`String "no-vars")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx ~tool_resolver:(fun _ -> Some t.descriptor)
               ~token ~llm ~registry:reg () in
    let step = Tool_call { tool_name = "test_tool"; input = `Assoc [] } in
    match Workflow_engine.execute_step ctx step with
    | Ok json ->
      Alcotest.(check string) "no-vars step" "\"no-vars\""
        (Yojson.Safe.to_string json)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_edge_workflow_with_variable_substitution () =
  (* Verify that {{name}} in a tool's input gets substituted from ctx.variables.
     The tool sees the substituted string and echoes it back. *)
  let t = dummy_tool (fun input _ ->
        match input with
        | `Assoc [("greet", `String s)] -> Success (`String ("hello " ^ s))
        | _ -> Success `Null) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("name", `String "world")]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step = Tool_call {
      tool_name = "test_tool";
      input = `Assoc [("greet", `String "Hello {{name}}")];
    } in
    (* Substitution is applied to agent prompts and human-approval templates,
       not to tool input. The tool should see the raw "{{name}}" string. *)
    match Workflow_engine.execute_step ctx step with
    | Ok json ->
      Alcotest.(check string) "tool input raw" "\"hello Hello {{name}}\""
        (Yojson.Safe.to_string json)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Suite wiring                                                             *)
(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "Workflow engine" [
    ("Sequential", [
      Alcotest.test_case "two steps execute in order" `Quick
        test_sequential_two_steps_execute_in_order;
      Alcotest.test_case "first failure stops subsequent (Fail_fast)" `Quick
        test_sequential_first_failure_stops_subsequent;
      Alcotest.test_case "empty workflow -> immediate success" `Quick
        test_sequential_empty_workflow_immediate_success;
      Alcotest.test_case "Continue_on_failure keeps going with Null" `Quick
        test_sequential_continue_on_failure_keeps_going;
    ]);
    ("Parallel", [
      Alcotest.test_case "two parallel steps both complete" `Quick
        test_parallel_two_steps_both_complete;
      Alcotest.test_case "one failure preserves other results" `Quick
        test_parallel_one_failure_preserves_other_results;
      Alcotest.test_case "all failures -> aggregate error" `Quick
        test_parallel_all_failures_aggregate_error;
      Alcotest.test_case "empty parallel -> empty list" `Quick
        test_parallel_empty_returns_empty_list;
    ]);
    ("Conditional", [
      Alcotest.test_case "true condition -> then step" `Quick
        test_conditional_true_branch_executes_then;
      Alcotest.test_case "false condition -> else step" `Quick
        test_conditional_false_branch_executes_else;
      Alcotest.test_case "false condition, no else -> Null" `Quick
        test_conditional_false_no_else_returns_null;
      Alcotest.test_case "nested conditions evaluate inner" `Quick
        test_conditional_nested_evaluates_inner;
    ]);
    ("Map_reduce", [
      Alcotest.test_case "3 inputs map to 3 results (Collect_all)" `Quick
        test_map_reduce_collect_all_three_inputs;
      Alcotest.test_case "empty list -> initial value" `Quick
        test_map_reduce_empty_list_initial_value;
      Alcotest.test_case "First_success returns first" `Quick
        test_map_reduce_first_success_returns_first;
      Alcotest.test_case "Majority composes reduce correctly" `Quick
        test_map_reduce_reduce_composition_majority;
    ]);
    ("Checkpoint", [
      Alcotest.test_case "checkpoint callback fires per step" `Quick
        test_checkpoint_callback_fires_per_step;
      Alcotest.test_case "partial state recorded on failure" `Quick
        test_checkpoint_records_partial_state_on_failure;
      Alcotest.test_case "make_checkpoint preserves state" `Quick
        test_checkpoint_make_checkpoint_preserves_state;
      Alcotest.test_case "resume uses loaded checkpoint variables" `Quick
        test_checkpoint_resume_uses_loaded_checkpoint;
    ]);
    ("Workflow lifecycle", [
      Alcotest.test_case "submit -> running -> completed" `Quick
        test_lifecycle_submit_running_completed;
      Alcotest.test_case "submit -> running -> failed" `Quick
        test_lifecycle_submit_running_failed;
      Alcotest.test_case "approve unlocks suspended workflow" `Quick
        test_lifecycle_approve_then_resume;
      Alcotest.test_case "approve rejects non-suspended workflow" `Quick
        test_lifecycle_approve_rejects_non_suspended;
      Alcotest.test_case "cancel transitions to failed" `Quick
        test_lifecycle_cancel_sets_failed;
    ]);
    ("Edge cases", [
      Alcotest.test_case "single-step workflow" `Quick
        test_edge_single_step_tool_call;
      Alcotest.test_case "deeply nested workflow" `Quick
        test_edge_deeply_nested_workflow;
      Alcotest.test_case "workflow with no variables" `Quick
        test_edge_workflow_with_no_variables;
      Alcotest.test_case "workflow with template input" `Quick
        test_edge_workflow_with_variable_substitution;
    ]);
  ]
