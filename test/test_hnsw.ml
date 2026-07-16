open Par

let random_vector dim =
  Array.init dim (fun _ -> Random.float 2.0 -. 1.0)

let brute_force_cosine vectors query k =
  let qn =
    let norm = sqrt (Array.fold_left (fun s x -> s +. x *. x) 0.0 query) in
    if norm < 1e-10 then Array.make (Array.length query) 0.0
    else Array.map (fun x -> x /. norm) query
  in
  let scored = List.map (fun (id, v) ->
    let vn =
      let norm = sqrt (Array.fold_left (fun s x -> s +. x *. x) 0.0 v) in
      if norm < 1e-10 then Array.make (Array.length v) 0.0
      else Array.map (fun x -> x /. norm) v
    in
    let dot = ref 0.0 in
    Array.iteri (fun i a -> dot := !dot +. a *. vn.(i)) qn;
    (id, 1.0 -. !dot)
  ) vectors in
  let sorted = List.sort (fun (_, d1) (_, d2) -> compare d1 d2) scored in
  let rec take acc n = function
    | _ when n <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> take (x :: acc) (n - 1) xs
  in
  take [] k sorted

let take_n lst n =
  let rec aux acc k = function
    | _ when k <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> aux (x :: acc) (k - 1) xs
  in
  aux [] n lst

let recall_at_k hnsw_results bf_results k =
  let hnsw_ids = List.map fst (take_n hnsw_results k) in
  let bf_ids = List.map fst (take_n bf_results k) in
  let hits = List.fold_left (fun acc id ->
    if List.mem id bf_ids then acc + 1 else acc
  ) 0 hnsw_ids in
  float_of_int hits /. float_of_int k

let show_error (e : Types.error_category) = match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> "Invalid_input: " ^ s
  | Types.External_failure s -> "External_failure: " ^ s
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> "Permission_denied: " ^ s
  | Types.Internal s -> "Internal: " ^ s
  | Types.Embedding_unsupported -> "Embedding_unsupported"

let test_insert_search_basic () =
  Random.init 42;
  let dim = 128 in
  match Hnsw.create ~dimension:dim ~m:16 ~ef_construction:200 ~ef_search:50 () with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok idx ->
    let vectors = Array.init 100 (fun i ->
      let v = random_vector dim in
      let id = Printf.sprintf "doc_%d" i in
      match Hnsw.insert idx ~id v with
      | Ok () -> (id, v)
      | Error e -> Alcotest.failf "insert %s failed: %s" id (show_error e)
    ) in
    let query = random_vector dim in
    let results = Hnsw.search idx ~query ~k:5 in
    Alcotest.(check int) "returns 5 results" 5 (List.length results);
    let is_sorted = List.for_all2 (fun (_, d1) (_, d2) -> d1 <= d2)
      (List.rev (List.tl (List.rev results)))
      (List.tl results) in
    Alcotest.(check bool) "sorted by distance" true is_sorted;
    let vectors_list = Array.to_list vectors in
    let bf = brute_force_cosine vectors_list query 5 in
    let recall = recall_at_k results bf 5 in
    Printf.eprintf "DEBUG: hnsw_results=%s bf_results=%s recall=%f\n"
      (String.concat "," (List.map fst results))
      (String.concat "," (List.map fst bf))
      recall;
    Alcotest.(check bool) "recall >= 0.8" true (recall >= 0.8);
    Hnsw.close idx

let test_empty_index () =
  match Hnsw.create ~dimension:64 () with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok idx ->
    let results = Hnsw.search idx ~query:(Array.make 64 0.5) ~k:5 in
    Alcotest.(check int) "empty index returns []" 0 (List.length results);
    Hnsw.close idx

let test_duplicate_id () =
  match Hnsw.create ~dimension:32 () with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok idx ->
    let v = Array.make 32 1.0 in
    (match Hnsw.insert idx ~id:"dup" v with
     | Error e -> Alcotest.failf "first insert failed: %s" (show_error e)
     | Ok () -> ());
    (match Hnsw.insert idx ~id:"dup" v with
     | Ok () -> Alcotest.fail "duplicate insert should fail"
     | Error _ -> ());
    Hnsw.close idx

let test_delete () =
  Random.init 99;
  let dim = 64 in
  match Hnsw.create ~dimension:dim () with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok idx ->
    for i = 0 to 49 do
      let id = Printf.sprintf "v_%d" i in
      match Hnsw.insert idx ~id (random_vector dim) with
      | Ok () -> ()
      | Error e -> Alcotest.failf "insert %s failed: %s" id (show_error e)
    done;
    for i = 0 to 9 do
      let id = Printf.sprintf "v_%d" i in
      match Hnsw.delete idx ~id with
      | Ok () -> ()
      | Error e -> Alcotest.failf "delete %s failed: %s" id (show_error e)
    done;
    Alcotest.(check int) "size after delete" 40 (Hnsw.size idx);
    let query = random_vector dim in
    let results = Hnsw.search idx ~query ~k:10 in
    let deleted_ids = List.init 10 (fun i -> Printf.sprintf "v_%d" i) in
    List.iter (fun (id, _) ->
      Alcotest.(check bool) (Printf.sprintf "deleted %s not in results" id)
        false (List.mem id deleted_ids)
    ) results;
    Hnsw.close idx

let test_persistence () =
  Random.init 77;
  let dim = 64 in
  let path = Filename.temp_file "hnsw_test" ".bin" in
  (match Hnsw.create ~dimension:dim ~m:8 ~ef_construction:100 ~ef_search:30 () with
   | Error e -> Alcotest.failf "create failed: %s" (show_error e)
   | Ok idx ->
     for i = 0 to 99 do
       let id = Printf.sprintf "p_%d" i in
       match Hnsw.insert idx ~id (random_vector dim) with
       | Ok () -> ()
       | Error e -> Alcotest.failf "insert failed: %s" (show_error e)
     done;
     let query = random_vector dim in
     let _results_before = Hnsw.search idx ~query ~k:5 in
     (match Hnsw.save idx ~path with
      | Error e -> Alcotest.failf "save failed: %s" (show_error e)
      | Ok () -> ());
     Hnsw.close idx);
  (match Hnsw.load ~path with
   | Error e -> Alcotest.failf "load failed: %s" (show_error e)
   | Ok idx2 ->
     Alcotest.(check int) "loaded size" 100 (Hnsw.size idx2);
     let query = random_vector dim in
     let results_after = Hnsw.search idx2 ~query ~k:5 in
     Alcotest.(check int) "loaded search returns results" 5 (List.length results_after);
     Hnsw.close idx2);
  Sys.remove path

let test_large_dataset () =
  Random.init 123;
  let dim = 256 in
  let n = 1000 in
  match Hnsw.create ~dimension:dim ~m:16 ~ef_construction:200 ~ef_search:50 () with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok idx ->
    let vectors = Array.init n (fun i ->
      let v = random_vector dim in
      let id = Printf.sprintf "l_%d" i in
      match Hnsw.insert idx ~id v with
      | Ok () -> (id, v)
      | Error e -> Alcotest.failf "insert failed: %s" (show_error e)
    ) in
    let query = random_vector dim in
    let results = Hnsw.search idx ~query ~k:10 in
    Alcotest.(check int) "returns 10 results" 10 (List.length results);
    let vectors_list = Array.to_list vectors in
    let bf = brute_force_cosine vectors_list query 10 in
    let recall = recall_at_k results bf 10 in
    Alcotest.(check bool) "recall >= 0.7" true (recall >= 0.7);
    Hnsw.close idx

let test_dimension_mismatch () =
  match Hnsw.create ~dimension:64 () with
  | Error e -> Alcotest.failf "create failed: %s" (show_error e)
  | Ok idx ->
    (match Hnsw.insert idx ~id:"bad" (Array.make 32 1.0) with
     | Ok () -> Alcotest.fail "dimension mismatch should fail"
     | Error _ -> ());
    (try
       ignore (Hnsw.search idx ~query:(Array.make 32 1.0) ~k:5);
       Alcotest.fail "dimension mismatch should raise"
     with Invalid_argument _ -> ());
    Hnsw.close idx

let test_cosine_vs_l2 () =
  Random.init 55;
  let dim = 32 in
  let make_vec () = random_vector dim in
  let v1 = make_vec () and v2 = make_vec () and v3 = make_vec () in
  let test_metric metric name =
    match Hnsw.create ~dimension:dim ~distance_metric:metric () with
    | Error e -> Alcotest.failf "create %s failed: %s" name (show_error e)
    | Ok idx ->
      ignore (Hnsw.insert idx ~id:"a" v1);
      ignore (Hnsw.insert idx ~id:"b" v2);
      ignore (Hnsw.insert idx ~id:"c" v3);
      let results = Hnsw.search idx ~query:v1 ~k:3 in
      Alcotest.(check int) (name ^ " returns 3") 3 (List.length results);
      Hnsw.close idx
  in
  test_metric `Cosine "cosine";
  test_metric `L2 "l2"

let () =
  Alcotest.run "hnsw" [
    ("core", [
      Alcotest.test_case "insert + search basic (recall >= 0.8)" `Quick
        test_insert_search_basic;
      Alcotest.test_case "empty index search" `Quick
        test_empty_index;
      Alcotest.test_case "duplicate id rejected" `Quick
        test_duplicate_id;
      Alcotest.test_case "delete removes from results" `Quick
        test_delete;
      Alcotest.test_case "persistence save/load" `Quick
        test_persistence;
      Alcotest.test_case "large dataset 1000 vectors (recall >= 0.7)" `Quick
        test_large_dataset;
      Alcotest.test_case "dimension mismatch" `Quick
        test_dimension_mismatch;
      Alcotest.test_case "cosine vs L2 metrics" `Quick
        test_cosine_vs_l2;
    ]);
  ]
