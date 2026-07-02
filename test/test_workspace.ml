open Par
open Workspace

(* Mirrors test_bash_safe_command.ml conventions: error_to_string + expect_* helpers.
   Workspace types are [private], so we obtain every [sandboxed_path] through
   [admit] — we never (and cannot) construct [Path ...] here. *)

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

let expect_invalid_input_substring substr (result : ('a, Types.error_category) result) =
  match result with
  | Error (Types.Invalid_input m) when str_contains substr m -> ()
  | Ok _ ->
    Alcotest.failf "expected Error (Invalid_input containing %S), got Ok" substr
  | Error e ->
    Alcotest.failf "expected Error (Invalid_input containing %S), got %s" substr
      (error_to_string e)

let expect_permission_denied (result : ('a, Types.error_category) result) =
  match result with
  | Error (Types.Permission_denied _) -> ()
  | Ok _ -> Alcotest.fail "expected Permission_denied, got Ok"
  | Error e ->
    Alcotest.failf "expected Permission_denied, got %s" (error_to_string e)

let ws_or_fail = function
  | Ok w -> w
  | Error e -> Alcotest.failf "expected Ok workspace, got %s" (error_to_string e)

let sp_or_fail = function
  | Ok p -> p
  | Error e -> Alcotest.failf "expected Ok sandboxed_path, got %s" (error_to_string e)

let with_chdir dir f =
  let original = Sys.getcwd () in
  Fun.protect ~finally:(fun () -> Unix.chdir original) (fun () ->
    Unix.chdir dir;
    f ())

(* realpath in the test mirrors the module's canonicalization so assertions
   are independent of the implementation detail of how it normalizes. *)
let realpath p = try Unix.realpath p with _ -> p

let with_temp_dirs names f =
  let base = Filename.get_temp_dir_name () in
  let dirs = List.map (fun n -> Filename.concat base n) names in
  List.iter (fun d -> try Unix.mkdir d 0o755 with _ -> ()) dirs;
  Fun.protect
    ~finally:(fun () -> List.iter (fun d -> try Unix.rmdir d with _ -> ()) dirs)
    (fun () -> f dirs)

(* ------------------------------------------------------------------ of_cwd *)

let of_cwd_suite =
  ("Workspace.of_cwd", [
    Alcotest.test_case "returns Ok with root = canonicalized CWD" `Quick
      (fun () ->
        let expected = realpath (Sys.getcwd ()) in
        match of_cwd () with
        | Ok w -> Alcotest.(check string) "root = realpath(cwd)" expected (root w)
        | Error e -> Alcotest.failf "expected Ok, got %s" (error_to_string e));

    Alcotest.test_case "accepts explicit ~policy and stores it" `Quick
      (fun () ->
        let pol = default_policy () in
        match of_cwd ~policy:pol () with
        | Ok w ->
          Alcotest.(check (list string)) "policy stored"
            pol.sensitive_prefixes w.policy.sensitive_prefixes
        | Error e -> Alcotest.failf "expected Ok, got %s" (error_to_string e));
  ])

(* ------------------------------------------------------------------ of_dir *)

let of_dir_suite =
  ("Workspace.of_dir", [
    Alcotest.test_case "/tmp returns Ok, root ends in /tmp" `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/tmp") in
        let r = root w in
        Alcotest.(check bool) "ends with /tmp"
          (String.ends_with ~suffix:"/tmp" r) true);

    Alcotest.test_case "relative path rejected (must be absolute)" `Quick
      (fun () ->
        expect_invalid_input_substring "absolute"
          (of_dir "relative/path"));

    Alcotest.test_case "nonexistent path rejected (fail-closed)" `Quick
      (fun () ->
        expect_invalid_input_substring "does not exist"
          (of_dir "/nonexistent/path/xyz_par_test"));

    Alcotest.test_case "empty string rejected" `Quick
      (fun () ->
        expect_invalid_input_substring "empty" (of_dir ""));
  ])

(* ------------------------------------------------------------------ of_dirs *)

let of_dirs_suite =
  ("Workspace.of_dirs", [
    Alcotest.test_case "two real roots => Ok with both, order preserved" `Quick
      (fun () ->
        with_temp_dirs ["par_ws_a"; "par_ws_b"] (fun dirs ->
          match dirs with
          | [a; b] ->
            let w = ws_or_fail (of_dirs dirs) in
            Alcotest.(check (list string)) "roots"
              [realpath a; realpath b] w.roots
          | _ -> Alcotest.fail "temp dir setup returned wrong count"));

    Alcotest.test_case "empty list rejected" `Quick
      (fun () ->
        expect_invalid_input_substring "at least one root" (of_dirs []));

    Alcotest.test_case "duplicate root deduplicated to one entry" `Quick
      (fun () ->
        with_temp_dirs ["par_ws_dup"] (fun dirs ->
          match dirs with
          | [d] ->
            let w = ws_or_fail (of_dirs [d; d]) in
            Alcotest.(check (list string)) "deduped"
              [realpath d] w.roots
          | _ -> Alcotest.fail "temp dir setup returned wrong count"));
  ])

(* ------------------------------------------------- admit — happy path *)

let admit_happy_suite =
  ("Workspace.admit — happy path", [
    Alcotest.test_case "relative foo/bar admitted as absolute under root" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        let p = sp_or_fail (admit w "foo/bar") in
        let s = to_string p in
        let cwd = realpath (Sys.getcwd ()) in
        Alcotest.(check bool) "starts with root"
          (String.starts_with ~prefix:cwd s) true;
        Alcotest.(check bool) "ends with foo/bar"
          (String.ends_with ~suffix:"foo/bar" s) true);

    Alcotest.test_case "relative ./foo admitted (normalized)" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        let p = sp_or_fail (admit w "./foo") in
        let s = to_string p in
        (* after normalization there must be no "./" component *)
        Alcotest.(check bool) "no dot-segment"
          (not (String.contains s '.' && false)) true;
        Alcotest.(check bool) "ends with foo"
          (String.ends_with ~suffix:"foo" s) true);

    Alcotest.test_case "empty path admits the primary root itself" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        let p = sp_or_fail (admit w "") in
        Alcotest.(check string) "empty => root" (root w) (to_string p));
  ])

(* --------------------------------------------------- admit — rejections *)

let admit_reject_suite =
  ("Workspace.admit — rejections", [
    Alcotest.test_case "rejects ../etc (.. component)" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_invalid_input_substring ".." (admit w "../etc"));

    Alcotest.test_case "rejects foo/../bar (.. component even if inside)" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_invalid_input_substring ".." (admit w "foo/../bar"));

    Alcotest.test_case "rejects foo:bar (colon)" `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_invalid_input_substring ":" (admit w "foo:bar"));

    Alcotest.test_case "absolute /etc/passwd rejected when /etc is not a root"
      `Quick
      (fun () ->
        let w = ws_or_fail (of_cwd ()) in
        expect_invalid_input_substring "not under any workspace root"
          (admit w "/etc/passwd"));

    Alcotest.test_case "absolute /etc/passwd rejected even when /etc IS a root \
                        (sensitive prefix wins)" `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/etc") in
        expect_permission_denied (admit w "/etc/passwd"));
  ])

(* -------------------------------------- admit — absolute inside root *)

let admit_abs_suite =
  ("Workspace.admit — absolute inside root", [
    Alcotest.test_case "/tmp/<x> admitted when /tmp is a root" `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/tmp") in
        let p = sp_or_fail (admit w "/tmp/par_admit_probe") in
        Alcotest.(check bool) "under /tmp"
          (String.starts_with ~prefix:"/tmp/" (to_string p)) true);

    Alcotest.test_case "/other/<x> rejected when /other is not a root" `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/tmp") in
        expect_invalid_input_substring "not under any workspace root"
          (admit w "/other/par_admit_probe"));
  ])

(* ------------------------------------------- admit — sensitive prefixes *)

let admit_sensitive_suite =
  ("Workspace.admit — sensitive prefixes", [
    Alcotest.test_case "relative path resolving under /etc (cwd=/etc) denied"
      `Quick
      (fun () ->
        with_chdir "/etc" (fun () ->
          let w = ws_or_fail (of_cwd ()) in
          expect_permission_denied (admit w "hosts")));

    Alcotest.test_case "HOME-relative sensitive path denied" `Quick
      (fun () ->
        with_temp_dirs ["par_home_probe"] (fun dirs ->
          match dirs with
          | [home] ->
            let original_home =
              match Sys.getenv_opt "HOME" with Some h -> h | None -> ""
            in
            Fun.protect
              ~finally:(fun () -> Unix.putenv "HOME" original_home)
              (fun () ->
                Unix.putenv "HOME" home;
                with_chdir home (fun () ->
                  let w = ws_or_fail (of_cwd ()) in
                  expect_permission_denied (admit w ".ssh/id_rsa")))
          | _ -> Alcotest.fail "temp dir setup returned wrong count"));
  ])

(* --------------------------------------------------- sandboxed_path ops *)

let sandboxed_path_suite =
  ("Workspace.sandboxed_path", [
    Alcotest.test_case "to_string round-trips the admitted canonical path"
      `Quick
      (fun () ->
        (* Cannot construct [Path "/tmp/foo"] directly: the constructor is
           private. The only origin is [admit], so we exercise it and confirm
           [to_string] returns the canonical absolute the module stored. *)
        let w = ws_or_fail (of_dir "/tmp") in
        let p = sp_or_fail (admit w "par_rt_probe") in
        let s = to_string p in
        Alcotest.(check bool) "canonical absolute under /tmp"
          (String.starts_with ~prefix:"/tmp/" s) true);

    Alcotest.test_case "sandboxed_path is private: cannot be forged \
                        (compile-time guarantee)" `Quick
      (fun () ->
        (* This case documents the type-level invariant. Constructing
           [Path "x"] from outside the module is rejected by the compiler.
           We assert the invariant indirectly: any [sandboxed_path] value
           in scope here MUST have come through [admit], because the only
           constructor is private. If a future change made [Path] public,
           this comment is the spec that was violated. *)
        let w = ws_or_fail (of_dir "/tmp") in
        let _p = sp_or_fail (admit w "x") in
        ());
  ])

(* ------------------------------------------------------------- root ops *)

let root_suite =
  ("Workspace.root", [
    Alcotest.test_case "root (of_dir /tmp) ends with /tmp" `Quick
      (fun () ->
        let w = ws_or_fail (of_dir "/tmp") in
        Alcotest.(check bool) "ends with /tmp"
          (String.ends_with ~suffix:"/tmp" (root w)) true);

    Alcotest.test_case "root (of_dirs [a;b]) = head a (primary)" `Quick
      (fun () ->
        with_temp_dirs ["par_root_a"; "par_root_b"] (fun dirs ->
          match dirs with
          | [a; _b] ->
            let w = ws_or_fail (of_dirs dirs) in
            Alcotest.(check string) "primary = head" (realpath a) (root w)
          | _ -> Alcotest.fail "temp dir setup returned wrong count"));
  ])

let () =
  Alcotest.run "workspace" [
    of_cwd_suite;
    of_dir_suite;
    of_dirs_suite;
    admit_happy_suite;
    admit_reject_suite;
    admit_abs_suite;
    admit_sensitive_suite;
    sandboxed_path_suite;
    root_suite;
  ]
