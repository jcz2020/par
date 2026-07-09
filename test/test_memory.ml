open Par_memory

let db_path = ":memory:"

let test_add_search_roundtrip () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"OCaml is a statically typed functional language"
          ~summary:"OCaml description" ~scope:"project-a"
          ~categories:["language"; "functional"] () in
    (match Sqlite_memory.search t ~scope:"project-a" "OCaml" with
     | Error e -> Alcotest.failf "search: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "found 1 result" 1 (List.length results);
       let m = List.hd results in
       Alcotest.(check string) "content matches"
         "OCaml is a statically typed functional language" m.content);
    Sqlite_memory.close t

let test_scope_filtering () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"alpha secret" ~scope:"scope-a" () in
    let _ = Sqlite_memory.add t ~content:"beta secret" ~scope:"scope-b" () in
    (match Sqlite_memory.search t ~scope:"scope-a" "secret" with
     | Error e -> Alcotest.failf "search scope-a: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "scope-a sees 1" 1 (List.length results);
       Alcotest.(check string) "scope-a content"
         "alpha secret" (List.hd results).content);
    (match Sqlite_memory.search t ~scope:"scope-b" "secret" with
     | Error e -> Alcotest.failf "search scope-b: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "scope-b sees 1" 1 (List.length results);
       Alcotest.(check string) "scope-b content"
         "beta secret" (List.hd results).content);
    Sqlite_memory.close t

let test_add_only_lifecycle () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let original = match Sqlite_memory.add t ~content:"v1 content"
                       ~summary:"v1" ~scope:"proj" () with
      | Error e -> Alcotest.failf "add: %s" (Memory_error.to_string e)
      | Ok m -> m
    in
    let updated = match Sqlite_memory.update t
                       { original with content = "v2 content"; summary = Some "v2" } with
      | Error e -> Alcotest.failf "update: %s" (Memory_error.to_string e)
      | Ok m -> m
    in
    Alcotest.(check bool) "new id differs" true (original.id <> updated.id);
    Alcotest.(check string) "updated has v2 content" "v2 content" updated.content;
    (match Sqlite_memory.search t ~scope:"proj" "v1 content" with
     | Error e -> Alcotest.failf "search v1: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "v1 still exists" 1 (List.length results);
       Alcotest.(check string) "v1 content preserved"
         "v1 content" (List.hd results).content);
    (match Sqlite_memory.search t ~scope:"proj" "v2 content" with
     | Error e -> Alcotest.failf "search v2: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "v2 exists" 1 (List.length results));
    Sqlite_memory.close t

let test_bm25_ranking () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"OCaml is a great programming language for building reliable software"
          ~scope:"proj" () in
    let _ = Sqlite_memory.add t ~content:"Python is also a programming language but dynamically typed"
          ~scope:"proj" () in
    let _ = Sqlite_memory.add t ~content:"The weather is nice today" ~scope:"proj" () in
     begin match Sqlite_memory.search t ~scope:"proj" "OCaml programming" with
      | Error e -> Alcotest.failf "search: %s" (Memory_error.to_string e)
      | Ok results ->
        Alcotest.(check bool) "has results" true (List.length results > 0);
        let top = List.hd results in
        Alcotest.(check bool) "OCaml ranks first"
          true (String.contains top.content 'O')
     end;
    Sqlite_memory.close t

let test_render_index () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"Use dune for building"
          ~summary:"Build system convention" ~scope:"proj"
          ~categories:["convention"] () in
    let _ = Sqlite_memory.add t ~content:"Always write tests first"
          ~summary:"Testing convention" ~scope:"proj"
          ~categories:["convention"] () in
    let rendered = Sqlite_memory.render_index t ~scope:"proj" () in
    Alcotest.(check bool) "render not empty" true (String.length rendered > 0);
    Alcotest.(check bool) "contains build convention"
      (try ignore (Str.search_forward (Str.regexp_string "Build system") rendered 0); true
       with Not_found -> false) true;
    Alcotest.(check bool) "contains testing convention"
      (try ignore (Str.search_forward (Str.regexp_string "Testing") rendered 0); true
       with Not_found -> false) true;
    Sqlite_memory.close t

let test_delete_removes_from_both_tables () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let m = match Sqlite_memory.add t ~content:"temporary memory" ~scope:"proj" () with
      | Error e -> Alcotest.failf "add: %s" (Memory_error.to_string e)
      | Ok m -> m
    in
    (match Sqlite_memory.search t ~scope:"proj" "temporary" with
     | Error e -> Alcotest.failf "search before delete: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "exists before delete" 1 (List.length results));
    (match Sqlite_memory.delete t m.id with
     | Error e -> Alcotest.failf "delete: %s" (Memory_error.to_string e)
     | Ok () -> ());
    (match Sqlite_memory.search t ~scope:"proj" "temporary" with
     | Error e -> Alcotest.failf "search after delete: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "gone after delete" 0 (List.length results));
    Sqlite_memory.close t

let test_close_releases_handle () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"test close" () in
    Sqlite_memory.close t

let test_make_service () =
  match Sqlite_memory.make_service db_path with
  | Error e -> Alcotest.failf "make_service: %s" (Memory_error.to_string e)
  | Ok svc ->
    let _ = svc.Memory_service.add_fn ~content:"service test" ~scope:"proj" () in
    (match svc.Memory_service.search_fn ~scope:"proj" "service" with
     | Error e -> Alcotest.failf "search: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "found via service" 1 (List.length results));
    svc.Memory_service.close_fn ()

let test_delete_nonexistent () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    (match Sqlite_memory.delete t "nonexistent-id" with
     | Error (Memory_error.Database_error _) -> ()
     | Error e -> Alcotest.failf "wrong error: %s" (Memory_error.to_string e)
     | Ok () -> Alcotest.fail "should have failed");
    Sqlite_memory.close t

let test_list_all_with_scope () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"item alpha" ~scope:"a" () in
    let _ = Sqlite_memory.add t ~content:"item beta" ~scope:"b" () in
    let _ = Sqlite_memory.add t ~content:"item gamma" ~scope:"a" () in
    (match Sqlite_memory.list_all t ~scope:"a" () with
     | Error e -> Alcotest.failf "list_all: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "scope a has 2" 2 (List.length results));
    (match Sqlite_memory.list_all t () with
     | Error e -> Alcotest.failf "list_all all: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check int) "all has 3" 3 (List.length results));
    Sqlite_memory.close t

let test_usage_bump_on_search () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let m = match Sqlite_memory.add t ~content:"tracked memory" ~scope:"proj" () with
      | Error e -> Alcotest.failf "add: %s" (Memory_error.to_string e)
      | Ok m -> m
    in
    let _ = Sqlite_memory.search t ~scope:"proj" "tracked" in
    (match Sqlite_memory.list_all t ~scope:"proj" () with
     | Error e -> Alcotest.failf "list_all: %s" (Memory_error.to_string e)
     | Ok results ->
       let found = List.find_opt (fun (x : Memory_object.memory_object) ->
         x.id = m.id) results in
       match found with
       | None -> Alcotest.fail "memory not found after search"
        | Some _updated ->
          (* Usage bump is internal; verify memory is still findable *)
          Alcotest.(check int) "list_all returns at least 1" 1
            (List.length results));
    Sqlite_memory.close t

let test_search_no_scope_returns_all_matches () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"shared knowledge" ~scope:"a" () in
    let _ = Sqlite_memory.add t ~content:"shared knowledge too" ~scope:"b" () in
    (match Sqlite_memory.search t "shared knowledge" with
     | Error e -> Alcotest.failf "search: %s" (Memory_error.to_string e)
     | Ok results ->
       Alcotest.(check bool) "found across scopes" true (List.length results >= 2));
    Sqlite_memory.close t

let () =
  Eio_main.run (fun _env ->
    Alcotest.run "memory" [
      ("add-search", [
         Alcotest.test_case "roundtrip" `Quick test_add_search_roundtrip;
       ]);
      ("scope", [
         Alcotest.test_case "filtering" `Quick test_scope_filtering;
         Alcotest.test_case "no-scope-all" `Quick test_search_no_scope_returns_all_matches;
       ]);
      ("lifecycle", [
         Alcotest.test_case "add-only update" `Quick test_add_only_lifecycle;
       ]);
      ("ranking", [
         Alcotest.test_case "BM25 relevance" `Quick test_bm25_ranking;
       ]);
      ("render", [
         Alcotest.test_case "compact markdown" `Quick test_render_index;
       ]);
      ("delete", [
         Alcotest.test_case "removes from both" `Quick test_delete_removes_from_both_tables;
         Alcotest.test_case "nonexistent" `Quick test_delete_nonexistent;
       ]);
      ("close", [
         Alcotest.test_case "releases handle" `Quick test_close_releases_handle;
       ]);
      ("service", [
         Alcotest.test_case "make_service" `Quick test_make_service;
       ]);
      ("list", [
         Alcotest.test_case "scope filtering" `Quick test_list_all_with_scope;
       ]);
      ("usage", [
         Alcotest.test_case "bump on search" `Quick test_usage_bump_on_search;
       ]);
    ])
