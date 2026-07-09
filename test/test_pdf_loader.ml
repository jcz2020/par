open Par

let sample_pdf = "/tmp/opencode/sample.pdf"

let ws () = Workspace.of_dir "/tmp/opencode" |> Result.get_ok

let () =
  Alcotest.run "pdf_loader" [
    ("load", [
      Alcotest.test_case "loads 2-page PDF into 2 Documents" `Quick
        (fun () ->
          match Pdf_loader.make (ws ()) sample_pdf with
          | Error e ->
            Alcotest.failf "expected Ok, got Error: %s"
              (Document.load_error_to_string e)
          | Ok thunk ->
            let docs = thunk () in
            Alcotest.(check int) "2 documents" 2 (List.length docs));

      Alcotest.test_case "page metadata: page 1 = Int 1, page 2 = Int 2" `Quick
        (fun () ->
          match Pdf_loader.make (ws ()) sample_pdf with
          | Error e ->
            Alcotest.failf "expected Ok, got Error: %s"
              (Document.load_error_to_string e)
          | Ok thunk ->
            let docs = thunk () in
            let d1 = List.nth docs 0 in
            let d2 = List.nth docs 1 in
            (match Hashtbl.find d1.Document.metadata "page" with
             | `Int n -> Alcotest.(check int) "page 1" 1 n
             | _ -> Alcotest.fail "page 1 not Int");
            (match Hashtbl.find d2.Document.metadata "page" with
             | `Int n -> Alcotest.(check int) "page 2" 2 n
             | _ -> Alcotest.fail "page 2 not Int"));

      Alcotest.test_case "page 1 content contains PAR" `Quick
        (fun () ->
          match Pdf_loader.make (ws ()) sample_pdf with
          | Error e ->
            Alcotest.failf "expected Ok, got Error: %s"
              (Document.load_error_to_string e)
          | Ok thunk ->
            let docs = thunk () in
            let d1 = List.nth docs 0 in
            let content = d1.Document.content in
            if String.length content = 0 then
              Alcotest.fail "page 1 content is empty";
            if not (try ignore (Str.search_forward (Str.regexp_string "PAR") content 0); true with Not_found -> false) then
              Alcotest.failf "page 1 content missing 'PAR', got first 200 chars: %s"
                (String.sub content 0 (min 200 (String.length content))));

      Alcotest.test_case "workspace rejection returns Error" `Quick
        (fun () ->
          match Pdf_loader.make (ws ()) "/etc/passwd" with
          | Ok _ -> Alcotest.fail "expected Error for workspace-rejected path"
          | Error (Document.Workspace_rejected _) -> ()
          | Error other ->
            Alcotest.failf "expected Workspace_rejected, got: %s"
              (Document.load_error_to_string other));
    ]);
  ]
