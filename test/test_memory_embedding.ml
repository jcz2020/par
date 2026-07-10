let vec0_available =
  let db = Sqlite3.db_open ":memory:" in
  let r = Sqlite3.enable_load_extension db true in
  ignore (Sqlite3.db_close db);
  r

let () =
  if not vec0_available then begin
    print_endline "[SKIP] SQLite load_extension not available on this platform";
    exit 0
  end
open Par_memory

let db_path = ":memory:"

let mock_embedding dim : Memory_service.embedding_fn =
  fun texts ->
    Ok (List.map (fun _ ->
      Array.init dim (fun i -> float_of_int (i mod 10) /. 10.0)
    ) texts)

let failing_embedding : Memory_service.embedding_fn =
  fun _texts -> Error "mock embedding failure"

let vec_row_count (t : Sqlite_memory.t) =
  let stmt =
    Sqlite3.prepare t.db
      "SELECT count(*) FROM memory_entries_vec"
  in
  let count =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      (match Sqlite3.column stmt 0 with
       | Sqlite3.Data.INT n -> Int64.to_int n
       | _ -> 0)
    | _ -> 0
  in
  let _ = Sqlite3.finalize stmt in
  count

let test_add_with_embedding_inserts_vec () =
  let embed_fn = mock_embedding 1536 in
  match Sqlite_memory.create ~embedding_fn:embed_fn db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"OCaml is a great language"
          ~scope:"proj" () in
    let count = vec_row_count t in
    Alcotest.(check int) "vec0 has 1 embedding" 1 count;
    Sqlite_memory.close t

let test_add_without_embedding_skips_vec () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"OCaml is a great language"
          ~scope:"proj" () in
    let count = vec_row_count t in
    Alcotest.(check int) "vec0 stays empty" 0 count;
    Sqlite_memory.close t

let test_embedding_failure_graceful () =
  match Sqlite_memory.create ~embedding_fn:failing_embedding db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    (match Sqlite_memory.add t ~content:"test graceful failure" ~scope:"proj" () with
     | Error e -> Alcotest.failf "add should succeed despite embedding failure: %s"
                    (Memory_error.to_string e)
     | Ok m ->
       Alcotest.(check string) "content preserved" "test graceful failure" m.content);
    let count = vec_row_count t in
    Alcotest.(check int) "vec0 empty after failed embed" 0 count;
    Sqlite_memory.close t

let test_keyword_only_without_embedding () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"OCaml is statically typed"
          ~scope:"proj" () in
    (match Sqlite_memory.search t ~mode:Keyword_only ~scope:"proj" "OCaml" with
     | Error e -> Alcotest.failf "search: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "found 1" 1 (List.length results));
    Sqlite_memory.close t

let test_vector_only_requires_embedding () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    (match Sqlite_memory.search t ~mode:Vector_only "query" with
     | Error Memory_error.Embedding_unavailable -> ()
     | Error e -> Alcotest.failf "wrong error: %s" (Memory_error.to_string e)
     | Ok _ -> Alcotest.fail "should have failed without embedding");
    Sqlite_memory.close t

let test_auto_hybrid_when_embedding_available () =
  let embed_fn = mock_embedding 1536 in
  match Sqlite_memory.create ~embedding_fn:embed_fn db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"OCaml is a great language"
          ~scope:"proj" () in
    (match Sqlite_memory.search t ~scope:"proj" "OCaml" with
     | Error e -> Alcotest.failf "search auto: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check bool) "found results" true (List.length results > 0));
    Sqlite_memory.close t

let test_auto_keyword_only_when_no_embedding () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"OCaml is a great language"
          ~scope:"proj" () in
    (match Sqlite_memory.search t ~scope:"proj" "OCaml" with
     | Error e -> Alcotest.failf "search auto: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "found 1" 1 (List.length results));
    Sqlite_memory.close t

let test_hybrid_fallback_to_fts_on_embed_error () =
  match Sqlite_memory.create ~embedding_fn:failing_embedding db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"OCaml is statically typed"
          ~scope:"proj" () in
    (match Sqlite_memory.search t ~mode:Hybrid ~scope:"proj" "OCaml" with
     | Error e -> Alcotest.failf "hybrid fallback: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "found via fts fallback" 1 (List.length results));
    Sqlite_memory.close t

let test_make_service_with_embedding () =
  let embed_fn = mock_embedding 1536 in
  match Sqlite_memory.make_service ~embedding_fn:embed_fn db_path with
  | Error e -> Alcotest.failf "make_service: %s" (Memory_error.to_string e)
  | Ok svc ->
    let _ = svc.Memory_service.add_fn ~content:"test embedding via service"
          ~scope:"proj" () in
    (match svc.Memory_service.search_fn ~scope:"proj" "embedding" with
     | Error e -> Alcotest.failf "search: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check bool) "found via service" true (List.length results > 0));
    svc.Memory_service.close_fn ()

let test_embedding_field_present () =
  let embed_fn = mock_embedding 768 in
  match Sqlite_memory.create ~dimension:768 ~embedding_fn:embed_fn db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    Alcotest.(check bool) "embedding is Some" true
      (Option.is_some t.Sqlite_memory.embedding);
    Sqlite_memory.close t

let test_no_embedding_field_when_absent () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    Alcotest.(check bool) "embedding is None" true
      (Option.is_none t.Sqlite_memory.embedding);
    Sqlite_memory.close t

let () =
  Eio_main.run (fun _env ->
    Alcotest.run "memory_embedding" [
      ("vec_insert", [
         Alcotest.test_case "add with embedding inserts vec" `Quick
           test_add_with_embedding_inserts_vec;
         Alcotest.test_case "add without embedding skips vec" `Quick
           test_add_without_embedding_skips_vec;
         Alcotest.test_case "embedding failure is graceful" `Quick
           test_embedding_failure_graceful;
       ]);
      ("search_mode", [
         Alcotest.test_case "keyword_only works without embedding" `Quick
           test_keyword_only_without_embedding;
         Alcotest.test_case "vector_only requires embedding" `Quick
           test_vector_only_requires_embedding;
         Alcotest.test_case "auto picks hybrid when available" `Quick
           test_auto_hybrid_when_embedding_available;
         Alcotest.test_case "auto picks keyword when unavailable" `Quick
           test_auto_keyword_only_when_no_embedding;
         Alcotest.test_case "hybrid falls back to fts on embed error" `Quick
           test_hybrid_fallback_to_fts_on_embed_error;
       ]);
      ("service", [
         Alcotest.test_case "make_service with embedding" `Quick
           test_make_service_with_embedding;
       ]);
      ("record", [
         Alcotest.test_case "embedding field present" `Quick
           test_embedding_field_present;
         Alcotest.test_case "embedding field absent" `Quick
           test_no_embedding_field_when_absent;
       ]);
    ])
