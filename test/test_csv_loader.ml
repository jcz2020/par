open Par

let fixtures_available = Sys.file_exists "/tmp/opencode"

let () =
  if not fixtures_available then begin
    print_endline "[SKIP] Fixtures not available at /tmp/opencode";
    exit 0
  end

let fixture_path = "/tmp/opencode/test_csv_loader.csv"

let test_header_two_data_rows_two_documents () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Csv_loader.make ws fixture_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let docs = loader () in
    Alcotest.(check int) "2 documents" 2 (List.length docs);
    let d1 = List.nth docs 0 in
    (match Hashtbl.find d1.metadata "name" with
     | `String s -> Alcotest.(check string) "row 1 name" "Alice" s
     | _ -> Alcotest.fail "name not a String");
    (match Hashtbl.find d1.metadata "age" with
     | `String s -> Alcotest.(check string) "row 1 age" "30" s
     | _ -> Alcotest.fail "age not a String");
    (match Hashtbl.find d1.metadata "city" with
     | `String s -> Alcotest.(check string) "row 1 city" "SF" s
     | _ -> Alcotest.fail "city not a String")

let test_row_index_in_metadata () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Csv_loader.make ws fixture_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let docs = loader () in
    let d2 = List.nth docs 1 in
    (match Hashtbl.find d2.metadata "row_index" with
     | `Int n -> Alcotest.(check int) "row 2 index" 2 n
     | _ -> Alcotest.fail "row_index not an Int")

let test_workspace_rejection () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Csv_loader.make ws "/etc/passwd" with
  | Error (Document.Workspace_rejected _) -> ()
  | Error other ->
    Alcotest.failf "expected Workspace_rejected, got: %s" (Document.load_error_to_string other)
  | Ok _ -> Alcotest.fail "should have been rejected"

let () =
  Alcotest.run "csv_loader" [
    ("load", [
      Alcotest.test_case "header + 2 data rows" `Quick
        test_header_two_data_rows_two_documents;
      Alcotest.test_case "row_index in metadata" `Quick
        test_row_index_in_metadata;
      Alcotest.test_case "workspace rejection" `Quick
        test_workspace_rejection;
    ]);
  ]
