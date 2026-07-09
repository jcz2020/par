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

let vec_extension =
  let candidates = [
    "/root/dev/PAR/vendor/sqlite-vec/linux-x86_64/vec0.so";
    Sys.getcwd () ^ "/vendor/sqlite-vec/linux-x86_64/vec0.so";
    "vec0.so";
  ] in
  try List.find Sys.file_exists candidates with _ -> "vec0.so"

let test_pdf_loader_to_vector_store () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let (embed_svc, _) = Mock_provider.mock_embed_service () in
      let rt =
        match Runtime.create ~config:test_config ~embeddings:embed_svc sw with
        | Error e -> Alcotest.failf "Runtime.create failed: %s" (show_error e)
        | Ok r -> r
      in
      let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
      let docs =
        match Pdf_loader.make ws "sample.pdf" with
        | Error e -> Alcotest.failf "Pdf_loader: %s" (Document.load_error_to_string e)
        | Ok f -> f ()
      in
      Alcotest.(check int) "2 pages loaded" 2 (List.length docs);
      let chunks = List.concat_map (fun d ->
        Chunking.chunk_by_chars ~text:d.Document.content ~max_size:500 ~overlap:50
      ) docs in
      Alcotest.(check bool) "at least 1 chunk" true (List.length chunks > 0);
      let vectors =
        match Runtime.embed rt (List.map (fun c -> c.Chunking.text) chunks) with
        | Error e -> Alcotest.failf "embed: %s" (show_error e)
        | Ok v -> v
      in
      Alcotest.(check int) "one vector per chunk" (List.length chunks) (List.length vectors);
      let vs =
        match Vector_store.create ~db_path:":memory:" ~vec_extension_path:vec_extension ~dimension:1536 () with
        | Error e -> Alcotest.failf "Vector_store.create: %s" (show_error e)
        | Ok s -> s
      in
      let vs_docs =
        List.mapi (fun i (chunk, vec) ->
          let doc : Vector_store.document =
            { id = Printf.sprintf "chunk_%d" i;
              content = chunk.Chunking.text;
              metadata = Some (`Assoc [("source", `String "sample.pdf")]) }
          in
          (doc, vec)
        ) (List.combine chunks vectors)
      in
      (match Vector_store.add vs vs_docs with
       | Error e -> Alcotest.failf "add: %s" (show_error e)
       | Ok () -> ());
      let mock_query =
        match embed_svc.embed_fn ["PAR"] with
        | Ok [v] -> v
        | _ -> Array.make 1536 0.0
      in
      (match Vector_store.search vs ~query:mock_query ~k:3 with
       | Error e -> Alcotest.failf "search: %s" (show_error e)
       | Ok results ->
         Alcotest.(check bool) "non-empty results" true (List.length results > 0));
      Vector_store.close vs;
      ignore (Runtime.close rt)
    )
  )

let () =
  Alcotest.run "document_loaders_e2e" [
    ("e2e", [
      Alcotest.test_case "PDF to chunk to embed to store to retrieve" `Quick
        test_pdf_loader_to_vector_store;
    ]);
  ]
