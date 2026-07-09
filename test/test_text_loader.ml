open Par

let fixture_path = "/tmp/opencode/test_text_loader.txt"

let test_loads_txt_returns_one_document () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Text_loader.make ws fixture_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let docs = loader () in
    Alcotest.(check int) "1 document" 1 (List.length docs);
    let doc = List.hd docs in
    Alcotest.(check string) "content matches" "hello world\nthis is a test file\nfor the text loader\n" doc.content;
    Alcotest.(check string) "source" fixture_path doc.source

let test_metadata_has_file_type_and_file_name () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Text_loader.make ws fixture_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let doc = List.hd (loader ()) in
    (match Hashtbl.find doc.metadata "file_type" with
     | `String s -> Alcotest.(check string) "file_type" "text/plain" s
     | _ -> Alcotest.fail "file_type not a String");
    (match Hashtbl.find doc.metadata "file_name" with
     | `String s -> Alcotest.(check string) "file_name" "test_text_loader.txt" s
     | _ -> Alcotest.fail "file_name not a String")

let test_workspace_rejection () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Text_loader.make ws "/etc/passwd" with
  | Error (Document.Workspace_rejected _) -> ()
  | Error other ->
    Alcotest.failf "expected Workspace_rejected, got: %s" (Document.load_error_to_string other)
  | Ok _ -> Alcotest.fail "should have been rejected"

let () =
  Alcotest.run "text_loader" [
    ("load", [
      Alcotest.test_case "loads .txt and returns 1 Document" `Quick
        test_loads_txt_returns_one_document;
      Alcotest.test_case "metadata: file_type=text/plain and file_name set" `Quick
        test_metadata_has_file_type_and_file_name;
      Alcotest.test_case "workspace rejection" `Quick
        test_workspace_rejection;
    ]);
  ]
