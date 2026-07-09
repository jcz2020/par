open Par
open Bash_safe_command

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid_input %S" s
  | Types.External_failure s -> Printf.sprintf "External_failure %S" s
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission_denied %S" s
  | Types.Internal s -> Printf.sprintf "Internal %S" s
  | Types.Embedding_unsupported -> "Embedding_unsupported"

let ws = match Workspace.of_cwd () with Ok w -> w | Error _ -> failwith "ws"

let expect_invalid_input msg result =
  match result with
  | Error (Types.Invalid_input m) when m = msg -> ()
  | Ok p ->
    Alcotest.failf "expected Error (Invalid_input %S), got Ok %S" msg
      (Workspace.to_string p)
  | Error e ->
    Alcotest.failf "expected Error (Invalid_input %S), got %s" msg
      (error_to_string e)

let expect_permission_denied result =
  match result with
  | Error (Types.Permission_denied _) -> ()
  | Ok p ->
    Alcotest.failf "expected Permission_denied, got Ok %S"
      (Workspace.to_string p)
  | Error e ->
    Alcotest.failf "expected Permission_denied, got %s" (error_to_string e)

let with_chdir_ws dir f =
  let original = Sys.getcwd () in
  Fun.protect ~finally:(fun () -> Unix.chdir original) (fun () ->
    Unix.chdir dir;
    match Workspace.of_cwd () with
    | Ok ws -> f ws
    | Error e -> failwith ("Workspace.of_cwd failed: " ^ error_to_string e))

let root_cwd =
  match Workspace.admit ws "" with
  | Ok p -> p
  | Error _ -> failwith "root_cwd"

let sandboxed_path_suite =
  ("sandboxed_path", [
    Alcotest.test_case "accepts 'src/lib'" `Quick (fun () ->
      match Workspace.admit ws "src/lib" with
      | Ok p ->
        let expected = Filename.concat (Workspace.root ws) "src/lib" in
        Alcotest.(check string) "admits to canonical path" expected (Workspace.to_string p)
      | Error e -> Alcotest.failf "expected Ok, got %s" (error_to_string e));

    Alcotest.test_case "accepts 'a/b/c.txt'" `Quick (fun () ->
      match Workspace.admit ws "a/b/c.txt" with
      | Ok p ->
        let expected = Filename.concat (Workspace.root ws) "a/b/c.txt" in
        Alcotest.(check string) "admits to canonical path" expected (Workspace.to_string p)
      | Error e -> Alcotest.failf "expected Ok, got %s" (error_to_string e));

    Alcotest.test_case "accepts 'foo..bar' (substring is not a path component)" `Quick (fun () ->
      match Workspace.admit ws "foo..bar" with
      | Ok p ->
        let expected = Filename.concat (Workspace.root ws) "foo..bar" in
        Alcotest.(check string) "admits to canonical path" expected (Workspace.to_string p)
      | Error e -> Alcotest.failf "expected Ok, got %s" (error_to_string e));

    Alcotest.test_case "rejects '..'" `Quick (fun () ->
      expect_invalid_input "path contains .."
        (Workspace.admit ws ".."));

    Alcotest.test_case "rejects '../foo'" `Quick (fun () ->
      expect_invalid_input "path contains .."
        (Workspace.admit ws "../foo"));

    Alcotest.test_case "rejects 'sub/../etc'" `Quick (fun () ->
      expect_invalid_input "path contains .."
        (Workspace.admit ws "sub/../etc"));

    Alcotest.test_case "rejects '/etc/passwd' (absolute not under workspace root)" `Quick (fun () ->
      expect_invalid_input "absolute path not under any workspace root"
        (Workspace.admit ws "/etc/passwd"));

    Alcotest.test_case "rejects 'C:\\Windows' (absolute not under workspace root)" `Quick (fun () ->
      expect_invalid_input "absolute path not under any workspace root"
        (Workspace.admit ws "C:\\Windows"));

    Alcotest.test_case "rejects 'foo:bar' (contains :)" `Quick (fun () ->
      expect_invalid_input "path contains :"
        (Workspace.admit ws "foo:bar"));

    Alcotest.test_case "rejects CWD-relative path resolving to /etc" `Quick (fun () ->
      with_chdir_ws "/" (fun ws_root ->
        expect_permission_denied
          (Workspace.admit ws_root "etc/foo")));

    Alcotest.test_case "admit \"\" returns workspace root" `Quick (fun () ->
      match Workspace.admit ws "" with
      | Ok p ->
        Alcotest.(check string) "root" (Workspace.root ws) (Workspace.to_string p)
      | Error e -> Alcotest.failf "expected Ok, got %s" (error_to_string e));
  ])

let command_suite =
  ("command", [
    Alcotest.test_case "make_exec with explicit cwd" `Quick (fun () ->
      let cmd = make_exec ~argv:["echo"; "hello"] ~cwd:root_cwd () in
      match cmd with
      | Exec { argv; cwd; env; timeout } ->
        Alcotest.(check (list string)) "argv" ["echo"; "hello"] argv;
        Alcotest.(check string) "cwd is workspace root" (Workspace.root ws) (Workspace.to_string cwd);
        Alcotest.(check (list (pair string string))) "env" [] env;
        Alcotest.(check (float 0.001)) "timeout default" 30.0 timeout
      | _ -> Alcotest.fail "expected Exec");

    Alcotest.test_case "make_exec with custom cwd, env, timeout" `Quick (fun () ->
      let cwd = match Workspace.admit ws "build" with
        | Ok p -> p
        | Error e -> Alcotest.failf "Workspace.admit build: %s" (error_to_string e)
      in
      let cmd = make_exec ~argv:["ls"]
        ~cwd ~env:["KEY", "VAL"] ~timeout:120.0 () in
      match cmd with
      | Exec { argv; cwd = c'; env; timeout } ->
        Alcotest.(check (list string)) "argv" ["ls"] argv;
        let expected = Filename.concat (Workspace.root ws) "build" in
        Alcotest.(check string) "cwd" expected (Workspace.to_string c');
        Alcotest.(check (list (pair string string))) "env" ["KEY", "VAL"] env;
        Alcotest.(check (float 0.001)) "timeout" 120.0 timeout
      | _ -> Alcotest.fail "expected Exec");

    Alcotest.test_case "make_exec with timeout=0 rejected" `Quick (fun () ->
      Alcotest.check_raises "rejects timeout=0"
        (Invalid_argument "timeout must be > 0")
        (fun () -> ignore (make_exec ~argv:["echo"] ~cwd:root_cwd ~timeout:0.0 ())));

    Alcotest.test_case "make_exec with timeout=600.1 rejected" `Quick (fun () ->
      Alcotest.check_raises "rejects timeout > 600"
        (Invalid_argument "timeout exceeds 600s cap")
        (fun () -> ignore (make_exec ~argv:["echo"] ~cwd:root_cwd ~timeout:600.1 ())));

    Alcotest.test_case "make_exec with timeout=600.0 accepted (boundary)" `Quick (fun () ->
      match make_exec ~argv:["echo"] ~cwd:root_cwd ~timeout:600.0 () with
      | Exec { timeout; _ } ->
        Alcotest.(check (float 0.001)) "timeout=600.0 ok" 600.0 timeout
      | _ -> Alcotest.fail "expected Exec");

    Alcotest.test_case "validate_argv rejects empty" `Quick (fun () ->
      match validate_argv [] with
      | Error (Types.Invalid_input "empty argv") -> ()
      | Ok () -> Alcotest.fail "expected Error for empty argv"
      | Error e -> Alcotest.failf "wrong error: %s" (error_to_string e));

    Alcotest.test_case "validate_argv rejects NUL byte" `Quick (fun () ->
      match validate_argv ["echo"; "hello\000world"] with
      | Error (Types.Invalid_input "NUL byte in argv") -> ()
      | Ok () -> Alcotest.fail "expected Error for NUL byte"
      | Error e -> Alcotest.failf "wrong error: %s" (error_to_string e));

    Alcotest.test_case "validate_argv rejects length > 4096" `Quick (fun () ->
      let argv = List.init 4097 (fun i -> Printf.sprintf "arg%d" i) in
      match validate_argv argv with
      | Error (Types.Invalid_input "argv too long") -> ()
      | Ok () -> Alcotest.fail "expected Error for length > 4096"
      | Error e -> Alcotest.failf "wrong error: %s" (error_to_string e));

    Alcotest.test_case "validate_argv accepts well-formed" `Quick (fun () ->
      match validate_argv ["ls"; "-la"; "src"] with
      | Ok () -> ()
      | Error e -> Alcotest.failf "expected Ok, got %s" (error_to_string e));

    Alcotest.test_case "make_pipeline of [No_op; exec_echo]" `Quick (fun () ->
      let echo = make_exec ~argv:["echo"; "hi"] ~cwd:root_cwd () in
      let pipe = make_pipeline [No_op; echo] in
      match pipe with
      | Pipeline [No_op; Exec { argv = ["echo"; "hi"]; _ }] -> ()
      | _ -> Alcotest.fail "pipeline did not preserve structure");
  ])

let assess_risk_suite =
  ("assess_risk", [
    Alcotest.test_case "No_op = Low" `Quick (fun () ->
      Alcotest.(check string) "Low" "Low" (risk_to_string (assess_risk No_op)));

    Alcotest.test_case "Exec {argv=[rm;-rf;/]} = High" `Quick (fun () ->
      let cmd = make_exec ~argv:["rm"; "-rf"; "/"] ~cwd:root_cwd () in
      Alcotest.(check string) "High" "High" (risk_to_string (assess_risk cmd)));

    Alcotest.test_case "Exec {argv=[echo;hello]} = Low" `Quick (fun () ->
      let cmd = make_exec ~argv:["echo"; "hello"] ~cwd:root_cwd () in
      Alcotest.(check string) "Low" "Low" (risk_to_string (assess_risk cmd)));

    Alcotest.test_case "Exec {argv=[sudo;rm]} = Medium" `Quick (fun () ->
      let cmd = make_exec ~argv:["sudo"; "rm"] ~cwd:root_cwd () in
      Alcotest.(check string) "Medium" "Medium" (risk_to_string (assess_risk cmd)));

    Alcotest.test_case "Exec {argv=[su -; ls]} = Medium" `Quick (fun () ->
      let cmd = make_exec ~argv:["su -"; "ls"] ~cwd:root_cwd () in
      Alcotest.(check string) "Medium" "Medium" (risk_to_string (assess_risk cmd)));

    Alcotest.test_case "Exec {argv=[/bin/rm; -rf]} = High (basename match)" `Quick (fun () ->
      let cmd = make_exec ~argv:["/bin/rm"; "-rf"] ~cwd:root_cwd () in
      Alcotest.(check string) "High" "High" (risk_to_string (assess_risk cmd)));

    Alcotest.test_case "Exec {timeout=200.0} = Medium" `Quick (fun () ->
      let cmd = make_exec ~argv:["sleep"; "100"] ~cwd:root_cwd ~timeout:200.0 () in
      Alcotest.(check string) "Medium" "Medium" (risk_to_string (assess_risk cmd)));

    Alcotest.test_case "Pipeline _ = Medium" `Quick (fun () ->
      let pipe = make_pipeline [No_op; make_exec ~argv:["echo"; "hi"] ~cwd:root_cwd ()] in
      Alcotest.(check string) "Medium" "Medium" (risk_to_string (assess_risk pipe)));

    Alcotest.test_case "Pipeline of rm + echo = Medium (not High)" `Quick (fun () ->
      let pipe = make_pipeline [make_exec ~argv:["rm"; "-rf"] ~cwd:root_cwd (); No_op] in
      Alcotest.(check string) "Medium" "Medium" (risk_to_string (assess_risk pipe)));

    Alcotest.test_case "risk_to_string round-trips all 4" `Quick (fun () ->
      Alcotest.(check string) "Low" "Low" (risk_to_string Low);
      Alcotest.(check string) "Medium" "Medium" (risk_to_string Medium);
      Alcotest.(check string) "High" "High" (risk_to_string High);
      Alcotest.(check string) "Critical" "Critical" (risk_to_string Critical));
  ])

let () =
  Alcotest.run "bash_safe_command" [
    sandboxed_path_suite;
    command_suite;
    assess_risk_suite;
  ]
