open Par
open Types

let show_error : error_category -> string = function
  | Timeout -> "Timeout"
  | Invalid_input s -> "Invalid_input: " ^ s
  | External_failure s -> "External_failure: " ^ s
  | Rate_limited -> "Rate_limited"
  | Permission_denied s -> "Permission_denied: " ^ s
  | Internal s -> "Internal: " ^ s
  | Embedding_unsupported -> "Embedding_unsupported"

let vector_has_dim dim vec =
  Alcotest.(check int) "vector dimension" dim (Array.length vec)

let test_mock_embed_single () =
  let (svc, _history) = Mock_provider.mock_embed_service () in
  match svc.embed_fn ["hello"] with
  | Ok [v] -> vector_has_dim 1536 v
  | Ok other -> Alcotest.failf "expected one vector, got %d" (List.length other)
  | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)

let test_mock_embed_batch () =
  let (svc, _history) = Mock_provider.mock_embed_service () in
  match svc.embed_fn ["a"; "b"] with
  | Ok vs ->
    Alcotest.(check int) "two vectors" 2 (List.length vs);
    List.iter (fun v -> vector_has_dim 1536 v) vs
  | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)

let test_mock_embed_deterministic () =
  let (svc, _history) = Mock_provider.mock_embed_service () in
  match svc.embed_fn ["same"], svc.embed_fn ["same"] with
  | Ok [a], Ok [b] ->
    Alcotest.(check (array (float 1e-9))) "same input same vector" a b
  | _ -> Alcotest.fail "expected matching vectors"

let test_mock_embed_history_records_calls () =
  let (svc, history) = Mock_provider.mock_embed_service () in
  Alcotest.(check int) "no calls yet" 0 (Mock_provider.embed_call_count history);
  ignore (svc.embed_fn ["first"]);
  Alcotest.(check int) "one call" 1 (Mock_provider.embed_call_count history);
  ignore (svc.embed_fn ["second"; "third"]);
  Alcotest.(check int) "two calls" 2 (Mock_provider.embed_call_count history);
  match Mock_provider.last_embed_call history with
  | Some record ->
    Alcotest.(check int) "last call inputs" 2 (List.length record.Mock_provider.inputs)
  | None -> Alcotest.fail "expected last embed call"

let minimal_runtime_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = false;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 86400.0;
}

let test_runtime_embed_with_mock () =
  let (embed_svc, _history) = Mock_provider.mock_embed_service () in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun switch ->
      match Runtime.create ~embeddings:embed_svc ~config:minimal_runtime_config switch with
      | Ok rt ->
        (match Runtime.embed rt ["test"] with
         | Ok vs -> Alcotest.(check int) "one vector" 1 (List.length vs)
         | Error e -> Alcotest.failf "unexpected error: %s" (show_error e));
        ignore (Runtime.close rt)
      | Error e -> Alcotest.failf "runtime create failed: %s" (show_error e)))

let test_runtime_embed_without_service () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun switch ->
      match Runtime.create ~config:minimal_runtime_config switch with
      | Ok rt ->
        (match Runtime.embed rt ["test"] with
         | Ok _ -> Alcotest.fail "expected embeddings not initialized error"
         | Error (Internal msg) ->
           Alcotest.(check string) "error message"
             "Embeddings not initialized" msg
         | Error e -> Alcotest.failf "expected Internal, got %s" (show_error e));
        ignore (Runtime.close rt)
      | Error e -> Alcotest.failf "runtime create failed: %s" (show_error e)))

let test_openai_embed_parses_fixture () =
  let fixture =
    {|{"object":"list","data":[
      {"object":"embedding","index":0,"embedding":[0.1,0.2,0.3]},
      {"object":"embedding","index":1,"embedding":[0.4,0.5,0.6]}
    ],"usage":{"prompt_tokens":6,"total_tokens":6}}|}
  in
  let json = Yojson.Safe.from_string fixture in
  match Openai_provider.parse_embeddings_response json with
  | Ok vs ->
    Alcotest.(check int) "two vectors" 2 (List.length vs);
    (match vs with
     | [a; b] ->
       Alcotest.(check (array (float 1e-9))) "first vector" [|0.1;0.2;0.3|] a;
       Alcotest.(check (array (float 1e-9))) "second vector" [|0.4;0.5;0.6|] b
     | _ -> Alcotest.fail "expected exactly two vectors")
  | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)

let test_anthropic_embed_unsupported () =
  let cfg = Anthropic { api_key = "test-key"; base_url = None } in
  match Anthropic_provider.create cfg with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok t ->
    match Anthropic_provider.embed t ["hello"] with
    | Ok _ -> Alcotest.fail "expected Embedding_unsupported"
    | Error Embedding_unsupported -> ()
    | Error e -> Alcotest.failf "expected Embedding_unsupported, got %s" (show_error e)

let () =
  Alcotest.run "Embedding API" [
    "mock_embed", [
      Alcotest.test_case "single text returns 1536-dim vector" `Quick test_mock_embed_single;
      Alcotest.test_case "batch returns two vectors" `Quick test_mock_embed_batch;
      Alcotest.test_case "same input yields same vector" `Quick test_mock_embed_deterministic;
      Alcotest.test_case "history records every call" `Quick test_mock_embed_history_records_calls;
    ];
    "runtime_embed", [
      Alcotest.test_case "with mock service returns Ok" `Quick test_runtime_embed_with_mock;
      Alcotest.test_case "without service returns Internal error" `Quick test_runtime_embed_without_service;
    ];
    "openai_embed", [
      Alcotest.test_case "parses fixture JSON response" `Quick test_openai_embed_parses_fixture;
    ];
    "anthropic_embed", [
      Alcotest.test_case "returns Embedding_unsupported" `Quick test_anthropic_embed_unsupported;
    ];
  ]
