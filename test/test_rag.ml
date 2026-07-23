open Par
open Types

let show_error (e : error_category) : string = match e with
  | Timeout -> "Timeout"
  | Invalid_input s -> "Invalid_input: " ^ s
  | External_failure s -> "External_failure: " ^ s
  | Rate_limited -> "Rate_limited"
  | Permission_denied s -> "Permission_denied: " ^ s
  | Internal s -> "Internal: " ^ s
  | Embedding_unsupported -> "Embedding_unsupported"

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
}

let mock_model : model_config = {
  provider = `Openai;
  model_name = "mock";
  api_base = None;
  temperature = 0.0;
  max_tokens = Some 100;
  top_p = Some 1.0;
  stop_sequences = None;
}

let mock_agent =
  let id = "test_agent" in
  { id; system_prompt = stable_prompt "You are a test agent";
    system_prompt_template = None;
    model = mock_model;
    tools = [];
    max_iterations = 5;
    middleware = [];
    retry_policy = None;
    context_strategy = None;
    resource_quota = None; max_execution_time = None; tool_timeout = None; early_stopping_method = Force; on_max_tokens = Some Return_partial; max_continuation_chunks = Some 3;
    context_compression_threshold = None; compression_cooldown_messages = None; context_window_override = None; cache_strategy = No_caching }

let test_embed_returns_vectors () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let (embed_svc, _) = Mock_provider.mock_embed_service () in
      match Runtime.create ~config:test_config ~embeddings:embed_svc sw with
      | Error e -> Alcotest.failf "Runtime.create failed: %s" (show_error e)
      | Ok rt ->
        (match Runtime.embed rt ["hello"; "world"] with
         | Ok [v1; v2] ->
           Alcotest.(check int) "vector 1 dim" 1536 (Array.length v1);
           Alcotest.(check int) "vector 2 dim" 1536 (Array.length v2)
         | Ok other ->
           Alcotest.failf "expected 2 vectors, got %d" (List.length other)
         | Error e ->
           Alcotest.failf "embed failed: %s" (show_error e));
        ignore (Runtime.close rt)))

let test_rag_without_vector_store () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let (embed_svc, _) = Mock_provider.mock_embed_service () in
      let (llm_svc, _) = Mock_provider.create [Text "RAG answer"] in
      match Runtime.create ~config:test_config
              ~embeddings:embed_svc ~llm:llm_svc sw with
      | Error e -> Alcotest.failf "Runtime.create failed: %s" (show_error e)
      | Ok rt ->
        ignore (Runtime.register_agent rt mock_agent);
        (match Runtime.invoke_with_rag rt
                 ~agent_id:"test_agent" ~message:"What is PAR?" ~k:4 () with
         | Ok (_answer, docs) ->
           Alcotest.(check int) "no vector_store → 0 docs" 0 (List.length docs)
         | Error e ->
           Alcotest.failf "invoke_with_rag failed: %s" (show_error e));
        ignore (Runtime.close rt)))

let test_embed_deterministic () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let (embed_svc, _) = Mock_provider.mock_embed_service () in
      match Runtime.create ~config:test_config ~embeddings:embed_svc sw with
      | Error e -> Alcotest.failf "Runtime.create failed: %s" (show_error e)
      | Ok rt ->
        (match Runtime.embed rt ["same"; "same"] with
         | Ok [v1; v2] ->
            Alcotest.(check bool) "deterministic: same input → same output"
              true (Array.length v1 = Array.length v2
                    && Array.fold_left2 (fun a b acc -> acc && Float.equal a b) v1 v2 true)
         | _ -> Alcotest.fail "embed returned unexpected shape");
        ignore (Runtime.close rt)))

let () =
  Alcotest.run "rag integration" [
    ("embeddings", [
      Alcotest.test_case "mock embed returns 1536-dim vectors" `Quick
        (fun () -> test_embed_returns_vectors ());
      Alcotest.test_case "mock embed is deterministic" `Quick
        (fun () -> test_embed_deterministic ());
    ]);
    ("rag_orchestration", [
      Alcotest.test_case "invoke_with_rag without vector_store returns 0 docs" `Quick
        (fun () -> test_rag_without_vector_store ());
    ]);
  ]
