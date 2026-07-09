open Par
open Workspace

(* Golden-case tests for Windows path/env normalization (Wave 2).
   Tests behavior through the PUBLIC interface (admit, of_dir, default_policy)
   rather than internal helpers.

   Strategy for verifying Windows behavior on a Linux test machine:
   - is_absolute_path: tested via of_dir error messages. A path recognized as
     absolute gets "does not exist" (file_exists fails); a relative path gets
     "must be absolute".
   - has_suspicious_colon: tested via admit error messages. foo:bar yields a
     colon error; C:\Users\foo yields a DIFFERENT error (not colon).
   - get_home_dir: tested via default_policy sensitive_prefixes, which are
     derived from the resolved home directory. *)

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid_input %S" s
  | Types.External_failure s -> Printf.sprintf "External_failure %S" s
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission_denied %S" s
  | Types.Internal s -> Printf.sprintf "Internal %S" s
  | Types.Embedding_unsupported -> "Embedding_unsupported"

let str_contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  if n = 0 then true
  else if n > h then false
  else
    let rec loop i =
      if i + n > h then false
      else if String.sub haystack i n = needle then true
      else loop (i + 1)
    in
    loop 0

let ws_or_fail = function
  | Ok w -> w
  | Error e -> Alcotest.failf "expected Ok workspace, got %s" (error_to_string e)

let sp_or_fail = function
  | Ok p -> p
  | Error e -> Alcotest.failf "expected Ok sandboxed_path, got %s" (error_to_string e)

let expect_error_substring substr (result : ('a, Types.error_category) result) =
  match result with
  | Error (Types.Invalid_input m) when str_contains substr m -> ()
  | Error (Types.Permission_denied m) when str_contains substr m -> ()
  | Ok _ ->
    Alcotest.failf "expected Error containing %S, got Ok" substr
  | Error e ->
    Alcotest.failf "expected Error containing %S, got %s" substr
      (error_to_string e)

let expect_error_not_substring substr (result : ('a, Types.error_category) result) =
  match result with
  | Error (Types.Invalid_input m) when not (str_contains substr m) -> ()
  | Error (Types.Permission_denied m) when not (str_contains substr m) -> ()
  | Ok _ ->
    Alcotest.failf "expected Error NOT containing %S, got Ok" substr
  | Error e ->
    Alcotest.failf "expected Error NOT containing %S, got %s" substr
      (error_to_string e)

let expect_ok (result : ('a, Types.error_category) result) =
  match result with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "expected Ok, got %s" (error_to_string e)

let with_home_env ~home ~userprofile ~homedrive ~homepath f =
  let vars = ["HOME", home; "USERPROFILE", userprofile;
              "HOMEDRIVE", homedrive; "HOMEPATH", homepath] in
  let originals = List.map (fun (n, _) -> (n, Sys.getenv_opt n)) vars in
  List.iter (fun (n, v) -> Unix.putenv n v) vars;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (n, orig) ->
          match orig with
          | Some v -> Unix.putenv n v
          | None -> Unix.putenv n "")
        originals)
    f

(* ================================ is_absolute_path ==================== *)

let absolute_detection_suite =
  ("is_absolute_path (via of_dir)", [
    Alcotest.test_case "Unix /etc subdir is absolute" `Quick
      (fun () ->
        expect_error_substring "does not exist"
          (of_dir "/etc/nonexistent_par_probe_xyz"));

    Alcotest.test_case "Unix relative path is NOT absolute" `Quick
      (fun () ->
        expect_error_substring "absolute" (of_dir "relative/path"));

    Alcotest.test_case "Windows drive C:\\... is absolute (not relative)"
      `Quick
      (fun () ->
        expect_error_substring "does not exist"
          (of_dir "C:\\Users\\foo"));

    Alcotest.test_case "Windows drive C:/... is absolute (forward-slash)"
      `Quick
      (fun () ->
        expect_error_substring "does not exist"
          (of_dir "C:/Users/foo"));

    Alcotest.test_case "UNC \\\\server\\share is absolute" `Quick
      (fun () ->
        expect_error_substring "does not exist"
          (of_dir "\\\\server\\share"));

    Alcotest.test_case "lowercase drive d:\\ is absolute" `Quick
      (fun () ->
        expect_error_substring "does not exist"
          (of_dir "d:\\Users\\foo"));

    Alcotest.test_case "Windows relative foo\\bar is NOT absolute" `Quick
      (fun () ->
        expect_error_substring "absolute" (of_dir "foo\\bar"));

    Alcotest.test_case "bare drive letter C: is NOT absolute" `Quick
      (fun () ->
        expect_error_substring "absolute" (of_dir "C:"));
  ])

(* ================================ has_suspicious_colon ================= *)

let colon_rejection_suite =
  ("has_suspicious_colon (via admit)", [
    Alcotest.test_case "foo:bar rejected for colon" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_error_substring ":" (admit w "foo:bar"));

    Alcotest.test_case "http://example rejected for colon" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_error_substring ":" (admit w "http://example.com"));

    Alcotest.test_case "C:\\Users\\foo NOT rejected for colon" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_error_not_substring ":" (admit w "C:\\Users\\foo"));

    Alcotest.test_case "C:/Users/foo NOT rejected for colon" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_error_not_substring ":" (admit w "C:/Users/foo"));

    Alcotest.test_case "C:\\foo:bar rejected (second colon)" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_error_substring ":" (admit w "C:\\foo:bar"));

    Alcotest.test_case "colon at position 0 rejected (:foo)" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_error_substring ":" (admit w ":foo"));

    Alcotest.test_case "no colon — admitted normally" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_ok (admit w "normal/path/no/colon"));
  ])

(* ================================ has_parent_component ================= *)

let parent_component_suite =
  ("has_parent_component (via admit)", [
    Alcotest.test_case "Unix .. rejected" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_error_substring ".." (admit w "../etc"));

    Alcotest.test_case "Unix foo/../bar rejected" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_error_substring ".." (admit w "foo/../bar"));

    Alcotest.test_case "Windows backslash ..\\ rejected" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_error_substring ".." (admit w "foo\\..\\bar"));

    Alcotest.test_case "Windows drive path with .. rejected" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_error_substring ".." (admit w "C:\\Users\\..\\etc"));

    Alcotest.test_case "double-dot substring without separator is fine" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_ok (admit w "foo..bar"));
  ])

(* ================================ get_home_dir ========================= *)

let home_resolution_suite =
  ("get_home_dir (via default_policy)", [
    Alcotest.test_case "HOME set → prefixes derived from HOME" `Quick
      (fun () ->
        with_home_env
          ~home:"/tmp/par_home_probe_1"
          ~userprofile:"" ~homedrive:"" ~homepath:""
          (fun () ->
            let pol = default_policy () in
            let has_home_ssh =
              List.exists
                (fun p -> str_contains "/tmp/par_home_probe_1" p)
                pol.sensitive_prefixes
            in
            Alcotest.(check bool) "HOME-based prefix present" true has_home_ssh));

    Alcotest.test_case "HOME empty → falls back to USERPROFILE" `Quick
      (fun () ->
        with_home_env
          ~home:""
          ~userprofile:"/tmp/par_home_probe_2"
          ~homedrive:"" ~homepath:""
          (fun () ->
            let pol = default_policy () in
            let has_userprofile_ssh =
              List.exists
                (fun p -> str_contains "/tmp/par_home_probe_2" p)
                pol.sensitive_prefixes
            in
            Alcotest.(check bool)
              "USERPROFILE-based prefix present" true has_userprofile_ssh));

    Alcotest.test_case "HOME empty + USERPROFILE empty → HOMEDRIVE+HOMEPATH"
      `Quick
      (fun () ->
        with_home_env
          ~home:"" ~userprofile:""
          ~homedrive:"C:"
          ~homepath:"\\Users\\par_probe_4"
          (fun () ->
            let pol = default_policy () in
            let combined = "C:\\Users\\par_probe_4" in
            let has_combined =
              List.exists
                (fun p -> str_contains combined p)
                pol.sensitive_prefixes
            in
            Alcotest.(check bool)
              "HOMEDRIVE+HOMEPATH-based prefix present"
              true has_combined));

    Alcotest.test_case "all empty → only absolute prefixes" `Quick
      (fun () ->
        with_home_env
          ~home:"" ~userprofile:"" ~homedrive:"" ~homepath:""
          (fun () ->
            let pol = default_policy () in
            let count = List.length pol.sensitive_prefixes in
            Alcotest.(check int)
              "only absolute prefixes (5)" 5 count;
            Alcotest.(check bool)
              "/etc present"
              (List.mem "/etc" pol.sensitive_prefixes) true));

    Alcotest.test_case "Windows USERPROFILE with backslash" `Quick
      (fun () ->
        with_home_env
          ~home:""
          ~userprofile:"C:\\Users\\par_probe_5"
          ~homedrive:"" ~homepath:""
          (fun () ->
            let pol = default_policy () in
            let has_win_home =
              List.exists
                (fun p -> str_contains "C:\\Users\\par_probe_5" p)
                pol.sensitive_prefixes
            in
            Alcotest.(check bool)
              "Windows USERPROFILE prefix present" true has_win_home));
  ])

(* ================================ admit integration ==================== *)

let admit_integration_suite =
  ("admit — cross-platform integration", [
    Alcotest.test_case "Unix /tmp/x admitted when /tmp is root" `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/tmp") in
        let p = sp_or_fail (admit w "/tmp/par_ws_probe_ok") in
        Alcotest.(check bool) "under /tmp"
          (String.starts_with ~prefix:"/tmp/" (to_string p)) true);

    Alcotest.test_case "C:\\... treated as absolute (not relative to root)"
      `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/tmp") in
        expect_error_substring "not under any workspace root"
          (admit w "C:\\Users\\foo"));

    Alcotest.test_case "UNC \\\\server\\share treated as absolute" `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/tmp") in
        expect_error_substring "not under any workspace root"
          (admit w "\\\\server\\share"));

    Alcotest.test_case "relative path admitted under root" `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/tmp") in
        expect_ok (admit w "par_probe_rel"));

    Alcotest.test_case "empty path admits the primary root" `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/tmp") in
        let p = sp_or_fail (admit w "") in
        let s = to_string p in
        Alcotest.(check bool) "root or under /tmp"
          (String.starts_with ~prefix:"/tmp" s) true);

    Alcotest.test_case "/etc/passwd denied by sensitive prefix" `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/etc") in
        match admit w "/etc/passwd" with
        | Error (Types.Permission_denied _) -> ()
        | other ->
          Alcotest.failf "expected Permission_denied, got %s"
            (error_to_string
               (match other with Error e -> e | Ok _ -> Types.Timeout)));
  ])

let () =
  Alcotest.run "workspace_paths" [
    absolute_detection_suite;
    colon_rejection_suite;
    parent_component_suite;
    home_resolution_suite;
    admit_integration_suite;
  ]
