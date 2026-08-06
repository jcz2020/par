open Par

let fixture_dir =
  let d = Filename.get_temp_dir_name () ^ "/par_test_html_loader_"
          ^ string_of_int (Unix.getpid ()) in
  Unix.mkdir d 0o755; d

let fixture_path = Filename.concat fixture_dir "test_html_loader.html"

let () =
  let oc = open_out fixture_path in
  output_string oc "<!DOCTYPE html>\n<html>\n<head>\n\
    <script>alert(\"test\");</script>\n\
    <style>p { color:red; }</style>\n</head>\n<body>\n\
    <nav>navigation</nav>\n\
    <p>Hello World</p>\n\
    <p>visible text here</p>\n\
    </body>\n</html>\n";
  close_out oc

let () = at_exit (fun () ->
  try ignore (Unix.system ("rm -rf " ^ Filename.quote fixture_dir)) with _ -> ())

let has_substr haystack needle =
  let hlen = String.length haystack and nlen = String.length needle in
  let rec go i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else go (i + 1)
  in
  go 0

let test_html_strips_script_style_nav () =
  let ws = match Workspace.of_dir fixture_dir with
    | Ok w -> w | Error _ -> Alcotest.fail "workspace creation failed"
  in
  match Html_loader.make ws fixture_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let docs = loader () in
    Alcotest.(check int) "one document" 1 (List.length docs);
    let doc = List.hd docs in
    let text = doc.content in
    Alcotest.(check bool) "no alert in text"
      true (not (has_substr text "alert"));
    Alcotest.(check bool) "no <script> literal"
      true (not (has_substr text "<script>"));
    Alcotest.(check bool) "no style rule in text"
      true (not (has_substr text "color:red"));
    Alcotest.(check bool) "has visible text"
      true (has_substr text "visible text here")

let test_html_body_text () =
  let ws = match Workspace.of_dir fixture_dir with
    | Ok w -> w | Error _ -> Alcotest.fail "workspace creation failed"
  in
  match Html_loader.make ws fixture_path with
  | Error e -> Alcotest.failf "make failed: %s" (Document.load_error_to_string e)
  | Ok loader ->
    let docs = loader () in
    let doc = List.hd docs in
    Alcotest.(check bool) "has Hello World"
      true (has_substr doc.content "Hello World");
    Alcotest.(check bool) "source is fixture path"
      true (doc.source = fixture_path);
    let file_type = Hashtbl.find doc.metadata "file_type" in
    match file_type with
    | `String ft ->
      Alcotest.(check string) "file_type is text/html" "text/html" ft
    | _ -> Alcotest.fail "file_type is not a String"

let test_workspace_rejection () =
  let ws = match Workspace.of_dir fixture_dir with
    | Ok w -> w | Error _ -> Alcotest.fail "workspace creation failed"
  in
  match Html_loader.make ws "/etc/passwd" with
  | Error (Workspace_rejected _) -> ()
  | Error other ->
    Alcotest.failf "unexpected error: %s" (Document.load_error_to_string other)
  | Ok _ ->
    Alcotest.fail "should have been rejected by workspace"

let () =
  Alcotest.run "html_loader" [
    ("HTML extraction", [
      Alcotest.test_case "strips script/style/nav elements" `Quick
        test_html_strips_script_style_nav;
      Alcotest.test_case "body text and metadata" `Quick
        test_html_body_text;
      Alcotest.test_case "workspace rejection" `Quick
        test_workspace_rejection;
    ]);
  ]
