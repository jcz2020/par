open Par

let fixtures_available = Sys.file_exists "/tmp/opencode"

let () =
  if not fixtures_available then begin
    print_endline "[SKIP] Fixtures not available at /tmp/opencode";
    exit 0
  end

let test_loads_mixed_directory () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Directory_loader.load ws ~map:Directory_loader.default_map "dir_loader_test" with
  | Error e -> Alcotest.failf "load failed: %s" (Document.load_error_to_string e)
  | Ok docs ->
    let n = List.length docs in
    Alcotest.(check bool) "at least 1 doc loaded" true (n > 0);
    (* .txt=1, .md=1, .csv=2, .xyz=skipped → total 4 docs *)
    Alcotest.(check int) "expected 4 documents (txt 1 + md 1 + csv 2)" 4 n

let test_unknown_extension_skipped () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Directory_loader.load ws ~map:Directory_loader.default_map "dir_loader_test" with
  | Ok docs ->
    (* The unknown.xyz file should not produce any Document *)
    let has_xyz = List.exists (fun d ->
      Filename.extension d.Document.source = ".xyz"
    ) docs in
    Alcotest.(check bool) "no .xyz documents" false has_xyz
  | Error e -> Alcotest.failf "load failed: %s" (Document.load_error_to_string e)

let test_workspace_rejection () =
  let ws = Workspace.of_dir "/tmp/opencode" |> Result.get_ok in
  match Directory_loader.load ws "/etc" with
  | Error (Document.Workspace_rejected _) -> ()
  | Error other ->
    Alcotest.failf "expected Workspace_rejected, got: %s" (Document.load_error_to_string other)
  | Ok _ -> Alcotest.fail "should have been rejected"

let () =
  Alcotest.run "directory_loader" [
    ("load", [
      Alcotest.test_case "loads mixed directory" `Quick
        test_loads_mixed_directory;
      Alcotest.test_case "unknown extension skipped" `Quick
        test_unknown_extension_skipped;
      Alcotest.test_case "workspace rejection" `Quick
        test_workspace_rejection;
    ]);
  ]
