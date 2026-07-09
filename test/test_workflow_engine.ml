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
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 ; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let response_with_tool_calls tool_calls : llm_response =
  { text = None; tool_calls = Some tool_calls; finish_reason = Tool_calls;
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
  context_window_fn = None; cache_control_fn = None;
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
    permission = Allow; timeout = None; concurrency_limit = None; on_update = None;
    cache_control = None } in
  { descriptor; handler }

let basic_agent ?(tools = []) () =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id = "test-agent"; system_prompt = stable_prompt "You are a test agent.";
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations = 10;
    middleware = []; retry_policy = None;
    context_strategy = None; resource_quota = None; max_execution_time = None; tool_timeout = None; early_stopping_method = Force; on_max_tokens = Some Return_partial; max_continuation_chunks = Some 3;
    context_compression_threshold = None; compression_cooldown_messages = None; context_window_override = None; cache_strategy = No_caching }

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
             ?(workflow_id_resolver = (fun () -> None))
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
    workflow_run_id;
    workflow_id_resolver;
    workspace = (match Workspace.of_cwd () with Ok w -> w | Error _ -> failwith "test workspace");
  }

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
      ~on_step_complete:(Some (fun path result ->
        captured := (path, result) :: !captured))
      ~token ~llm ~registry:reg () in
    let step : workflow_step = Sequential [
      Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      Tool_call { tool_name = "test_tool"; input = `Assoc [] };
    ] in
    let _ = ok_or_fail "execute_step"
            (Workflow_engine.execute_step ctx step) in
    let ids = List.map fst (List.rev !captured) in
    Alcotest.(check (list string)) "step ids" ["0"; "1"; "2"]
      (List.map (fun p -> String.concat "." (List.map string_of_int p)) ids))

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
      ~on_step_complete:(Some (fun path result ->
        captured := (path, result) :: !captured))
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
      Alcotest.(check string) "first step id" "0"
        (String.concat "." (List.map string_of_int id))
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
    Alcotest.(check int) "results preserved" 2 (List.length cp.step_results);
    Alcotest.(check (option (list string))) "allowed_roles default None" None cp.allowed_roles;
    Alcotest.(check string) "workflow_id default empty" "" cp.workflow_id)

let test_checkpoint_with_allowed_roles_round_trips () =
  let t = dummy_tool (fun _ _ -> Success (`String "ok")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("k", `String "v")]
      ~workflow_id_resolver:(fun () -> Some "wf-roundtrip")
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let cp = Workflow_engine.make_checkpoint
      ~step_path:[2; 3]
      ~step_results:[`String "r1"]
      ~allowed_roles:(Some ["admin"; "reviewer"])
      ctx in
    Alcotest.(check string) "workflow_id from resolver" "wf-roundtrip" cp.workflow_id;
    Alcotest.(check (option (list string))) "allowed_roles preserved"
      (Some ["admin"; "reviewer"]) cp.allowed_roles;
    let json = workflow_checkpoint_to_yojson cp in
    match workflow_checkpoint_of_yojson json with
    | Ok cp' ->
      Alcotest.(check string) "round-trip workflow_id" "wf-roundtrip" cp'.workflow_id;
      Alcotest.(check (option (list string))) "round-trip allowed_roles"
        (Some ["admin"; "reviewer"]) cp'.allowed_roles;
      Alcotest.(check (list int)) "round-trip step_path" [2; 3] cp'.step_path
    | Error e -> Alcotest.failf "checkpoint decode: %s" e)

let test_checkpoint_none_allowed_roles_round_trips () =
  let t = dummy_tool (fun _ _ -> Success (`String "ok")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let cp = Workflow_engine.make_checkpoint
      ~step_path:[]
      ctx in
    Alcotest.(check (option (list string))) "default allowed_roles is None"
      None cp.allowed_roles;
    let json = workflow_checkpoint_to_yojson cp in
    match workflow_checkpoint_of_yojson json with
    | Ok cp' ->
      Alcotest.(check (option (list string))) "round-trip None allowed_roles"
        None cp'.allowed_roles
    | Error e -> Alcotest.failf "checkpoint decode: %s" e)

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

let test_resume_sequential_after_approval_runs_remaining_steps () =
  (* 3-step Sequential with Human_approval at index 1. After approval,
     resume_from_checkpoint must skip step 0 (already done), skip the
     Human_approval (treated as approved), and run step 2. *)
  let t = dummy_tool (fun _ _ -> Success (`String "step-after-approval")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("result_0", `String "first-step-result")]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let top_step : workflow_step = Sequential [
      Tool_call { tool_name = "test_tool"; input = `String "skipped" };
      Human_approval { prompt_template = "approve?"; timeout = 60.0;
                       allowed_roles = ["admin"] };
      Tool_call { tool_name = "test_tool"; input = `String "after" };
    ] in
    let cp : workflow_checkpoint = {
      workflow_id = "wf-resume";
      step_path = [1];
      variables = ctx.Workflow_engine.variables;
      step_results = [`String "first-step-result"];
      allowed_roles = Some ["admin"];
    } in
    match Workflow_engine.resume_from_checkpoint ctx top_step cp with
    | Ok (`List results) ->
      Alcotest.(check int) "post-resume ran one step" 1 (List.length results);
      Alcotest.(check string) "post-resume step runs" "\"step-after-approval\""
        (Yojson.Safe.to_string (List.hd results))
    | Ok other -> Alcotest.failf "expected List [step-after-approval], got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "resume failed: %s" (error_to_string e))

let test_resume_restores_variables_from_checkpoint () =
  (* Verify that resume substitutes checkpoint.variables into remaining tool
     inputs. The placeholder var on the input is what proves the ctx was
     rebuilt with the checkpoint's variables. *)
  let captured_input = ref `Null in
  let t = dummy_tool (fun input _ ->
    captured_input := input;
    Success (`String "ok")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("placeholder", `Null)]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let top_step : workflow_step = Sequential [
      Human_approval { prompt_template = "ok?"; timeout = 60.0;
                       allowed_roles = [] };
      Tool_call { tool_name = "test_tool";
                  input = `Assoc [("msg", `String "got-{{restored}}-ok")] };
    ] in
    let saved_vars = [("restored", `String "alpha-value");
                      ("result_0", `String "first")] in
    let cp : workflow_checkpoint = {
      workflow_id = "wf-vars";
      step_path = [0];
      variables = saved_vars;
      step_results = [`String "first"];
      allowed_roles = Some [];
    } in
    ignore (Workflow_engine.resume_from_checkpoint ctx top_step cp);
    Alcotest.(check string) "restored var substituted into tool input"
      "{\"msg\":\"got-alpha-value-ok\"}"
      (Yojson.Safe.to_string !captured_input))

let test_resume_nested_sequential_drops_into_inner_branch () =
  (* Outer Sequential [A, Inner(approval, B), C]; checkpoint at [1; 0]
     means Inner is at outer index 1, Human_approval is at inner index 0. *)
  let t = dummy_tool (fun _ _ -> Success (`String "B-out")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("A", `String "done")]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let top_step : workflow_step = Sequential [
      Tool_call { tool_name = "test_tool"; input = `String "A" };
      Sequential [
        Human_approval { prompt_template = "ok?"; timeout = 60.0;
                         allowed_roles = [] };
        Tool_call { tool_name = "test_tool"; input = `String "B" };
      ];
      Tool_call { tool_name = "test_tool"; input = `String "C" };
    ] in
    let cp : workflow_checkpoint = {
      workflow_id = "wf-nested";
      step_path = [1; 0];
      variables = ctx.Workflow_engine.variables;
      step_results = [`String "A"];
      allowed_roles = Some [];
    } in
    match Workflow_engine.resume_from_checkpoint ctx top_step cp with
    | Ok (`List results) ->
      Alcotest.(check int) "one resumed step (B)" 1 (List.length results);
      Alcotest.(check string) "B runs" "\"B-out\""
        (Yojson.Safe.to_string (List.hd results))
    | Ok other -> Alcotest.failf "expected List of 1, got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "nested resume failed: %s" (error_to_string e))

let test_resume_conditional_true_branch_runs_after_approval () =
  let t = dummy_tool (fun _ _ -> Success (`String "then-result")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("flag", `Bool true)]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let top_step : workflow_step = Sequential [
      Human_approval { prompt_template = "go?"; timeout = 60.0;
                       allowed_roles = [] };
      Conditional {
        condition = Variable "flag";
        then_step = Tool_call { tool_name = "test_tool"; input = `String "then" };
        else_step = Some (Tool_call { tool_name = "test_tool"; input = `String "else" });
      };
    ] in
    let cp : workflow_checkpoint = {
      workflow_id = "wf-cond";
      step_path = [0];
      variables = ctx.Workflow_engine.variables;
      step_results = [];
      allowed_roles = Some [];
    } in
    match Workflow_engine.resume_from_checkpoint ctx top_step cp with
    | Ok (`List results) ->
      Alcotest.(check int) "one resumed step (conditional)" 1 (List.length results);
      Alcotest.(check string) "then branch runs" "\"then-result\""
        (Yojson.Safe.to_string (List.hd results))
    | Ok other -> Alcotest.failf "expected List [then-result], got %s"
                    (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "conditional resume failed: %s"
                   (error_to_string e))

let test_resume_rejects_parallel_at_step_path () =
  let t = dummy_tool (fun _ _ -> Success (`String "x")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("done", `String "yes")]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let top_step : workflow_step = Sequential [
      Tool_call { tool_name = "test_tool"; input = `String "A" };
      Parallel [
        Tool_call { tool_name = "test_tool"; input = `String "B" };
        Tool_call { tool_name = "test_tool"; input = `String "C" };
      ];
    ] in
    let cp : workflow_checkpoint = {
      workflow_id = "wf-parallel";
      step_path = [1];
      variables = ctx.Workflow_engine.variables;
      step_results = [`String "A"];
      allowed_roles = None;
    } in
    match Workflow_engine.resume_from_checkpoint ctx top_step cp with
    | Ok _ -> Alcotest.fail "expected Error for Parallel mid-Sequential resume"
    | Error (Internal msg) ->
      Alcotest.(check bool) "mentions Parallel" true
        (try ignore (Str.search_forward (Str.regexp "Parallel") msg 0); true
         with Not_found -> false)
    | Error e -> Alcotest.failf "expected Internal, got: %s" (error_to_string e))

let test_resume_invalid_step_path_returns_error () =
  let t = dummy_tool (fun _ _ -> Success (`String "x")) in
  with_token (fun token ->
    let llm = mock_llm [text_response "unused"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let top_step : workflow_step = Sequential [
      Tool_call { tool_name = "test_tool"; input = `String "A" };
    ] in
    let cp : workflow_checkpoint = {
      workflow_id = "wf-bad-path";
      step_path = [5];
      variables = ctx.Workflow_engine.variables;
      step_results = [];
      allowed_roles = None;
    } in
    match Workflow_engine.resume_from_checkpoint ctx top_step cp with
    | Ok _ -> Alcotest.fail "expected Error for out-of-bounds step_path"
    | Error _ -> ())

let test_step_path_tracks_nested_position () =
  let paths_seen = ref [] in
  let t = dummy_tool (fun _ _ -> Success (`String "ok")) in
  let agent = basic_agent ~tools:[t] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "x"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg
      ~on_step_complete:(Some (fun path _ -> paths_seen := path :: !paths_seen))
      () in
    let step = Sequential [
      Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      Sequential [
        Tool_call { tool_name = "test_tool"; input = `Assoc [] };
        Tool_call { tool_name = "test_tool"; input = `Assoc [] };
      ];
      Tool_call { tool_name = "test_tool"; input = `Assoc [] };
    ] in
    ignore (Workflow_engine.execute_step ctx step);
    List.sort compare (List.map (fun p -> String.concat "." (List.map string_of_int p)) !paths_seen)
    |> fun ps ->
    Alcotest.(check bool) "step_path nested seen"
      (List.mem "0" ps && List.mem "1.0" ps && List.mem "1.1" ps && List.mem "2" ps) true)

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
  { def = { id; name; version = 1; steps; variables; failure_policy;
            parallel_limit; timeout };
    on_complete }

let workflow_status_to_string = function
  | Wf_pending -> "Wf_pending"
  | Wf_running -> "Wf_running"
  | Wf_suspended _ -> "Wf_suspended"
  | Wf_completed _ -> "Wf_completed"
  | Wf_failed _ -> "Wf_failed"

(* -------------------------------------------------------------------------- *)
(* Rehydration — boot-time population of rt.workflows from persistence       *)
(* -------------------------------------------------------------------------- *)

let rehydration_runtime_config db_path : runtime_config =
  { persistence = `Sqlite db_path;
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = true;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = 604800.0; }

let make_rehydration_persist (sqlt : Sqlite_persistence.t) : persistence_service =
  { save_events_fn = (fun envs -> Sqlite_persistence.save_events sqlt envs);
    load_events_fn = (fun tid -> Sqlite_persistence.load_events sqlt tid);
    load_events_by_session_fn =
      (fun sid -> Sqlite_persistence.load_events_by_session sqlt sid);
    load_sessions_fn = (fun lim -> Sqlite_persistence.load_sessions sqlt lim);
    save_task_state_fn =
      (fun ts -> Sqlite_persistence.save_task_state sqlt ts);
    load_task_state_fn =
      (fun tid -> Sqlite_persistence.load_task_state sqlt tid);
    save_workflow_state_fn =
      (fun id st cp -> Sqlite_persistence.save_workflow_state sqlt id st cp);
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
    close_fn = (fun () -> Sqlite_persistence.close sqlt); }

let rehydration_mock_llm =
  { complete_fn = (fun _model _tools _conv -> Ok (text_response "unused"));
    stream_fn = (fun _ _tools _ _ _ ->
      Ok { final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = ignore;
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None; }

let test_rehydration_restores_suspended_workflows () =
  with_switch (fun sw1 ->
    let db_path = Filename.temp_file "par_rehydration_" ".db" in
    try
      let run_id = Workflow_run_id.create () in
      let cp : workflow_checkpoint = {
        workflow_id = "wf-suspended";
        step_path = [0];
        variables = [("k", `String "v")];
        step_results = [`String "first-step"];
        allowed_roles = Some ["admin"];
      } in
      (* Round 1: create runtime, save suspended state. *)
      let persist1, rt1 =
        match Sqlite_persistence.create db_path with
        | Error e -> Alcotest.failf "sqlite create: %s" (error_to_string e)
        | Ok sqlt1 ->
          let persist1 = make_rehydration_persist sqlt1 in
          (match Runtime.create ~llm:rehydration_mock_llm
                  ~persistence:persist1
                  ~config:(rehydration_runtime_config db_path)
                  sw1 with
           | Ok r -> (persist1, r)
           | Error e -> Alcotest.failf "rt1 create: %s" (error_to_string e))
      in
      (match persist1.save_workflow_state_fn
              run_id (Wf_suspended cp) (Some cp) with
       | Ok () -> ()
       | Error e -> Alcotest.failf "save: %s" (error_to_string e));
      let _ = Runtime.close rt1 in
      (* Round 2: re-open DB in a fresh runtime via a new switch. *)
      with_switch (fun sw2 ->
        let rt2 =
          match Sqlite_persistence.create db_path with
          | Error e -> Alcotest.failf "sqlite reopen: %s" (error_to_string e)
          | Ok sqlt2 ->
            let persist2 = make_rehydration_persist sqlt2 in
            match Runtime.create ~llm:rehydration_mock_llm
                    ~persistence:persist2
                    ~config:(rehydration_runtime_config db_path)
                    sw2 with
            | Ok r -> r
            | Error e -> Alcotest.failf "rt2 create: %s" (error_to_string e)
        in
        (match Runtime.get_workflow_status rt2 run_id with
         | Ok (Wf_suspended cp') ->
           Alcotest.(check string) "rehydrated workflow_id" "wf-suspended" cp'.workflow_id;
           Alcotest.(check (list int)) "rehydrated step_path" [0] cp'.step_path;
           (match cp'.allowed_roles with
            | Some roles -> Alcotest.(check (list string)) "allowed_roles" ["admin"] roles
            | None -> Alcotest.fail "expected Some allowed_roles")
         | Ok other ->
           Alcotest.failf "expected Wf_suspended, got %s"
             (workflow_status_to_string other)
         | Error e -> Alcotest.failf "get_workflow_status: %s" (error_to_string e));
        let _ = Runtime.close rt2 in
        ());
      Sys.remove db_path
    with exn ->
      (try Sys.remove db_path with _ -> ());
      raise exn)

let test_rehydration_resume_works_after_restart () =
  (* The critical regression test for §2.1 + FIX 1: after process restart,
     Runtime.create must restore BOTH suspended runs AND their workflow
     definitions, so resume_workflow can actually replay the remaining
     steps. Before the fix, workflow_defs was not restored and resume
     would fail with "Workflow definition not found". *)
  with_switch (fun sw1 ->
    let db_path = Filename.temp_file "par_resume_restart_" ".db" in
    try
      (* Round 1: register workflow with Human_approval, submit, it suspends. *)
      let _persist1, rt1 =
        match Sqlite_persistence.create db_path with
        | Error e -> Alcotest.failf "sqlite create: %s" (error_to_string e)
        | Ok sqlt1 ->
          let persist1 = make_rehydration_persist sqlt1 in
          (match Runtime.create ~llm:rehydration_mock_llm
                  ~persistence:persist1
                  ~config:(rehydration_runtime_config db_path)
                  sw1 with
           | Ok r -> (persist1, r)
           | Error e -> Alcotest.failf "rt1 create: %s" (error_to_string e))
      in
      let agent = ({ (basic_agent ()) with id = "post-approver" }) in
      (match Runtime.register_agent rt1 agent with
       | Ok () -> ()
       | Error e -> Alcotest.failf "register_agent: %s" (error_to_string e));
      let wf = dummy_workflow
        ~id:"wf-restart-resume"
        ~name:"Restart Resume"
        ~steps:(Sequential [
          Human_approval { prompt_template = "ok?"; timeout = 60.0;
                           allowed_roles = ["admin"] };
          Agent_call { agent_id = "post-approver";
                       prompt_template = "You are approved. Say 'done'.";
                       response_schema = None };
        ]) () in
        (match Runtime.register_workflow rt1 wf with
         | Ok () -> ()
         | Error e -> Alcotest.failf "register_workflow: %s" (error_to_string e));
        let run_id =
          match Runtime.submit_workflow rt1 wf with
          | Ok id -> id
          | Error e -> Alcotest.failf "submit_workflow: %s" (error_to_string e)
        in
        (match Runtime.get_workflow_status rt1 run_id with
         | Ok (Wf_suspended _) -> ()
         | Ok other -> Alcotest.failf "expected Wf_suspended, got %s"
                         (workflow_status_to_string other)
         | Error e -> Alcotest.failf "status: %s" (error_to_string e));
        let _ = Runtime.close rt1 in
        (* Round 2: fresh runtime, NO register_workflow call.
           The def should be auto-restored from workflow_definitions table. *)
        with_switch (fun sw2 ->
          let rt2 =
            match Sqlite_persistence.create db_path with
            | Error e -> Alcotest.failf "sqlite reopen: %s" (error_to_string e)
            | Ok sqlt2 ->
              let persist2 = make_rehydration_persist sqlt2 in
              match Runtime.create ~llm:rehydration_mock_llm
                      ~persistence:persist2
                      ~config:(rehydration_runtime_config db_path)
                      sw2 with
              | Ok r -> r
              | Error e -> Alcotest.failf "rt2 create: %s" (error_to_string e)
          in
          (* Tool handler also needs to be re-registered (persistence doesn't
             cover tool handlers — only descriptors). *)
          let agent2 = ({ (basic_agent ()) with id = "post-approver" }) in
          (match Runtime.register_agent rt2 agent2 with
           | Ok () -> ()
           | Error e -> Alcotest.failf "register_agent rt2: %s" (error_to_string e));
          (* Critical assertion: resume succeeds without manual register_workflow. *)
          (match Runtime.resume_workflow rt2 run_id with
           | Ok (Some result) ->
             Alcotest.(check string) "result status Success"
               "Success" (match result.status with
                          | `Success -> "Success"
                          | `Partial -> "Partial"
                          | `Failed -> "Failed");
             (match List.assoc_opt "result" result.outputs with
              | Some (`List [_]) ->
                Alcotest.(check bool) "post-approval step ran (got result list)"
                  true true
              | Some other ->
                Alcotest.failf "expected List with one element, got %s"
                  (Yojson.Safe.to_string other)
              | None -> Alcotest.fail "expected result output")
           | Ok None -> Alcotest.fail "expected Some result, got None (still suspended?)"
           | Error e -> Alcotest.failf "resume after restart failed: %s"
                          (error_to_string e));
          let _ = Runtime.close rt2 in
          ());
      Sys.remove db_path
    with exn ->
      (try Sys.remove db_path with _ -> ());
      raise exn)

let test_rehydration_empty_db_returns_no_runs () =  with_switch (fun sw ->
    let db_path = Filename.temp_file "par_rehydration_empty_" ".db" in
    try
      let rt =
        match Sqlite_persistence.create db_path with
        | Error e -> Alcotest.failf "sqlite create: %s" (error_to_string e)
        | Ok sqlt ->
          let persist = make_rehydration_persist sqlt in
          match Runtime.create ~llm:rehydration_mock_llm
                  ~persistence:persist
                  ~config:(rehydration_runtime_config db_path)
                  sw with
          | Ok r -> r
          | Error e -> Alcotest.failf "create: %s" (error_to_string e)
      in
      (* Rehydration on empty DB must NOT inject any phantom run. *)
      let dummy_run_id = Workflow_run_id.create () in
      (match Runtime.get_workflow_status rt dummy_run_id with
       | Ok _ -> Alcotest.fail "expected not-found for unhydrated run"
       | Error _ -> ());
      let _ = Runtime.close rt in
      Sys.remove db_path
    with exn ->
      (try Sys.remove db_path with _ -> ());
      raise exn)

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
    (* Approve should succeed — approver "admin" matches allowed_roles. *)
    (match Runtime.approve_workflow rt id ~approver:"admin" with
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

(* -------------------------------------------------------------------------- *)
(* Approve-workflow role validation (§1.2) — unit tests bypassing submit       *)
(* -------------------------------------------------------------------------- *)

let test_approve_validates_allowed_roles_allows_authorized () =
  with_switch (fun sw ->
    let rt = match Runtime.create ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let wf_id_str = "wf-role-ok" in
    let wf = dummy_workflow ~id:wf_id_str
      ~name:"Role OK"
      ~steps:(Human_approval {
        prompt_template = "ok?";
        timeout = 60.0;
        allowed_roles = ["admin"; "reviewer"];
      }) () in
    let _ = Runtime.register_workflow rt wf in
    let id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit: %s" (error_to_string e) in
    match Runtime.approve_workflow rt id ~approver:"admin" with
    | Ok () -> ()
    | Error e -> Alcotest.failf "expected Ok for authorized approver, got: %s"
                   (error_to_string e))

let test_approve_validates_allowed_roles_rejects_unauthorized () =
  with_switch (fun sw ->
    let rt = match Runtime.create ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let wf_id_str = "wf-role-bad" in
    let wf = dummy_workflow ~id:wf_id_str
      ~name:"Role Bad"
      ~steps:(Human_approval {
        prompt_template = "ok?";
        timeout = 60.0;
        allowed_roles = ["admin"; "reviewer"];
      }) () in
    let _ = Runtime.register_workflow rt wf in
    let id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit: %s" (error_to_string e) in
    match Runtime.approve_workflow rt id ~approver:"intern" with
    | Ok () -> Alcotest.fail "expected reject for unauthorized approver"
    | Error (Permission_denied msg) ->
      Alcotest.(check bool) "mentions allowed_roles" true
        (try ignore (Str.search_forward (Str.regexp "allowed_roles") msg 0); true
         with Not_found -> false);
      (match Runtime.get_workflow_status rt id with
       | Ok (Wf_suspended _) -> ()
       | Ok other -> Alcotest.failf "expected still suspended, got: %s"
                       (workflow_status_to_string other)
       | Error e -> Alcotest.failf "status: %s" (error_to_string e))
    | Error e -> Alcotest.failf "expected Permission_denied, got: %s"
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
(* Workflow lifecycle events (§1.4) — capture via custom event_bus_service    *)
(* -------------------------------------------------------------------------- *)

let capture_event_bus () :
    (event list ref * event_bus_service) =
  let events = ref [] in
  let service : event_bus_service = {
    publish_fn = (fun evt -> events := evt :: !events);
    subscribe_fn = (fun _ -> "");
    unsubscribe_fn = (fun _ -> ());
    set_session_id_fn = (fun _ -> ());
    start_dispatcher_fn = (fun _ -> ());
  } in
  (events, service)

let has_workflow_event (events : event list) predicate =
  List.exists predicate events

let test_submit_emits_workflow_started_and_completed () =
  with_switch (fun sw ->
    let events, bus = capture_event_bus () in
    let rt = match Runtime.create ~event_bus:bus
                              ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let tool_desc = match Runtime.register_tool rt ~name:"echo"
                       ~description:"echo" ~input_schema:(`Assoc [])
                       ~handler:(fun input _ -> Success input) () with
      | Ok tb -> tb.descriptor
      | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e) in
    let agent = basic_agent ~tools:[{ descriptor = tool_desc;
                                       handler = (fun i _ -> Success i) }] () in
    let _ = Runtime.register_agent rt agent in
    let wf = dummy_workflow ~id:"wf-events-ok"
      ~name:"Events OK"
      ~steps:(Sequential [
        Tool_call { tool_name = "echo"; input = `String "hi" };
      ]) () in
    let _ = Runtime.register_workflow rt wf in
    let _id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit: %s" (error_to_string e) in
    Alcotest.(check bool) "Workflow_started emitted" true
      (has_workflow_event !events (function
        | Workflow_started _ -> true | _ -> false));
    Alcotest.(check bool) "Workflow_completed emitted" true
      (has_workflow_event !events (function
        | Workflow_completed _ -> true | _ -> false));
    Alcotest.(check bool) "Workflow_step_completed emitted" true
      (has_workflow_event !events (function
        | Workflow_step_completed _ -> true | _ -> false));
    let _ = Runtime.close rt in
    ())

let test_submit_failure_emits_workflow_failed () =
  with_switch (fun sw ->
    let events, bus = capture_event_bus () in
    let rt = match Runtime.create ~event_bus:bus
                              ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let tool_desc = match Runtime.register_tool rt ~name:"failing"
                       ~description:"fails" ~input_schema:(`Assoc [])
                       ~handler:(fun _ _ ->
                         Error { category = Internal "boom"; message = "boom";
                                 retryable = false; metadata = [] }) () with
      | Ok tb -> tb.descriptor
      | Error e -> Alcotest.failf "register: %s" (error_to_string e) in
    let agent = basic_agent ~tools:[{ descriptor = tool_desc;
                                       handler = (fun _ _ ->
                                         Error { category = Internal "boom";
                                                 message = "boom";
                                                 retryable = false;
                                                 metadata = [] }) }] () in
    let _ = Runtime.register_agent rt agent in
    let wf = dummy_workflow ~id:"wf-events-fail"
      ~name:"Events Fail"
      ~steps:(Tool_call { tool_name = "failing"; input = `Assoc [] }) () in
    let _ = Runtime.register_workflow rt wf in
    let _id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit: %s" (error_to_string e) in
    Alcotest.(check bool) "Workflow_failed emitted" true
      (has_workflow_event !events (function
        | Workflow_failed _ -> true | _ -> false));
    let _ = Runtime.close rt in
    ())

let test_suspended_submit_emits_approval_requested () =
  with_switch (fun sw ->
    let events, bus = capture_event_bus () in
    let rt = match Runtime.create ~event_bus:bus
                              ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let wf = dummy_workflow ~id:"wf-events-approval"
      ~name:"Events Approval"
      ~steps:(Human_approval {
        prompt_template = "Approve?";
        timeout = 60.0;
        allowed_roles = ["admin"];
      }) () in
    let _ = Runtime.register_workflow rt wf in
    let _id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit: %s" (error_to_string e) in
    Alcotest.(check bool) "Approval_requested emitted" true
      (has_workflow_event !events (function
        | Approval_requested _ -> true | _ -> false));
    let _ = Runtime.close rt in
    ())

let test_approve_emits_approval_granted () =
  with_switch (fun sw ->
    let events, bus = capture_event_bus () in
    let rt = match Runtime.create ~event_bus:bus
                              ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let wf = dummy_workflow ~id:"wf-events-granted"
      ~name:"Events Granted"
      ~steps:(Human_approval {
        prompt_template = "Approve?";
        timeout = 60.0;
        allowed_roles = ["admin"];
      }) () in
    let _ = Runtime.register_workflow rt wf in
    let id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit: %s" (error_to_string e) in
    (* Reset the events list so we capture only the approve call. *)
    events := [];
    (match Runtime.approve_workflow rt id ~approver:"admin" with
     | Ok () -> ()
     | Error e -> Alcotest.failf "approve: %s" (error_to_string e));
    Alcotest.(check bool) "Approval_granted emitted" true
      (has_workflow_event !events (function
        | Approval_granted _ -> true | _ -> false));
    let _ = Runtime.close rt in
    ())

let test_cancel_emits_workflow_failed_event () =
  with_switch (fun sw ->
    let events, bus = capture_event_bus () in
    let rt = match Runtime.create ~event_bus:bus ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let wf = dummy_workflow ~id:"wf-cancel-evt"
      ~name:"Cancel Events"
      ~steps:(Human_approval {
        prompt_template = "ok?"; timeout = 60.0;
        allowed_roles = ["admin"] }) () in
    let _ = Runtime.register_workflow rt wf in
    let id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit: %s" (error_to_string e) in
    (match Runtime.cancel_workflow rt id with
     | Ok () -> ()
     | Error e -> Alcotest.failf "cancel: %s" (error_to_string e));
    Alcotest.(check bool) "Workflow_failed event emitted on cancel"
      true (has_workflow_event !events (function
              | Workflow_failed { workflow_run_id; _ } ->
                Workflow_run_id.to_string workflow_run_id =
                Workflow_run_id.to_string id
              | _ -> false));
    (match Runtime.cancel_workflow rt (Workflow_run_id.create ()) with
     | Ok () -> Alcotest.fail "should reject unknown workflow id"
     | Error (Invalid_input _) -> ()
     | Error e -> Alcotest.failf "expected Invalid_input, got: %s"
                    (error_to_string e)))

let test_resume_runtime_runs_remaining_tool_calls () =
  (* End-to-end: register workflow with Sequential[a, approval, b, c],
     suspend at approval, call resume_workflow via Runtime API, assert
     final tool call (c) executes and workflow completes. *)
  with_switch (fun sw ->
    let rt = match Runtime.create ~config:(runtime_config ()) sw with
      | Ok r -> r
      | Error e -> Alcotest.failf "create: %s" (error_to_string e) in
    let tool_desc = match Runtime.register_tool rt ~name:"echo"
                       ~description:"echo" ~input_schema:(`Assoc [])
                       ~handler:(fun input _ -> Success input) () with
      | Ok tb -> tb.descriptor
      | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e) in
    let agent = basic_agent ~tools:[{ descriptor = tool_desc;
                                       handler = (fun i _ -> Success i) }] () in
    let _ = Runtime.register_agent rt agent in
    let wf_id_str = "wf-runtime-resume" in
    let wf = dummy_workflow ~id:wf_id_str
      ~name:"Runtime Resume"
      ~steps:(Sequential [
        Tool_call { tool_name = "echo"; input = `String "step-a" };
        Human_approval { prompt_template = "Approve step b?"; timeout = 60.0;
                         allowed_roles = ["admin"] };
        Tool_call { tool_name = "echo"; input = `String "step-c" };
      ]) () in
    let _ = Runtime.register_workflow rt wf in
    let id = match Runtime.submit_workflow rt wf with
      | Ok id -> id
      | Error e -> Alcotest.failf "submit: %s" (error_to_string e) in
    (match Runtime.get_workflow_status rt id with
     | Ok (Wf_suspended cp) ->
       Alcotest.(check (option (list string))) "allowed_roles captured"
         (Some ["admin"]) cp.allowed_roles
     | Ok other ->
       Alcotest.failf "expected Wf_suspended, got %s"
         (workflow_status_to_string other)
     | Error e -> Alcotest.failf "status: %s" (error_to_string e));
    (match Runtime.resume_workflow rt id with
     | Ok (Some result) ->
       Alcotest.(check bool) "result.Success" true (result.status = `Success);
       (match List.assoc_opt "result" result.outputs with
        | Some (`List (`String s :: _)) ->
          Alcotest.(check string) "final output is step-c" "step-c" s
        | other -> Alcotest.failf "expected final output to wrap [step-c], got: %s"
                     (match other with
                      | Some j -> Yojson.Safe.to_string j
                      | None -> "<missing>"))
     | Ok None -> Alcotest.fail "resume returned None (workflow still suspended?)"
     | Error e -> Alcotest.failf "resume_workflow: %s" (error_to_string e));
    (match Runtime.get_workflow_status rt id with
     | Ok (Wf_completed _) -> ()
     | Ok other ->
       Alcotest.failf "expected Wf_completed after resume, got %s"
         (workflow_status_to_string other)
     | Error e -> Alcotest.failf "final status: %s" (error_to_string e));
    let _ = Runtime.close rt in
    ())

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
    match Workflow_engine.execute_step ctx step with
    | Ok json ->
      Alcotest.(check string) "tool input substituted" "\"hello Hello world\""
        (Yojson.Safe.to_string json)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_tool_input_deep_nested_substitution () =
  let t = dummy_tool (fun input _ -> Success input) in
  with_token (fun token ->
    let llm = mock_llm [text_response "x"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~variables:[("x", `String "42"); ("y", `String "hello")]
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step = Tool_call {
      tool_name = "test_tool";
      input = `Assoc [
        ("a", `Assoc [("b", `String "{{x}}")]);
        ("c", `List [`String "{{y}}"; `Int 7]);
      ];
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok json ->
      Alcotest.(check string) "deep nested subst"
        "{\"a\":{\"b\":\"42\"},\"c\":[\"hello\",7]}"
        (Yojson.Safe.to_string json)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_agent_call_preserves_tool_calls () =
  let mock_tc : Types.tool_call = {
    id = "tc-1";
    name = "calc";
    arguments = `Assoc [("x", `Int 2)];
  } in
  let llm = mock_llm [response_with_tool_calls [mock_tc]] in
  let agent = basic_agent () in
  with_token (fun token ->
    let reg = make_registry [] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~token ~llm ~registry:reg () in
    let step = Agent_call { agent_id = "test-agent"; prompt_template = "x"; response_schema = None } in
    match Workflow_engine.execute_step ctx step with
    | Ok (`Assoc fields) ->
      (match List.assoc_opt "tool_calls" fields with
       | Some (`List (_ :: _)) -> Alcotest.(check bool) "tool_calls preserved" true true
       | _ -> Alcotest.failf "tool_calls should be a non-empty list, got: %s"
                (Yojson.Safe.to_string (`Assoc fields)))
    | Ok other -> Alcotest.failf "expected Assoc, got %s" (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_sequential_propagates_result_to_next_step () =
  let t = dummy_tool (fun input _ ->
    match input with
    | `Assoc [("msg", `String s)] -> Success (`String ("echo:" ^ s))
    | _ -> Success `Null) in
  let agent = basic_agent ~tools:[t] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "step1-output"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step = Sequential [
      Agent_call { agent_id = "test-agent"; prompt_template = "anything"; response_schema = None };
      Tool_call { tool_name = "test_tool"; input = `Assoc [("msg", `String "got {{result.text}}")] };
    ] in
    match Workflow_engine.execute_step ctx step with
    | Ok (`List [_; second]) ->
      (match second with
       | `String s -> Alcotest.(check string) "step 2 sees step 1 result" "echo:got step1-output" s
       | _ -> Alcotest.fail "expected string from tool")
    | Ok other -> Alcotest.failf "expected Ok (List [_; _]), got %s"
                   (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "unexpected error: %s" (error_to_string e))

let test_sequential_propagates_indexed_results () =
  let t = dummy_tool (fun input _ ->
    match input with
    | `Assoc [("x", `String s)] -> Success (`String s)
    | _ -> Success `Null) in
  let agent = basic_agent ~tools:[t] () in
  with_token (fun token ->
    let llm = mock_llm [text_response "first"; text_response "second"] in
    let reg = make_registry [t] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~tool_resolver:(fun _ -> Some t.descriptor)
      ~token ~llm ~registry:reg () in
    let step = Sequential [
      Agent_call { agent_id = "test-agent"; prompt_template = "1"; response_schema = None };
      Agent_call { agent_id = "test-agent"; prompt_template = "2"; response_schema = None };
      Tool_call { tool_name = "test_tool"; input = `Assoc [("x", `String "{{result_0.text}}-{{result_1.text}}")] };
    ] in
    match Workflow_engine.execute_step ctx step with
    | Ok (`List [_; _; third]) ->
      (match third with
       | `String s -> Alcotest.(check string) "indexed results" "first-second" s
       | _ -> Alcotest.fail "expected string")
    | Ok other -> Alcotest.failf "unexpected: %s"
                   (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "unexpected error: %s" (error_to_string e))

(* -------------------------------------------------------------------------- *)
(* Suite wiring                                                             *)
(* -------------------------------------------------------------------------- *)

let test_workflow_def_round_trips_yojson () =
  let def : workflow_def = {
    id = "rt-test";
    name = "Round Trip";
    version = 1;
    steps = Sequential [
      Agent_call { agent_id = "a"; prompt_template = "x"; response_schema = None };
      Tool_call { tool_name = "t"; input = `Assoc [] };
    ];
    variables = [("k", `String "v"); ("n", `Int 42)];
    failure_policy = Fail_fast;
    parallel_limit = 2;
    timeout = 60.0;
  } in
  let json = workflow_def_to_yojson def in
  (match workflow_def_of_yojson json with
   | Ok def' ->
     Alcotest.(check string) "id round-trips" def.id def'.id;
     Alcotest.(check string) "name round-trips" def.name def'.name;
     Alcotest.(check int) "version round-trips" def.version def'.version;
     Alcotest.(check int) "parallel_limit round-trips" def.parallel_limit def'.parallel_limit;
      Alcotest.(check (float 0.0001)) "timeout round-trips" def.timeout def'.timeout
   | Error e ->
     Alcotest.failf "workflow_def_of_yojson failed: %s" e)

(* -------------------------------------------------------------------------- *)
(* Response_schema (Agent_call schema-validated structured output)            *)
(* -------------------------------------------------------------------------- *)

(* A minimal JSON Schema for { "sentiment": "positive" | "negative" | "neutral" }. *)
let sentiment_schema : Yojson.Safe.t =
  `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("sentiment", `Assoc [
        ("type", `String "string");
        ("enum", `List [`String "positive"; `String "negative"; `String "neutral"]);
      ]);
    ]);
    ("required", `List [`String "sentiment"]);
    ("additionalProperties", `Bool false);
  ]

let test_agent_call_without_schema_unchanged () =
  (* Regression guard: when response_schema = None the execution path is
     identical to the pre-feature behaviour — only "text" and "tool_calls"
     are present in the result, no "output" key. *)
  let llm = mock_llm [text_response "hello world"] in
  let agent = basic_agent () in
  with_token (fun token ->
    let reg = make_registry [] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~token ~llm ~registry:reg () in
    let step = Agent_call { agent_id = "test-agent"; prompt_template = "hi"; response_schema = None } in
    match Workflow_engine.execute_step ctx step with
    | Ok (`Assoc fields) ->
      (match List.assoc_opt "output" fields with
       | None -> Alcotest.(check bool) "no output key (regression guard)" true true
       | Some v -> Alcotest.failf "unexpected output key: %s" (Yojson.Safe.to_string v));
      (match List.assoc_opt "text" fields with
       | Some (`String s) -> Alcotest.(check string) "text preserved" "hello world" s
       | _ -> Alcotest.failf "missing text field, got: %s"
                (Yojson.Safe.to_string (`Assoc fields)))
    | Ok other -> Alcotest.failf "expected Assoc, got %s" (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_agent_call_with_schema_happy_path () =
  (* Agent_call with response_schema = Some: the LLM returns text that
     contains a JSON object matching the schema, run_structured extracts
     and validates it, and the validated JSON is surfaced as "output". *)
  let valid_json = `Assoc [("sentiment", `String "positive")] in
  let llm = mock_llm [text_response (Yojson.Safe.to_string valid_json)] in
  let agent = basic_agent () in
  with_token (fun token ->
    let reg = make_registry [] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~token ~llm ~registry:reg () in
    let step = Agent_call {
      agent_id = "test-agent";
      prompt_template = "Classify: {{text}}";
      response_schema = Some sentiment_schema;
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok (`Assoc fields) ->
      (match List.assoc_opt "output" fields with
       | Some (`Assoc [("sentiment", `String s)]) ->
         Alcotest.(check string) "output.sentiment" "positive" s
       | Some v -> Alcotest.failf "output has wrong shape: %s" (Yojson.Safe.to_string v)
       | None -> Alcotest.failf "output key missing, got: %s"
                   (Yojson.Safe.to_string (`Assoc fields)))
    | Ok other -> Alcotest.failf "expected Assoc, got %s" (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok, got: %s" (error_to_string e))

let test_agent_call_with_schema_repair_loop () =
  (* First LLM call returns prose (no JSON), second returns valid JSON.
     The run_structured repair loop should kick in: a JSON-parse error
     triggers a repair feedback message and a retry. *)
  let valid_json = `Assoc [("sentiment", `String "negative")] in
  let llm = mock_llm [
    text_response "I'm not sure, let me think...";
    text_response (Yojson.Safe.to_string valid_json);
  ] in
  let agent = basic_agent () in
  with_token (fun token ->
    let reg = make_registry [] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~token ~llm ~registry:reg () in
    let step = Agent_call {
      agent_id = "test-agent";
      prompt_template = "x";
      response_schema = Some sentiment_schema;
    } in
    match Workflow_engine.execute_step ctx step with
    | Ok (`Assoc fields) ->
      (match List.assoc_opt "output" fields with
       | Some (`Assoc [("sentiment", `String s)]) ->
         Alcotest.(check string) "repair succeeded on attempt 2" "negative" s
       | Some v -> Alcotest.failf "output wrong shape: %s" (Yojson.Safe.to_string v)
       | None -> Alcotest.failf "output key missing")
    | Ok other -> Alcotest.failf "expected Assoc, got %s" (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok (repair loop should have succeeded): %s"
                   (error_to_string e))

let test_conditional_references_schema_output_dot_path () =
  (* End-to-end: a Sequential of [Agent_call (with schema); Conditional]
     where the Condition reads result.output.sentiment via dot-path.
     The dot-path resolve_path in expression.ml must drill into the
     nested JSON object that run_structured produces. *)
  let valid_json = `Assoc [("sentiment", `String "positive")] in
  let llm = mock_llm [
    text_response (Yojson.Safe.to_string valid_json);
    text_response "branch: pos";
    text_response "branch: pos";
    text_response "branch: pos";
  ] in
  let agent = basic_agent () in
  (* A Conditional that picks "pos" when sentiment == "positive", else "neg". *)
  let condition_step : workflow_step = Conditional {
    condition = Equals (
      Variable "result.output.sentiment",
      Literal (`String "positive")
    );
    then_step = Agent_call {
      agent_id = "test-agent";
      prompt_template = "branch: pos";
      response_schema = None;
    };
    else_step = Some (Agent_call {
      agent_id = "test-agent";
      prompt_template = "branch: neg";
      response_schema = None;
    });
  }
  in
  with_token (fun token ->
    let reg = make_registry [] in
    let ctx = make_ctx
      ~agent_resolver:(fun _ -> Some agent)
      ~token ~llm ~registry:reg () in
    let step = Sequential [
      Agent_call {
        agent_id = "test-agent";
        prompt_template = "classify";
        response_schema = Some sentiment_schema;
      };
      condition_step;
    ] in
    match Workflow_engine.execute_step ctx step with
    | Ok (`List [first; second]) ->
      (match first with
       | `Assoc first_fields ->
         (match List.assoc_opt "output" first_fields with
          | Some _ -> ()
          | None -> Alcotest.failf "first step missing output: %s"
                      (Yojson.Safe.to_string first))
       | _ -> Alcotest.failf "first step not an Assoc: %s"
                (Yojson.Safe.to_string first));
      (match second with
       | `Assoc fields ->
         (match List.assoc_opt "text" fields with
          | Some (`String s) ->
            Alcotest.(check string) "conditional picked 'pos' branch"
              "branch: pos" s
          | _ -> Alcotest.failf "expected text from pos branch, got: %s"
                   (Yojson.Safe.to_string second))
       | _ -> Alcotest.failf "expected Assoc from pos branch, got: %s"
                (Yojson.Safe.to_string second))
    | Ok other -> Alcotest.failf "expected List, got %s" (Yojson.Safe.to_string other)
    | Error e -> Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_workflow_step_yojson_backward_compat () =
  (* Verifies the [@deriving.yojson.default None] attribute: existing 2-field
     Agent_call JSON (no response_schema key) decodes successfully. *)
  let json = `List [
    `String "Agent_call";
    `Assoc [
      ("agent_id", `String "default-agent");
      ("prompt_template", `String "hello");
    ]
  ] in
  match workflow_step_of_yojson json with
  | Ok (Agent_call { agent_id; prompt_template; response_schema }) ->
    Alcotest.(check string) "agent_id round-trips" "default-agent" agent_id;
    Alcotest.(check string) "prompt round-trips" "hello" prompt_template;
    Alcotest.(check bool) "response_schema defaults to None"
      true (response_schema = None)
  | Ok _ -> Alcotest.fail "expected Agent_call variant"
  | Error e -> Alcotest.failf "backward-compat decode failed: %s" e

let test_workflow_step_yojson_with_response_schema () =
  (* Forward compat: 3-field Agent_call JSON with response_schema decodes. *)
  let json = `List [
    `String "Agent_call";
    `Assoc [
      ("agent_id", `String "a");
      ("prompt_template", `String "p");
      ("response_schema", sentiment_schema);
    ]
  ] in
  match workflow_step_of_yojson json with
  | Ok (Agent_call { agent_id; prompt_template; response_schema }) ->
    Alcotest.(check string) "agent_id" "a" agent_id;
    Alcotest.(check string) "prompt" "p" prompt_template;
    Alcotest.(check bool) "response_schema present"
      true (Option.is_some response_schema)
  | Ok _ -> Alcotest.fail "expected Agent_call variant"
  | Error e -> Alcotest.failf "decode failed: %s" e

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
      Alcotest.test_case "propagates result to next step" `Quick
        test_sequential_propagates_result_to_next_step;
      Alcotest.test_case "propagates indexed results" `Quick
        test_sequential_propagates_indexed_results;
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
      Alcotest.test_case "with allowed_roles round-trips" `Quick
        test_checkpoint_with_allowed_roles_round_trips;
      Alcotest.test_case "none allowed_roles round-trips" `Quick
        test_checkpoint_none_allowed_roles_round_trips;
      Alcotest.test_case "resume uses loaded checkpoint variables" `Quick
        test_checkpoint_resume_uses_loaded_checkpoint;
      Alcotest.test_case "step_path tracks nested position" `Quick
        test_step_path_tracks_nested_position;
    ]);
    ("Resume from checkpoint", [
      Alcotest.test_case "sequential: runs step after approval" `Quick
        test_resume_sequential_after_approval_runs_remaining_steps;
      Alcotest.test_case "restores variables from checkpoint" `Quick
        test_resume_restores_variables_from_checkpoint;
      Alcotest.test_case "nested sequential drops into inner branch" `Quick
        test_resume_nested_sequential_drops_into_inner_branch;
      Alcotest.test_case "conditional true branch runs after approval" `Quick
        test_resume_conditional_true_branch_runs_after_approval;
      Alcotest.test_case "rejects Parallel at step_path" `Quick
        test_resume_rejects_parallel_at_step_path;
      Alcotest.test_case "invalid step_path returns error" `Quick
        test_resume_invalid_step_path_returns_error;
      Alcotest.test_case "runtime.resume_workflow end-to-end" `Quick
        test_resume_runtime_runs_remaining_tool_calls;
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
      Alcotest.test_case "cancel emits Workflow_failed event + rejects unknown" `Quick
        test_cancel_emits_workflow_failed_event;
    ]);
    ("Approve role validation", [
      Alcotest.test_case "allowed_roles accepts authorized approver" `Quick
        test_approve_validates_allowed_roles_allows_authorized;
      Alcotest.test_case "allowed_roles rejects unauthorized approver" `Quick
        test_approve_validates_allowed_roles_rejects_unauthorized;
    ]);
    ("Rehydration", [
      Alcotest.test_case "restores suspended runs after restart" `Quick
        test_rehydration_restores_suspended_workflows;
      Alcotest.test_case "resume works after restart without re-register" `Quick
        test_rehydration_resume_works_after_restart;
      Alcotest.test_case "empty db hydrates zero runs" `Quick
        test_rehydration_empty_db_returns_no_runs;
    ]);
    ("Workflow lifecycle events", [
      Alcotest.test_case "submit emits started/completed/step" `Quick
        test_submit_emits_workflow_started_and_completed;
      Alcotest.test_case "submit failure emits Workflow_failed" `Quick
        test_submit_failure_emits_workflow_failed;
      Alcotest.test_case "suspend emits Approval_requested" `Quick
        test_suspended_submit_emits_approval_requested;
      Alcotest.test_case "approve emits Approval_granted" `Quick
        test_approve_emits_approval_granted;
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
      Alcotest.test_case "tool input deep nested substitution" `Quick
        test_tool_input_deep_nested_substitution;
      Alcotest.test_case "agent call preserves tool_calls" `Quick
        test_agent_call_preserves_tool_calls;
    ]);
    ("Response_schema (Agent_call)", [
      Alcotest.test_case "without schema: unchanged behaviour (regression guard)" `Quick
        test_agent_call_without_schema_unchanged;
      Alcotest.test_case "with schema: validated JSON in result.output" `Quick
        test_agent_call_with_schema_happy_path;
      Alcotest.test_case "with schema + invalid LLM output: repair loop succeeds" `Quick
        test_agent_call_with_schema_repair_loop;
      Alcotest.test_case "Conditional reads result.output.<field> via dot-path" `Quick
        test_conditional_references_schema_output_dot_path;
    ]);
    ("Serialization", [
      Alcotest.test_case "workflow_def yojson round-trips" `Quick
        test_workflow_def_round_trips_yojson;
      Alcotest.test_case "workflow_step 2-field JSON decodes (backward compat)" `Quick
        test_workflow_step_yojson_backward_compat;
      Alcotest.test_case "workflow_step 3-field JSON decodes (with response_schema)" `Quick
        test_workflow_step_yojson_with_response_schema;
    ]);
  ]
