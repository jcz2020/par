open Par

let fixture_path = "/tmp/opencode/test_md_loader.md"

let test_loads_md_returns_one_document () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Markdown_loader.make ws fixture_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let docs = loader () in
    Alcotest.(check int) "1 document" 1 (List.length docs);
    let doc = List.hd docs in
    Alcotest.(check bool) "content non-empty"
      true (String.length doc.content > 0)

let test_frontmatter_title_in_metadata () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Markdown_loader.make ws fixture_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let doc = List.hd (loader ()) in
    (match Hashtbl.find_opt doc.metadata "title" with
     | Some (`String s) -> Alcotest.(check string) "title" "Hello World" s
     | _ -> Alcotest.fail "title not in metadata or wrong type")

let test_metadata_file_type_markdown () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Markdown_loader.make ws fixture_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let doc = List.hd (loader ()) in
    (match Hashtbl.find doc.metadata "file_type" with
     | `String s -> Alcotest.(check string) "file_type" "text/markdown" s
     | _ -> Alcotest.fail "file_type not a String")

let test_workspace_rejection () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Markdown_loader.make ws "/etc/passwd" with
  | Error (Document.Workspace_rejected _) -> ()
  | Error other ->
    Alcotest.failf "expected Workspace_rejected, got: %s" (Document.load_error_to_string other)
  | Ok _ -> Alcotest.fail "should have been rejected"

let () =
  Alcotest.run "markdown_loader" [
    ("load", [
      Alcotest.test_case "loads .md with frontmatter" `Quick
        test_loads_md_returns_one_document;
      Alcotest.test_case "frontmatter title in metadata" `Quick
        test_frontmatter_title_in_metadata;
      Alcotest.test_case "metadata file_type=text/markdown" `Quick
        test_metadata_file_type_markdown;
      Alcotest.test_case "workspace rejection" `Quick
        test_workspace_rejection;
    ]);
  ]
