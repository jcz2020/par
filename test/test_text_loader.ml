open Par

(* Dynamic fixture: create the workspace + content file in a temp dir so
   the test runs in any environment (CI, fresh opam install, tarball
   build) instead of depending on /tmp/opencode which is a developer-
   machine checkout of an unrelated project. *)
let fixture_dir =
  let d = Filename.get_temp_dir_name () ^ "/par_test_text_loader_"
          ^ string_of_int (Unix.getpid ()) in
  Unix.mkdir d 0o755; d

let fixture_path = Filename.concat fixture_dir "test_text_loader.txt"

let () =
  let oc = open_out fixture_path in
  output_string oc "hello world\nthis is a test file\nfor the text loader\n";
  close_out oc

let () = at_exit (fun () ->
  try ignore (Unix.system ("rm -rf " ^ Filename.quote fixture_dir)) with _ -> ())

let test_loads_txt_returns_one_document () =
  let ws = Workspace.of_dir fixture_dir |> Result.get_ok in
  match Text_loader.make ws fixture_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let docs = loader () in
    Alcotest.(check int) "1 document" 1 (List.length docs);
    let doc = List.hd docs in
    Alcotest.(check string) "content matches" "hello world\nthis is a test file\nfor the text loader\n" doc.content;
    Alcotest.(check string) "source" fixture_path doc.source

let test_metadata_has_file_type_and_file_name () =
  let ws = Workspace.of_dir fixture_dir |> Result.get_ok in
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
  let ws = Workspace.of_dir fixture_dir |> Result.get_ok in
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
