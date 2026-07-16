open Par
open Types

let show_error (e : error_category) = match e with
  | Timeout -> "Timeout"
  | Invalid_input s -> "Invalid_input: " ^ s
  | External_failure s -> "External_failure: " ^ s
  | Rate_limited -> "Rate_limited"
  | Permission_denied s -> "Permission_denied: " ^ s
  | Internal s -> "Internal: " ^ s
  | Embedding_unsupported -> "Embedding_unsupported"

let test_hnsw_backend_via_vector_store () =
  Eio_main.run (fun _env ->
    let dim = 64 in
    match Vector_store.create_for_backend (Vs_hnsw {
      persist_path = None; dimension = dim;
      m = 16; ef_construction = 200; ef_search = 50;
    }) with
    | Error e -> Alcotest.failf "create_for_backend failed: %s" (show_error e)
    | Ok vs ->
      let docs = [
        ({ Vector_store.id = "doc1"; content = "hello world"; metadata = None },
         Array.init dim (fun i -> if i = 0 then 1.0 else 0.0));
        ({ Vector_store.id = "doc2"; content = "foo bar"; metadata = None },
         Array.init dim (fun i -> if i = 1 then 1.0 else 0.0));
        ({ Vector_store.id = "doc3"; content = "hello again"; metadata = None },
         Array.init dim (fun i -> if i = 0 then 0.9 else if i = 1 then 0.1 else 0.0));
      ] in
      (match Vector_store.add vs docs with
       | Error e -> Alcotest.failf "add failed: %s" (show_error e)
       | Ok () -> ());
      let query = Array.init dim (fun i -> if i = 0 then 1.0 else 0.0) in
      (match Vector_store.search vs ~query ~k:2 with
       | Error e -> Alcotest.failf "search failed: %s" (show_error e)
       | Ok results ->
         Alcotest.(check int) "returns 2 results" 2 (List.length results));
      (match Vector_store.delete vs ~ids:["doc1"] with
       | Error e -> Alcotest.failf "delete failed: %s" (show_error e)
       | Ok () -> ());
      (match Vector_store.search vs ~query ~k:3 with
       | Error e -> Alcotest.failf "search after delete failed: %s" (show_error e)
       | Ok results ->
         let ids = List.map (fun r -> r.Vector_store.doc.Vector_store.id) results in
         Alcotest.(check bool) "doc1 deleted" false (List.mem "doc1" ids));
      Vector_store.close vs)

let test_hnsw_backend_with_metadata () =
  Eio_main.run (fun _env ->
    let dim = 32 in
    match Vector_store.create_for_backend (Vs_hnsw {
      persist_path = None; dimension = dim;
      m = 8; ef_construction = 100; ef_search = 30;
    }) with
    | Error e -> Alcotest.failf "create failed: %s" (show_error e)
    | Ok vs ->
      let meta = `Assoc [("key", `String "value")] in
      let docs = [
        ({ Vector_store.id = "m1"; content = "with metadata"; metadata = Some meta },
         Array.init dim (fun i -> if i = 0 then 1.0 else 0.0));
      ] in
      (match Vector_store.add vs docs with
       | Error e -> Alcotest.failf "add failed: %s" (show_error e)
       | Ok () -> ());
      let query = Array.init dim (fun i -> if i = 0 then 1.0 else 0.0) in
      (match Vector_store.search vs ~query ~k:1 with
       | Error e -> Alcotest.failf "search failed: %s" (show_error e)
       | Ok results ->
         Alcotest.(check int) "1 result" 1 (List.length results));
      Vector_store.close vs)

let () =
  Alcotest.run "in_memory_vector_store" [
    ("hnsw_backend", [
      Alcotest.test_case "add/search/delete via Vector_store" `Quick
        test_hnsw_backend_via_vector_store;
      Alcotest.test_case "metadata preserved" `Quick
        test_hnsw_backend_with_metadata;
    ]);
  ]
