open Par
open Types

let error_to_string (e : error_category) =
  match e with
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"
  | Cancelled _ -> "Cancelled"

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

let make_tool ?(description = "A test tool") name =
  { name; description; input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
      ("required", `List []);
    ];
    output_schema = None; permission = Allow; timeout = None;
    concurrency_limit = None; on_update = None; cache_control = None }

let dummy_handler _input _token = Success (`Assoc [("ok", `Bool true)])

let make_registry tools =
  let reg = Tool_registry.create () in
  List.iter (fun (d, h) ->
    ignore (Tool_registry.register reg d h)
  ) tools;
  reg

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let basic_agent ?(tools = []) () =
  let descriptors = List.map fst tools in
  { id = "test-agent";
    system_prompt = stable_prompt "You are a test agent.";
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

let test_registry_layer_default () =
  let d = make_tool "alpha" in
  let reg = Tool_registry.create () in
  ignore (Tool_registry.register reg d dummy_handler);
  let descs = Tool_registry.searchable_descriptors reg in
  Alcotest.(check int) "default is Always, not searchable" 0 (List.length descs)

let test_register_searchable () =
  let d = make_tool "beta" in
  let reg = Tool_registry.create () in
  ignore (Tool_registry.register_searchable reg d dummy_handler);
  let descs = Tool_registry.searchable_descriptors reg in
  Alcotest.(check int) "one searchable" 1 (List.length descs);
  Alcotest.(check string) "name matches" "beta" (List.hd descs).name

let test_set_layer () =
  let d = make_tool "gamma" in
  let reg = Tool_registry.create () in
  ignore (Tool_registry.register reg d dummy_handler);
  Alcotest.(check int) "before: 0 searchable" 0
    (List.length (Tool_registry.searchable_descriptors reg));
  Tool_registry.set_layer reg "gamma" Tool_registry.Searchable;
  Alcotest.(check int) "after: 1 searchable" 1
    (List.length (Tool_registry.searchable_descriptors reg));
  Tool_registry.set_layer reg "gamma" Tool_registry.Always;
  Alcotest.(check int) "reverted: 0 searchable" 0
    (List.length (Tool_registry.searchable_descriptors reg))

let test_copy_all_preserves_layers () =
  let d1 = make_tool "always_tool" in
  let d2 = make_tool "searchable_tool" in
  let src = Tool_registry.create () in
  ignore (Tool_registry.register src d1 dummy_handler);
  ignore (Tool_registry.register_searchable src d2 dummy_handler);
  let dst = Tool_registry.create () in
  Tool_registry.copy_all ~src ~dst;
  let searchable = Tool_registry.searchable_descriptors dst in
  Alcotest.(check int) "searchable copied" 1 (List.length searchable);
  Alcotest.(check string) "name" "searchable_tool" (List.hd searchable).name

let test_estimate_tokens_empty () =
  let est = Tool_budget.estimate_tokens [] in
  Alcotest.(check int) "empty = 0" 0 est

let test_estimate_tokens_basic () =
  let d = make_tool ~description:"A tool with a description" "test_tool" in
  let est = Tool_budget.estimate_tokens [d] in
  Alcotest.(check bool) "positive estimate" true (est > 0)

let test_estimate_tokens_multiple () =
  let d1 = make_tool ~description:"tool one" "alpha" in
  let d2 = make_tool ~description:"tool two" "beta" in
  let est1 = Tool_budget.estimate_tokens [d1] in
  let est2 = Tool_budget.estimate_tokens [d1; d2] in
  Alcotest.(check bool) "more tools = more tokens" true (est2 > est1)

let test_search_basic () =
  let d1 = make_tool ~description:"Read files from disk" "read_file" in
  let d2 = make_tool ~description:"Write files to disk" "write_file" in
  let d3 = make_tool ~description:"Search the web" "web_search" in
  let results = Tool_search.search ~query:"file" ~category:None [d1; d2; d3] in
  Alcotest.(check int) "2 file tools" 2 (List.length results);
  let names = List.map (fun (d : tool_descriptor) -> d.name) results in
  Alcotest.(check bool) "has read_file" true (List.mem "read_file" names);
  Alcotest.(check bool) "has write_file" true (List.mem "write_file" names)

let test_search_name_weight () =
  let d1 = make_tool ~description:"A generic tool" "web_search" in
  let d2 = make_tool ~description:"Search the web for results" "helper" in
  let results = Tool_search.search ~query:"search" ~category:None [d1; d2] in
  Alcotest.(check bool) "name match ranked higher" true
    (List.length results >= 1 && (List.hd results).name = "web_search")

let test_search_category_filter () =
  let d1 = make_tool ~description:"Read files" "read_file" in
  let d2 = make_tool ~description:"Search the web" "web_search" in
  let results = Tool_search.search ~query:"search" ~category:(Some "web") [d1; d2] in
  Alcotest.(check int) "1 web tool" 1 (List.length results);
  Alcotest.(check string) "web_search" "web_search" (List.hd results).name

let test_search_no_match () =
  let d1 = make_tool ~description:"Read files" "read_file" in
  let results = Tool_search.search ~query:"xyz_nonexistent" ~category:None [d1] in
  Alcotest.(check int) "no match" 0 (List.length results)

let test_promote_tools () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      ignore token;
      let d = make_tool "promoted_tool" in
      let ctx = Invoke_context.create ~session_id:"test" () in
      Invoke_context.with_context ctx (fun () ->
        Alcotest.(check int) "initial: 0 promoted" 0
          (List.length !(ctx.promoted_tools));
        Invoke_context.promote_tools [d];
        Alcotest.(check int) "after: 1 promoted" 1
          (List.length !(ctx.promoted_tools));
        Alcotest.(check string) "name" "promoted_tool"
          (List.hd !(ctx.promoted_tools)).name)))

let test_promote_dedup () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      ignore token;
      let d = make_tool "dup_tool" in
      let ctx = Invoke_context.create ~session_id:"test" () in
      Invoke_context.with_context ctx (fun () ->
        Invoke_context.promote_tools [d];
        Invoke_context.promote_tools [d];
        Alcotest.(check int) "dedup: still 1" 1
          (List.length !(ctx.promoted_tools)))))

let test_budget_threshold_none_no_change () =
  with_token (fun token ->
    let tools = [
      (make_tool ~description:"tool alpha" "alpha", dummy_handler);
      (make_tool ~description:"tool beta" "beta", dummy_handler);
    ] in
    let agent = basic_agent ~tools () in
    let llm = {
      complete_fn = (fun _model llm_tools _conv ->
        Alcotest.(check int) "all tools visible" 2 (List.length llm_tools);
        Ok (stop_response "done"));
      stream_fn = (fun _ _ _ _ _ -> Ok { final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
      close_fn = ignore;
      complete_structured_fn = None; list_models_fn = None;
      supports_native_tools_fn = None; context_window_fn = None;
      cache_control_fn = None;
    } in
    let reg = make_registry tools in
    match Engine.run_agent token agent "hi" llm reg with
    | Ok _ -> ()
    | Error (e, _) -> Alcotest.failf "unexpected error: %s"
        (error_to_string e))

let test_budget_threshold_exceeded () =
  with_token (fun token ->
    let tool_desc = make_tool ~description:(String.make 5000 'x') "big_tool" in
    let tools = [(tool_desc, dummy_handler)] in
    let agent = basic_agent ~tools () in
    let seen_tool_names = ref [] in
    let llm = {
      complete_fn = (fun _model llm_tools _conv ->
        seen_tool_names := List.map (fun (d : tool_descriptor) -> d.name) llm_tools;
        Ok (stop_response "done"));
      stream_fn = (fun _ _ _ _ _ -> Ok { final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
      close_fn = ignore;
      complete_structured_fn = None; list_models_fn = None;
      supports_native_tools_fn = None; context_window_fn = None;
      cache_control_fn = None;
    } in
    let reg = make_registry tools in
    ignore (Tool_registry.register_searchable reg tool_desc dummy_handler);
    ignore (Tool_registry.register_searchable reg Tool_search.descriptor
      (Tool_search.make_handler reg));
    match Engine.run_agent ~budget_threshold:100 token agent "hi" llm reg with
    | Ok _ ->
      Alcotest.(check bool) "tool_search present in progressive mode"
        true (List.mem "tool_search" !seen_tool_names)
    | Error (e, _) -> Alcotest.failf "unexpected error: %s"
        (error_to_string e))

let () =
  let open Alcotest in
  run "Tool Search" [
    "registry_layer", [
      test_case "default layer is Always" `Quick test_registry_layer_default;
      test_case "register_searchable" `Quick test_register_searchable;
      test_case "set_layer" `Quick test_set_layer;
      test_case "copy_all preserves layers" `Quick test_copy_all_preserves_layers;
    ];
    "budget", [
      test_case "estimate empty" `Quick test_estimate_tokens_empty;
      test_case "estimate basic" `Quick test_estimate_tokens_basic;
      test_case "estimate multiple" `Quick test_estimate_tokens_multiple;
    ];
    "search", [
      test_case "basic keyword search" `Quick test_search_basic;
      test_case "name weighted higher" `Quick test_search_name_weight;
      test_case "category filter" `Quick test_search_category_filter;
      test_case "no match" `Quick test_search_no_match;
    ];
    "promotion", [
      test_case "promote_tools" `Quick test_promote_tools;
      test_case "dedup on re-promote" `Quick test_promote_dedup;
    ];
    "engine_integration", [
      test_case "budget None = all tools visible" `Quick test_budget_threshold_none_no_change;
      test_case "budget exceeded = progressive mode" `Quick test_budget_threshold_exceeded;
    ];
  ]
