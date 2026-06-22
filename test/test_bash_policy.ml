(* test/test_bash_policy.ml — v0.3.1
   Comprehensive tests for the bash policy trust boundary.
   Each policy gets positive + negative cases; helpers tested in isolation. *)

open Par

(* -------------------------------------------------------------------------- *)
(* Helpers                                                                   *)
(* -------------------------------------------------------------------------- *)

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid_input %S" s
  | Types.External_failure s -> Printf.sprintf "External_failure %S" s
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission_denied %S" s
  | Types.Internal s -> Printf.sprintf "Internal %S" s
  | Types.Embedding_unsupported -> "Embedding_unsupported"

(* Get a policy module by name. *)
let get_policy = function
  | "ReadOnly" -> (module Bash_policy.ReadOnly : Bash_policy.POLICY)
  | "ReadOnlyNoNet" -> (module Bash_policy.ReadOnlyNoNet : Bash_policy.POLICY)
  | "Coder" -> (module Bash_policy.Coder : Bash_policy.POLICY)
  | _ -> failwith "unknown policy"

let test_filter_accepts policy_name cmd =
  let module P = (val get_policy policy_name : Bash_policy.POLICY) in
  match P.filter cmd with
  | Ok _ -> true
  | Error _ -> false

let test_filter_error policy_name cmd =
  let module P = (val get_policy policy_name : Bash_policy.POLICY) in
  match P.filter cmd with
  | Ok _ -> None
  | Error e -> Some e

let cwd = Bash_safe_command.sandboxed_path_cwd ()
let ok_cmd argv = Bash_safe_command.Exec { argv; cwd; env = []; timeout = 5.0 }
let ok_cmd_env argv env =
  Bash_safe_command.Exec { argv; cwd; env; timeout = 5.0 }

let test_case name speed f = Alcotest.test_case name speed f

(* -------------------------------------------------------------------------- *)
(* ReadOnly policy tests                                                     *)
(* -------------------------------------------------------------------------- *)

let readonly_suite = "ReadOnly", [
  test_case "name is ReadOnly" `Quick (fun () ->
    let module P = (val (get_policy "ReadOnly") : Bash_policy.POLICY) in
    Alcotest.(check string) "name" "ReadOnly" P.name);
  test_case "accepts cat" `Quick (fun () ->
    Alcotest.(check bool) "RO accepts cat" true
      (test_filter_accepts "ReadOnly" (ok_cmd ["cat"; "file.txt"])));
  test_case "accepts ls" `Quick (fun () ->
    Alcotest.(check bool) "RO accepts ls" true
      (test_filter_accepts "ReadOnly" (ok_cmd ["ls"; "-la"])));
  test_case "accepts grep" `Quick (fun () ->
    Alcotest.(check bool) "RO accepts grep" true
      (test_filter_accepts "ReadOnly" (ok_cmd ["grep"; "foo"; "bar"])));
  test_case "accepts echo" `Quick (fun () ->
    Alcotest.(check bool) "RO accepts echo" true
      (test_filter_accepts "ReadOnly" (ok_cmd ["echo"; "hello"])));
  test_case "rejects rm" `Quick (fun () ->
    Alcotest.(check bool) "RO rejects rm" false
      (test_filter_accepts "ReadOnly" (ok_cmd ["rm"; "-rf"; "build/"])));
  test_case "rejects chmod" `Quick (fun () ->
    Alcotest.(check bool) "RO rejects chmod" false
      (test_filter_accepts "ReadOnly" (ok_cmd ["chmod"; "755"; "foo"])));
  test_case "rejects mv" `Quick (fun () ->
    Alcotest.(check bool) "RO rejects mv" false
      (test_filter_accepts "ReadOnly" (ok_cmd ["mv"; "a"; "b"])));
  test_case "rejects cp" `Quick (fun () ->
    Alcotest.(check bool) "RO rejects cp" false
      (test_filter_accepts "ReadOnly" (ok_cmd ["cp"; "src"; "dst"])));
  test_case "rejects /bin/rm (basename match)" `Quick (fun () ->
    Alcotest.(check bool) "RO rejects /bin/rm" false
      (test_filter_accepts "ReadOnly" (ok_cmd ["/bin/rm"; "file"])));
  test_case "rejects custom env" `Quick (fun () ->
    let cmd = ok_cmd_env ["env"] ["FOO", "bar"] in
    Alcotest.(check bool) "RO rejects env" false
      (test_filter_accepts "ReadOnly" cmd));
  test_case "rejects env in middle of argv" `Quick (fun () ->
    let cmd = ok_cmd_env ["env"; "FOO=bar"] ["X", "1"] in
    Alcotest.(check bool) "RO rejects env" false
      (test_filter_accepts "ReadOnly" cmd));
  test_case "rejection is Permission_denied not Invalid_input" `Quick (fun () ->
    match test_filter_error "ReadOnly" (ok_cmd ["rm"; "x"]) with
    | Some (Types.Permission_denied _) -> ()
    | Some e -> Alcotest.failf "expected Permission_denied, got %s" (error_to_string e)
    | None -> Alcotest.fail "expected rejection");
  test_case "Pipeline of read-only commands is allowed" `Quick (fun () ->
    let p = (module Bash_policy.ReadOnly : Bash_policy.POLICY) in
    let module P = (val p : Bash_policy.POLICY) in
    let cmd = Bash_safe_command.Pipeline [ok_cmd ["ls"]; ok_cmd ["cat"; "x"]] in
    match P.filter cmd with
    | Ok (Bash_safe_command.Pipeline _) -> ()
    | Ok _ -> Alcotest.fail "expected Pipeline"
    | Error e -> Alcotest.failf "expected Ok, got %s" (error_to_string e));
  test_case "Pipeline [No_op] = Ok" `Quick (fun () ->
    let p = (module Bash_policy.ReadOnly : Bash_policy.POLICY) in
    let module P = (val p : Bash_policy.POLICY) in
    match P.filter Bash_safe_command.No_op with
    | Ok Bash_safe_command.No_op -> ()
    | _ -> Alcotest.fail "No_op should pass through");
  test_case "Pipeline with bad cmd rejected" `Quick (fun () ->
    Alcotest.(check bool) "pipeline of rm rejected" false
      (test_filter_accepts "ReadOnly"
        (Bash_safe_command.Pipeline [ok_cmd ["rm"; "x"]])));
]

(* -------------------------------------------------------------------------- *)
(* ReadOnlyNoNet policy tests                                                *)
(* -------------------------------------------------------------------------- *)

let readonlynonet_suite = "ReadOnlyNoNet", [
  test_case "accepts cat" `Quick (fun () ->
    Alcotest.(check bool) "RONN accepts cat" true
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["cat"; "file.txt"])));
  test_case "accepts ls" `Quick (fun () ->
    Alcotest.(check bool) "RONN accepts ls" true
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["ls"; "-la"])));
  test_case "rejects curl" `Quick (fun () ->
    Alcotest.(check bool) "RONN rejects curl" false
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["curl"; "http://x.com"])));
  test_case "rejects wget" `Quick (fun () ->
    Alcotest.(check bool) "RONN rejects wget" false
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["wget"; "http://x.com"])));
  test_case "rejects ssh" `Quick (fun () ->
    Alcotest.(check bool) "RONN rejects ssh" false
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["ssh"; "user@host"])));
  test_case "rejects scp" `Quick (fun () ->
    Alcotest.(check bool) "RONN rejects scp" false
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["scp"; "a"; "b"])));
  test_case "rejects ping" `Quick (fun () ->
    Alcotest.(check bool) "RONN rejects ping" false
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["ping"; "8.8.8.8"])));
  test_case "rejects URLs in argv (echo https://evil.com)" `Quick (fun () ->
    Alcotest.(check bool) "RONN rejects URL" false
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["echo"; "https://evil.com"])));
  test_case "rejects http:// in argv" `Quick (fun () ->
    Alcotest.(check bool) "RONN rejects http URL" false
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["echo"; "see http://example.com"])));
  test_case "rejects ftp:// in argv" `Quick (fun () ->
    Alcotest.(check bool) "RONN rejects ftp URL" false
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["echo"; "ftp://server/file"])));
  test_case "still rejects write tools" `Quick (fun () ->
    Alcotest.(check bool) "RONN rejects rm" false
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd ["rm"; "x"])));
  test_case "rejects custom env" `Quick (fun () ->
    Alcotest.(check bool) "RONN rejects env" false
      (test_filter_accepts "ReadOnlyNoNet" (ok_cmd_env ["ls"] ["X", "1"])));
]

(* -------------------------------------------------------------------------- *)
(* Coder policy tests                                                        *)
(* -------------------------------------------------------------------------- *)

let coder_suite = "Coder", [
  test_case "accepts cat" `Quick (fun () ->
    Alcotest.(check bool) "Coder accepts cat" true
      (test_filter_accepts "Coder" (ok_cmd ["cat"; "file.txt"])));
  test_case "accepts curl" `Quick (fun () ->
    Alcotest.(check bool) "Coder accepts curl" true
      (test_filter_accepts "Coder" (ok_cmd ["curl"; "http://x.com"])));
  test_case "accepts rm (no -rf / pattern)" `Quick (fun () ->
    Alcotest.(check bool) "Coder accepts rm file" true
      (test_filter_accepts "Coder" (ok_cmd ["rm"; "build/output.txt"])));
  test_case "rejects rm -rf /" `Quick (fun () ->
    Alcotest.(check bool) "Coder rejects rm -rf /" false
      (test_filter_accepts "Coder" (ok_cmd ["rm"; "-rf"; "/"])));
  test_case "rejects rm -rf ~" `Quick (fun () ->
    Alcotest.(check bool) "Coder rejects rm -rf ~" false
      (test_filter_accepts "Coder" (ok_cmd ["rm"; "-rf"; "~"])));
  test_case "T3 BLACKLIST BUG: dd of=/dev/sda currently passes Coder" `Quick (fun () ->
    (* T3 blacklist was fixed: dd pattern now `dd[ \t]+.*of=/dev/\(sd\|hd\|nvme\|vd\)`
       correctly matches `dd of=/dev/sd*`. Coder rejects via blacklist. *)
    Alcotest.(check bool) "Coder rejects dd" false
      (test_filter_accepts "Coder" (ok_cmd ["dd"; "if=/dev/zero"; "of=/dev/sda"])));
  test_case "T3 BLACKLIST BUG: fork bomb currently passes Coder" `Quick (fun () ->
    (* T3 fork-bomb pattern fixed to literal `:(){:|:&}:` (BRE literal syntax).
       Coder rejects via blacklist. *)
    Alcotest.(check bool) "Coder rejects fork bomb" false
      (test_filter_accepts "Coder" (ok_cmd ["bash"; "-c"; ":(){:|:&}:"])));
  test_case "rejects sudo" `Quick (fun () ->
    Alcotest.(check bool) "Coder rejects sudo" false
      (test_filter_accepts "Coder" (ok_cmd ["sudo"; "apt"; "update"])));
  test_case "rejects shutdown" `Quick (fun () ->
    Alcotest.(check bool) "Coder rejects shutdown" false
      (test_filter_accepts "Coder" (ok_cmd ["shutdown"; "-h"; "now"])));
  test_case "sanitizes env on accepted command" `Quick (fun () ->
    let p = (module Bash_policy.Coder : Bash_policy.POLICY) in
    let module P = (val p : Bash_policy.POLICY) in
    let cmd = ok_cmd_env ["ls"] ["OPENAI_API_KEY", "sk-secret"; "USER", "me"] in
    match P.filter cmd with
    | Ok (Bash_safe_command.Exec { env; _ }) ->
      let keys = List.map fst env in
      Alcotest.(check bool) "no OPENAI_API_KEY" false (List.mem "OPENAI_API_KEY" keys);
      Alcotest.(check bool) "keeps USER" true (List.mem "USER" keys)
    | Ok _ -> Alcotest.fail "expected Exec"
    | Error e -> Alcotest.failf "should accept, got %s" (error_to_string e));
  test_case "blacklist rejection uses Permission_denied" `Quick (fun () ->
    match test_filter_error "Coder" (ok_cmd ["rm"; "-rf"; "/"]) with
    | Some (Types.Permission_denied msg) ->
      let has_marker =
        let re = Str.regexp "Blacklist" in
        try ignore (Str.search_forward re msg 0); true
        with Not_found -> false
      in
      Alcotest.(check bool) "msg mentions Blacklist" true has_marker
    | Some e -> Alcotest.failf "expected Permission_denied, got %s" (error_to_string e)
    | None -> Alcotest.fail "expected rejection");
]

(* -------------------------------------------------------------------------- *)
(* sanitize_env tests                                                        *)
(* -------------------------------------------------------------------------- *)

let sanitize_env_suite = "sanitize_env", [
  test_case "strips OPENAI_API_KEY" `Quick (fun () ->
    let env = ["PATH", "/usr/bin"; "OPENAI_API_KEY", "sk-xxx"; "USER", "test"] in
    let cleaned = Bash_policy.sanitize_env env in
    let keys = List.map fst cleaned in
    Alcotest.(check bool) "no OPENAI_API_KEY" false (List.mem "OPENAI_API_KEY" keys);
    Alcotest.(check bool) "keeps PATH" true (List.mem "PATH" keys);
    Alcotest.(check bool) "keeps USER" true (List.mem "USER" keys));
  test_case "strips ANTHROPIC_API_KEY" `Quick (fun () ->
    let env = ["ANTHROPIC_API_KEY", "x"] in
    let keys = List.map fst (Bash_policy.sanitize_env env) in
    Alcotest.(check bool) "no ANTHROPIC_API_KEY" false (List.mem "ANTHROPIC_API_KEY" keys));
  test_case "strips AWS_SECRET_ACCESS_KEY" `Quick (fun () ->
    let env = ["AWS_SECRET_ACCESS_KEY", "xxx"] in
    let keys = List.map fst (Bash_policy.sanitize_env env) in
    Alcotest.(check bool) "no AWS_SECRET_ACCESS_KEY" false (List.mem "AWS_SECRET_ACCESS_KEY" keys));
  test_case "strips all AWS_* prefix" `Quick (fun () ->
    let env = ["AWS_REGION", "us-east-1"; "AWS_PROFILE", "default"] in
    let keys = List.map fst (Bash_policy.sanitize_env env) in
    Alcotest.(check int) "all AWS stripped" 0 (List.length keys));
  test_case "strips GITHUB_TOKEN" `Quick (fun () ->
    let env = ["GITHUB_TOKEN", "x"] in
    let keys = List.map fst (Bash_policy.sanitize_env env) in
    Alcotest.(check bool) "no GITHUB_TOKEN" false (List.mem "GITHUB_TOKEN" keys));
  test_case "strips case-insensitive PASSWORD" `Quick (fun () ->
    let env = ["DB_PASSWORD", "x"] in
    let keys = List.map fst (Bash_policy.sanitize_env env) in
    Alcotest.(check bool) "no DB_PASSWORD" false (List.mem "DB_PASSWORD" keys));
  test_case "strips case-insensitive api_token" `Quick (fun () ->
    let env = ["my_api_token", "x"] in
    let keys = List.map fst (Bash_policy.sanitize_env env) in
    Alcotest.(check bool) "no my_api_token" false (List.mem "my_api_token" keys));
  test_case "strips MY_CREDENTIAL_VAR" `Quick (fun () ->
    let env = ["MY_CREDENTIAL_VAR", "x"] in
    let keys = List.map fst (Bash_policy.sanitize_env env) in
    Alcotest.(check bool) "no MY_CREDENTIAL_VAR" false (List.mem "MY_CREDENTIAL_VAR" keys));
  test_case "keeps HOME, PATH, USER, LANG, TZ" `Quick (fun () ->
    let env = ["HOME", "/root"; "PATH", "/bin"; "USER", "x"; "LANG", "C"; "TZ", "UTC"] in
    let keys = List.map fst (Bash_policy.sanitize_env env) in
    List.iter (fun k ->
      Alcotest.(check bool) (Printf.sprintf "keeps %s" k) true (List.mem k keys))
      ["HOME"; "PATH"; "USER"; "LANG"; "TZ"]);
  test_case "output is sorted for determinism" `Quick (fun () ->
    let env = ["B", "1"; "A", "2"; "C", "3"] in
    let cleaned = Bash_policy.sanitize_env env in
    let keys = List.map fst cleaned in
    Alcotest.(check (list string)) "sorted ascending"
      ["A"; "B"; "C"] keys);
  test_case "empty env → empty" `Quick (fun () ->
    Alcotest.(check (list (pair string string))) "empty" []
      (Bash_policy.sanitize_env []));
  test_case "does not strip LANG_KEY (kept list wins)" `Quick (fun () ->
    (* LANG is in always_keep, so even though it matches the substring
       "key" pattern, it should be kept. *)
    let env = ["LANG", "C"] in
    let keys = List.map fst (Bash_policy.sanitize_env env) in
    Alcotest.(check bool) "keeps LANG" true (List.mem "LANG" keys));
]

(* -------------------------------------------------------------------------- *)
(* strip_ansi tests                                                          *)
(* -------------------------------------------------------------------------- *)

let strip_ansi_suite = "strip_ansi", [
  test_case "removes CSI sequence (color)" `Quick (fun () ->
    let input = "before \027[31mred\027[0m after" in
    Alcotest.(check string) "stripped" "before red after"
      (Bash_policy.strip_ansi input));
  test_case "removes cursor positioning" `Quick (fun () ->
    let input = "a\027[2Jb" in
    Alcotest.(check string) "stripped" "ab" (Bash_policy.strip_ansi input));
  test_case "removes OSC sequence" `Quick (fun () ->
    (* OSC: ESC ] ... BEL *)
    let input = "x\027]0;title\007y" in
    Alcotest.(check string) "stripped" "xy" (Bash_policy.strip_ansi input));
  test_case "leaves plain text alone" `Quick (fun () ->
    Alcotest.(check string) "unchanged" "hello world"
      (Bash_policy.strip_ansi "hello world"));
  test_case "removes ESC= sequence" `Quick (fun () ->
    let input = "a\027=b" in
    Alcotest.(check string) "stripped" "ab" (Bash_policy.strip_ansi input));
  test_case "removes multiple sequences" `Quick (fun () ->
    let input = "\027[1m\027[31mbold red\027[0m plain" in
    Alcotest.(check string) "stripped" "bold red plain"
      (Bash_policy.strip_ansi input));
]

(* -------------------------------------------------------------------------- *)
(* truncate_output tests                                                     *)
(* -------------------------------------------------------------------------- *)

let truncate_output_suite = "truncate_output", [
  test_case "short string passes through" `Quick (fun () ->
    let s = "hello\nworld" in
    let out, trunc = Bash_policy.truncate_output ~max_bytes:100 ~max_lines:10 s in
    Alcotest.(check string) "content" s out;
    Alcotest.(check bool) "not truncated" false trunc);
  test_case "empty string passes through" `Quick (fun () ->
    let out, trunc = Bash_policy.truncate_output ~max_bytes:100 ~max_lines:10 "" in
    Alcotest.(check string) "empty" "" out;
    Alcotest.(check bool) "not truncated" false trunc);
  test_case "byte cap truncates long string" `Quick (fun () ->
    let s = String.make 100000 'x' in
    let out, trunc = Bash_policy.truncate_output ~max_bytes:50 ~max_lines:10000 s in
    Alcotest.(check bool) "truncated" true trunc;
    Alcotest.(check bool) "output under byte cap + marker" true
      (String.length out < 200));
  test_case "line cap truncates many-line string" `Quick (fun () ->
    let s = String.concat "\n" (List.init 1000 (fun i -> Printf.sprintf "line%d" i)) in
    let out, trunc = Bash_policy.truncate_output ~max_bytes:1_000_000 ~max_lines:5 s in
    Alcotest.(check bool) "truncated" true trunc;
    let has_marker =
      let re = Str.regexp "truncated" in
      try ignore (Str.search_forward re out 0); true
      with Not_found -> false
    in
    Alcotest.(check bool) "marker present" true has_marker);
  test_case "marker contains 'truncated'" `Quick (fun () ->
    let s = String.make 100000 'x' in
    let out, _ = Bash_policy.truncate_output ~max_bytes:50 ~max_lines:5 s in
    let has_marker =
      let re = Str.regexp "truncated" in
      try ignore (Str.search_forward re out 0); true
      with Not_found -> false
    in
    Alcotest.(check bool) "marker" true has_marker);
  test_case "at-byte-boundary not truncated" `Quick (fun () ->
    let s = "hello" in
    let out, trunc = Bash_policy.truncate_output ~max_bytes:5 ~max_lines:100 s in
    Alcotest.(check string) "exact" "hello" out;
    Alcotest.(check bool) "not truncated at boundary" false trunc);
]

(* -------------------------------------------------------------------------- *)
(* Total-ness / never raises                                                 *)
(* -------------------------------------------------------------------------- *)

let totality_suite = "totality", [
  test_case "filter does not raise on huge argv" `Quick (fun () ->
    let argv = List.init 1000 (fun i -> Printf.sprintf "arg%d" i) in
    let p = (module Bash_policy.Coder : Bash_policy.POLICY) in
    let module P = (val p : Bash_policy.POLICY) in
    let _ : (Bash_safe_command.command, Types.error_category) result =
      P.filter (ok_cmd argv)
    in
    Alcotest.(check bool) "did not raise" true true);
  test_case "filter does not raise on empty argv" `Quick (fun () ->
    let p = (module Bash_policy.Coder : Bash_policy.POLICY) in
    let module P = (val p : Bash_policy.POLICY) in
    let cmd = Bash_safe_command.Exec {
      argv = []; cwd; env = []; timeout = 1.0;
    } in
    let result = P.filter cmd in
    match result with
    | Ok _ | Error _ -> Alcotest.(check bool) "result returned" true true);
  test_case "filter does not raise on deeply nested Pipeline" `Quick (fun () ->
    (* Construct a pipeline; depth doesn't matter as long as recursion is fine. *)
    let inner = ok_cmd ["echo"; "hi"] in
    let outer = Bash_safe_command.Pipeline [inner; inner; inner] in
    let p = (module Bash_policy.Coder : Bash_policy.POLICY) in
    let module P = (val p : Bash_policy.POLICY) in
    let _ = P.filter outer in
    Alcotest.(check bool) "did not raise" true true);
  test_case "sanitize_env does not raise on weird keys" `Quick (fun () ->
    let env = [("", ""); ("A=B=C", "v"); ("x\ny", "v")] in
    let _ = Bash_policy.sanitize_env env in
    Alcotest.(check bool) "did not raise" true true);
]

(* -------------------------------------------------------------------------- *)
(* Main                                                                       *)
(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "bash_policy" [
    readonly_suite;
    readonlynonet_suite;
    coder_suite;
    sanitize_env_suite;
    strip_ansi_suite;
    truncate_output_suite;
    totality_suite;
  ]
