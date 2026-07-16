open Par

let fixtures_available = Sys.file_exists "/tmp/opencode"

let () =
  if not fixtures_available then begin
    print_endline "[SKIP] Fixtures not available at /tmp/opencode";
    exit 0
  end

let docx_path = "/tmp/opencode/test_docx_loader.docx"
let bogus_path = "/tmp/opencode/test_docx_loader_bogus.docx"

let document_xml =
  "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\
   <w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\
     <w:body>\
       <w:p><w:r><w:t>Hello</w:t></w:r></w:p>\
       <w:p><w:r><w:t>Line</w:t><w:rPr/><w:tab/><w:t>Two</w:t></w:r></w:p>\
     </w:body>\
   </w:document>"

let () =
  let zf = Zip.open_out docx_path in
  Zip.add_entry document_xml zf "word/document.xml";
  Zip.close_out zf

let () =
  let oc = open_out bogus_path in
  output_string oc "this is not a zip file";
  close_out oc

let ws () = Workspace.of_dir "/tmp/opencode" |> Result.get_ok

let test_valid_docx_returns_one_document () =
  match Docx_loader.make (ws ()) docx_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let docs = loader () in
    Alcotest.(check int) "1 document" 1 (List.length docs);
    let doc = List.hd docs in
    Alcotest.(check string) "source" docx_path doc.Document.source;
    let content = doc.Document.content in
    if not (try ignore (Str.search_forward (Str.regexp_string "Hello") content 0); true
            with Not_found -> false)
    then Alcotest.failf "content missing 'Hello': %S" content;
    if not (try ignore (Str.search_forward (Str.regexp_string "Line") content 0); true
            with Not_found -> false)
    then Alcotest.failf "content missing 'Line': %S" content;
    if not (try ignore (Str.search_forward (Str.regexp_string "Two") content 0); true
            with Not_found -> false)
    then Alcotest.failf "content missing 'Two': %S" content

let test_metadata_has_docx_file_type () =
  match Docx_loader.make (ws ()) docx_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let doc = List.hd (loader ()) in
    (match Hashtbl.find doc.Document.metadata "file_type" with
     | `String s ->
       Alcotest.(check string)
         "file_type" "application/vnd.openxmlformats-officedocument.wordprocessingml.document" s
     | _ -> Alcotest.fail "file_type not a String");
    (match Hashtbl.find doc.Document.metadata "file_name" with
     | `String s -> Alcotest.(check string) "file_name" "test_docx_loader.docx" s
     | _ -> Alcotest.fail "file_name not a String")

let test_file_size_is_real_disk_size () =
  let real_size = (Unix.stat docx_path).Unix.st_size in
  match Docx_loader.make (ws ()) docx_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let doc = List.hd (loader ()) in
    (match Hashtbl.find doc.Document.metadata "file_size" with
     | `Int n -> Alcotest.(check int) "file_size = real disk size" real_size n
     | _ -> Alcotest.fail "file_size not an Int")

let test_missing_file_returns_error () =
  match Docx_loader.make (ws ()) "/tmp/opencode/does_not_exist.docx" with
  | Error Document.File_not_found _ -> ()
  | Error other ->
    Alcotest.failf "expected File_not_found, got: %s"
      (Document.load_error_to_string other)
  | Ok _ -> Alcotest.fail "expected File_not_found for missing file"

let test_invalid_zip_returns_empty () =
  match Docx_loader.make (ws ()) bogus_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let docs = loader () in
    Alcotest.(check int) "invalid zip → 0 documents" 0 (List.length docs)

let test_workspace_rejection () =
  match Docx_loader.make (ws ()) "/etc/passwd" with
  | Error (Document.Workspace_rejected _) -> ()
  | Error other ->
    Alcotest.failf "expected Workspace_rejected, got: %s"
      (Document.load_error_to_string other)
  | Ok _ -> Alcotest.fail "should have been rejected"

let () =
  Alcotest.run "docx_loader" [
    ("load", [
      Alcotest.test_case "valid .docx returns 1 Document with text" `Quick
        test_valid_docx_returns_one_document;
      Alcotest.test_case "metadata: file_type and file_name" `Quick
        test_metadata_has_docx_file_type;
      Alcotest.test_case "file_size is real disk size, not text length" `Quick
        test_file_size_is_real_disk_size;
      Alcotest.test_case "missing file → Error File_not_found" `Quick
        test_missing_file_returns_error;
      Alcotest.test_case "non-zip file → empty list (graceful)" `Quick
        test_invalid_zip_returns_empty;
      Alcotest.test_case "workspace rejection" `Quick
        test_workspace_rejection;
    ]);
  ]
