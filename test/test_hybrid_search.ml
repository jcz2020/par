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

let dim = 4
let vocab = [|"alpha"; "beta"; "gamma"; "delta"|]

let count_keyword (text : string) (keyword : string) : int =
  let lower = String.lowercase_ascii text in
  let re = Str.regexp_string (String.lowercase_ascii keyword) in
  let rec loop pos acc =
    try
      let idx = Str.search_forward re lower pos in
      loop (idx + String.length keyword) (acc + 1)
    with Not_found -> acc
  in
  loop 0 0

let content_embedding (content : string) : float array =
  let vec = Array.make dim 0.0 in
  Array.iteri (fun d kw -> vec.(d) <- float_of_int (count_keyword content kw)) vocab;
  let norm = sqrt (Array.fold_left (fun a v -> a +. v *. v) 0.0 vec) in
  if norm > 0.0 then Array.map (fun v -> v /. norm) vec
  else vec

let has_novector (text : string) : bool =
  let lower = String.lowercase_ascii text in
  try
    let _ = Str.search_forward (Str.regexp_string "novector") lower 0 in
    true
  with Not_found -> false

let mock_embedding_gap : Memory_service.embedding_fn =
  fun texts ->
    Ok (List.map (fun text ->
      if has_novector text then [||]
      else content_embedding text
    ) texts)

let mock_embedding_content : Memory_service.embedding_fn =
  fun texts -> Ok (List.map content_embedding texts)

type fixture = {
  t : Sqlite_memory.t;
  d_alpha_all : string;
  d_gamma_delta : string;
  d_alpha_novector : string;
}

let setup_fixture () : fixture =
  match Sqlite_memory.create ~dimension:dim ~embedding_fn:mock_embedding_gap ":memory:" with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let add content =
      match Sqlite_memory.add t ~content () with
      | Error e -> Alcotest.failf "add %s: %s" content (Memory_error.to_string e)
      | Ok m -> m.content
    in
    {
      t;
      d_alpha_all = add "alpha beta gamma delta";
      d_gamma_delta = add "gamma delta";
      d_alpha_novector = add "alpha novector content";
    }

let close_fixture (f : fixture) = Sqlite_memory.close f.t

let contents_of (results : Memory_object.memory_object list) : string list =
  List.map (fun (m : Memory_object.memory_object) -> m.content) results

let position_of (results : Memory_object.memory_object list) (content : string) : int option =
  let rec loop i = function
    | [] -> None
    | (m : Memory_object.memory_object) :: _ when m.content = content -> Some i
    | _ :: rest -> loop (i + 1) rest
  in
  loop 0 results

let query_vec_alpha = [| 1.0; 0.0; 0.0; 0.0 |]

let test_both_legs_ranks_highest () =
  let f = setup_fixture () in
  (match Sqlite_memory.hybrid_search f.t ~limit:5 ~query:"alpha" ~query_vec:query_vec_alpha () with
   | Error e -> Alcotest.failf "hybrid_search: %s" (Memory_error.to_string e)
   | Ok results ->
     let contents = contents_of results in
     Alcotest.(check bool) "both-legs doc present"
       true (List.mem f.d_alpha_all contents);
     let pos_all = position_of results f.d_alpha_all in
     let pos_gamma = position_of results f.d_gamma_delta in
     (match pos_all, pos_gamma with
      | Some pa, Some pg ->
        Alcotest.(check bool) "both-legs above vec-only" true (pa < pg)
      | _ ->
        Alcotest.fail "expected both d_alpha_all and d_gamma_delta in results"));
  close_fixture f

let test_fts_only_document_appears () =
  let f = setup_fixture () in
  (match Sqlite_memory.hybrid_search f.t ~limit:5 ~query:"alpha" ~query_vec:query_vec_alpha () with
   | Error e -> Alcotest.failf "hybrid_search: %s" (Memory_error.to_string e)
   | Ok results ->
     Alcotest.(check bool) "fts-only doc appears"
       true (List.mem f.d_alpha_novector (contents_of results)));
  close_fixture f

let test_vec_only_document_appears () =
  let f = setup_fixture () in
  (match Sqlite_memory.hybrid_search f.t ~limit:5 ~query:"alpha" ~query_vec:query_vec_alpha () with
   | Error e -> Alcotest.failf "hybrid_search: %s" (Memory_error.to_string e)
   | Ok results ->
     Alcotest.(check bool) "vec-only doc appears"
       true (List.mem f.d_gamma_delta (contents_of results)));
  close_fixture f

let test_weight_sensitivity () =
  let f = setup_fixture () in
  let run ~w_fts ~w_vec =
    match Sqlite_memory.hybrid_search f.t
      ~limit:5 ~weight_fts:w_fts ~weight_vec:w_vec
      ~query:"alpha" ~query_vec:query_vec_alpha () with
    | Ok r -> r
    | Error e -> Alcotest.failf "hybrid_search: %s" (Memory_error.to_string e)
  in
  let fts_heavy = run ~w_fts:1.0 ~w_vec:0.0 in
  let vec_heavy = run ~w_fts:0.0 ~w_vec:1.0 in
  let pos_novector_fts = position_of fts_heavy f.d_alpha_novector in
  let pos_gamma_fts = position_of fts_heavy f.d_gamma_delta in
  let pos_novector_vec = position_of vec_heavy f.d_alpha_novector in
  let pos_gamma_vec = position_of vec_heavy f.d_gamma_delta in
  (match pos_novector_fts, pos_gamma_fts with
   | Some pf, Some pg ->
     Alcotest.(check bool) "fts-only above vec-only when weight_fts=1" true (pf < pg)
   | _ -> Alcotest.fail "expected both docs in fts-heavy results");
  (match pos_novector_vec, pos_gamma_vec with
   | Some pv, Some pgv ->
     Alcotest.(check bool) "vec-only above fts-only when weight_vec=1" true (pgv < pv)
   | _ -> Alcotest.fail "expected both docs in vec-heavy results");
  close_fixture f

let test_deterministic_ordering () =
  let f = setup_fixture () in
  let run () =
    match Sqlite_memory.hybrid_search f.t
      ~limit:5 ~query:"alpha" ~query_vec:query_vec_alpha () with
    | Ok r -> contents_of r
    | Error e -> Alcotest.failf "hybrid_search: %s" (Memory_error.to_string e)
  in
  let order1 = run () in
  let order2 = run () in
  Alcotest.(check (list string)) "same ordering both runs" order1 order2;
  close_fixture f

let test_empty_results () =
  let f = setup_fixture () in
  (match Sqlite_memory.hybrid_search f.t
      ~scope:"nonexistent_scope" ~limit:5
      ~query:"alpha" ~query_vec:query_vec_alpha () with
   | Error e -> Alcotest.failf "should return Ok [], got Error: %s" (Memory_error.to_string e)
   | Ok results ->
     Alcotest.(check int) "empty list for nonexistent scope" 0 (List.length results));
  close_fixture f

let test_scope_filtering () =
  match Sqlite_memory.create ~dimension:dim ~embedding_fn:mock_embedding_content ":memory:" with
  | Error e -> Alcotest.failf "create: %s" (Memory_error.to_string e)
  | Ok t ->
    let _ = Sqlite_memory.add t ~content:"alpha beta" ~scope:"scopeA" () in
    let _ = Sqlite_memory.add t ~content:"alpha gamma" ~scope:"scopeB" () in
    let _ = Sqlite_memory.add t ~content:"alpha delta" ~scope:"scopeA" () in
    (match Sqlite_memory.hybrid_search t
        ~scope:"scopeA" ~limit:5
        ~query:"alpha" ~query_vec:query_vec_alpha () with
     | Error e -> Alcotest.failf "hybrid_search: %s" (Memory_error.to_string e)
     | Ok results ->
       let scopes = List.filter_map (fun (m : Memory_object.memory_object) ->
         m.scope) results in
       let all_a = List.for_all (fun s -> s = "scopeA") scopes in
       Alcotest.(check bool) "only scopeA results" true all_a;
       Alcotest.(check int) "exactly 2 scopeA docs" 2 (List.length results));
    Sqlite_memory.close t

let () =
  Eio_main.run (fun _env ->
    Alcotest.run "hybrid_search" [
      ("rrf", [
         Alcotest.test_case "both-legs doc ranks highest" `Quick
           test_both_legs_ranks_highest;
         Alcotest.test_case "fts-only document appears" `Quick
           test_fts_only_document_appears;
         Alcotest.test_case "vec-only document appears" `Quick
           test_vec_only_document_appears;
         Alcotest.test_case "weight sensitivity changes ranking" `Quick
           test_weight_sensitivity;
         Alcotest.test_case "deterministic ordering (k=60)" `Quick
           test_deterministic_ordering;
         Alcotest.test_case "empty results returns empty list" `Quick
           test_empty_results;
         Alcotest.test_case "scope filtering" `Quick
           test_scope_filtering;
       ]);
    ])
