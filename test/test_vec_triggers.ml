open Par_memory

let db_path = ":memory:"

let mock_embedding dim : Memory_service.embedding_fn =
  fun texts ->
    Ok (List.map (fun _ ->
      Array.init dim (fun i -> float_of_int (i mod 10) /. 10.0)
    ) texts)

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

let update_content_direct (t : Sqlite_memory.t) ~ext_id ~new_content =
  let stmt = Sqlite3.prepare t.db
    "UPDATE memory_entries SET content = ? WHERE ext_id = ?" in
  let _ = Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT new_content) in
  let _ = Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT ext_id) in
  let _ = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  ()

let test_delete_removes_vec_row () =
  let embed_fn = mock_embedding 1536 in
  match Sqlite_memory.create ~embedding_fn:embed_fn db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let m = Sqlite_memory.add t ~content:"test delete vec cleanup"
          ~scope:"test" () |> Result.get_ok in
    Alcotest.(check int) "vec0 has 1 row" 1 (vec_row_count t);
    Sqlite_memory.delete t m.id |> Result.get_ok;
    Alcotest.(check int) "vec0 row gone after delete" 0 (vec_row_count t);
    Sqlite_memory.close t

let test_update_content_drops_stale_vec () =
  let embed_fn = mock_embedding 1536 in
  match Sqlite_memory.create ~embedding_fn:embed_fn db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let m = Sqlite_memory.add t ~content:"original content"
          ~scope:"test" () |> Result.get_ok in
    Alcotest.(check int) "vec0 has 1 row" 1 (vec_row_count t);
    update_content_direct t ~ext_id:m.id ~new_content:"updated content";
    Alcotest.(check int) "vec0 row gone after content update" 0 (vec_row_count t);
    Sqlite_memory.close t

let test_delete_without_vec_no_error () =
  match Sqlite_memory.create db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let m = Sqlite_memory.add t ~content:"no embedding here"
          ~scope:"test" () |> Result.get_ok in
    Alcotest.(check int) "vec0 empty" 0 (vec_row_count t);
    (match Sqlite_memory.delete t m.id with
     | Ok () ->
       Alcotest.(check int) "vec0 still empty, no error" 0 (vec_row_count t)
     | Error e ->
       Alcotest.failf "delete should not fail when no vec row: %s"
         (Memory_error.to_string e));
    Sqlite_memory.close t

let test_delete_preserves_other_vec_rows () =
  let embed_fn = mock_embedding 1536 in
  match Sqlite_memory.create ~embedding_fn:embed_fn db_path with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let m1 = Sqlite_memory.add t ~content:"first entry"
          ~scope:"test" () |> Result.get_ok in
    let _m2 = Sqlite_memory.add t ~content:"second entry"
          ~scope:"test" () |> Result.get_ok in
    let _m3 = Sqlite_memory.add t ~content:"third entry"
          ~scope:"test" () |> Result.get_ok in
    Alcotest.(check int) "vec0 has 3 rows" 3 (vec_row_count t);
    Sqlite_memory.delete t m1.id |> Result.get_ok;
    Alcotest.(check int) "vec0 has 2 rows after delete" 2 (vec_row_count t);
    Sqlite_memory.close t

let () =
  Eio_main.run (fun _env ->
    Alcotest.run "vec_triggers" [
      ("delete", [
         Alcotest.test_case "delete removes vec row" `Quick
           test_delete_removes_vec_row;
         Alcotest.test_case "delete without vec row no error" `Quick
           test_delete_without_vec_no_error;
         Alcotest.test_case "delete preserves other vec rows" `Quick
           test_delete_preserves_other_vec_rows;
       ]);
      ("update", [
         Alcotest.test_case "update content drops stale vec row" `Quick
           test_update_content_drops_stale_vec;
       ]);
    ])
