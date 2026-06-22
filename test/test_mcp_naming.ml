(* test/test_mcp_naming.ml — v0.3.1 Mcp_naming unit tests *)

open Par
module N = Par__Mcp_naming
module T = Par__Mcp_types

let () = Logs.set_level (Some Logs.Warning) |> ignore

let string_of_error_category (ec : Types.error_category) =
  match ec with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> "Invalid_input(" ^ s ^ ")"
  | Types.External_failure s -> "External_failure(" ^ s ^ ")"
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> "Permission_denied(" ^ s ^ ")"
  | Types.Internal s -> "Internal(" ^ s ^ ")"
  | Types.Embedding_unsupported -> "Embedding_unsupported"

let error_category_pp fmt ec =
  Format.pp_print_string fmt (string_of_error_category ec)

let error_category_testable = Alcotest.testable error_category_pp (=)

let contains_substring ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then true
  else if nlen > hlen then false
  else
    let rec loop i =
      if i > hlen - nlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

let error_msg_substring s r =
  match r with
  | Ok () -> Alcotest.failf "expected Error, got Ok (%S)" s
  | Error (Types.Invalid_input m) ->
      if not (contains_substring ~needle:s m) then
        Alcotest.failf "error message %S does not contain %S" m s
      else ()
  | Error _ -> Alcotest.failf "expected Invalid_input, got non-Invalid_input"

let sanitize_empty_becomes_underscore () =
  Alcotest.check Alcotest.string "empty -> _" "_" (N.sanitize "")

let sanitize_unchanged () =
  Alcotest.check Alcotest.string "abc" "abc" (N.sanitize "abc")

let sanitize_hyphen_preserved () =
  Alcotest.check Alcotest.string "abc-def" "abc-def"
    (N.sanitize "abc-def")

let sanitize_underscore_preserved () =
  Alcotest.check Alcotest.string "abc_def" "abc_def"
    (N.sanitize "abc_def")

let sanitize_dot_replaced () =
  Alcotest.check Alcotest.string "abc.def" "abc_def"
    (N.sanitize "abc.def")

let sanitize_slash_replaced () =
  Alcotest.check Alcotest.string "abc/def" "abc_def"
    (N.sanitize "abc/def")

let sanitize_backslash_replaced () =
  Alcotest.check Alcotest.string "abc\\def" "abc_def"
    (N.sanitize "abc\\def")

let sanitize_colon_replaced () =
  Alcotest.check Alcotest.string "abc:def" "abc_def"
    (N.sanitize "abc:def")

let sanitize_space_replaced () =
  Alcotest.check Alcotest.string "abc def" "abc_def"
    (N.sanitize "abc def")

let sanitize_special_chars_replaced () =
  Alcotest.check Alcotest.string "abc!@#def" "abc___def"
    (N.sanitize "abc!@#def")

let sanitize_uppercase_digits_preserved () =
  Alcotest.check Alcotest.string "ABC123" "ABC123"
    (N.sanitize "ABC123")

let sanitize_idempotent () =
  let inputs = [""; "abc"; "abc-def"; "abc.def"; "abc/def"; "abc\\def";
                "abc:def"; "abc def"; "abc!@#def"; "ABC123"; "mcp__x__y"] in
  List.iter (fun s ->
    let once = N.sanitize s in
    let twice = N.sanitize once in
    Alcotest.check Alcotest.string
      (Printf.sprintf "idempotent on %S" s) once twice
  ) inputs

let sanitize_length_preserved () =
  let inputs = ["abc"; "abc-def"; "abc.def"; "abc/def"; "abc\\def";
               "abc:def"; "abc def"; "abc!@#def"; "ABC123"] in
  List.iter (fun s ->
    let out = N.sanitize s in
    Alcotest.check Alcotest.int
      (Printf.sprintf "length of sanitize %S" s)
      (String.length s) (String.length out)
  ) inputs

let sanitize_output_charset () =
  let inputs = [""; "abc"; "abc.def/ghi\\jkl:mno pqr!@#$%^&*()"] in
  let valid = function
    | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-' -> true
    | _ -> false
  in
  List.iter (fun s ->
    let out = N.sanitize s in
    let bad = ref [] in
    String.iter (fun c -> if not (valid c) then bad := c :: !bad) out;
    Alcotest.check Alcotest.bool
      (Printf.sprintf "charset ok for %S -> %S" s out)
      true (List.length !bad = 0)
  ) inputs

let validate_accepts_fs () =
  Alcotest.(check (result unit error_category_testable))
    "fs" (Ok ()) (N.validate_server_name "fs")

let validate_accepts_git_1 () =
  Alcotest.(check (result unit error_category_testable))
    "git_1" (Ok ()) (N.validate_server_name "git_1")

let validate_accepts_hyphen () =
  Alcotest.(check (result unit error_category_testable))
    "my-server" (Ok ()) (N.validate_server_name "my-server")

let validate_accepts_uppercase () =
  Alcotest.(check (result unit error_category_testable))
    "ABC" (Ok ()) (N.validate_server_name "ABC")

let validate_rejects_empty () =
  error_msg_substring "must not be empty"
    (N.validate_server_name "")

let validate_rejects_colon () =
  error_msg_substring "must contain only"
    (N.validate_server_name "a:b")

let validate_rejects_space () =
  error_msg_substring "must contain only"
    (N.validate_server_name "has space")

let validate_rejects_too_long () =
  let s = String.make 33 'a' in
  error_msg_substring "must be <=32"
    (N.validate_server_name s)

let validate_accepts_exactly_32 () =
  let s = String.make 32 'a' in
  Alcotest.(check (result unit error_category_testable))
    "32 chars" (Ok ()) (N.validate_server_name s)

let mangle_hierarchical_short () =
  Alcotest.check Alcotest.string
    "mcp__fs__read"
    "mcp__fs__read"
    (N.mangle_tool_name
       ~style:T.Hierarchical
       ~server_name:"fs"
       ~tool_name:"read")

let mangle_flat_short () =
  Alcotest.check Alcotest.string
    "fs_read"
    "fs_read"
    (N.mangle_tool_name
       ~style:T.Flat
       ~server_name:"fs"
       ~tool_name:"read")

let mangle_hierarchical_filesystem () =
  Alcotest.check Alcotest.string
    "mcp__filesystem__read_file"
    "mcp__filesystem__read_file"
    (N.mangle_tool_name
       ~style:T.Hierarchical
       ~server_name:"filesystem"
       ~tool_name:"read_file")

let mangle_sanitizes_colons () =
  Alcotest.check Alcotest.string
    "mcp__my_server__v1"
    "mcp__my_server__v1"
    (N.mangle_tool_name
       ~style:T.Hierarchical
       ~server_name:"my:server"
       ~tool_name:"v1")

(* 49 chars: 7 prefix + 10 server + 32 tool. No warn (49 < 50), no truncate. *)
let mangle_below_50_no_warn_no_truncate () =
  let s = "abcdefghij" in
  let t = "abcdefghijklmnopqrstuvwxyz123456" in
  let out = N.mangle_tool_name
    ~style:T.Hierarchical ~server_name:s ~tool_name:t in
  let expected = "mcp__abcdefghij__abcdefghijklmnopqrstuvwxyz123456" in
  Alcotest.check Alcotest.string
    (Printf.sprintf "len=%d" (String.length out))
    expected out;
  Alcotest.check Alcotest.int "length=49" 49 (String.length out)

(* 60 chars exactly: server "s" (1) + tool 52 chars = 7+1+52 = 60. *)
let mangle_exactly_60 () =
  let s = "s" in
  let t = String.make 52 'a' in
  let out = N.mangle_tool_name
    ~style:T.Hierarchical ~server_name:s ~tool_name:t in
  Alcotest.check Alcotest.int "no truncation at 60" 60 (String.length out)

(* 61 chars: server "s" (1) + tool 53 chars = 7+1+53 = 61. Truncate to 60. *)
let mangle_truncates_61_to_60 () =
  let s = "s" in
  let t = String.make 53 'a' in
  let out = N.mangle_tool_name
    ~style:T.Hierarchical ~server_name:s ~tool_name:t in
  Alcotest.check Alcotest.int "truncated to 60" 60 (String.length out)

(* 58 chars: server "s" (1) + tool 50 chars = 7+1+50 = 58. Warn zone, no truncate. *)
let mangle_warn_zone_no_truncate () =
  let s = "s" in
  let t = String.make 50 'a' in
  let out = N.mangle_tool_name
    ~style:T.Hierarchical ~server_name:s ~tool_name:t in
  Alcotest.check Alcotest.int "warn zone, length unchanged" 58
    (String.length out)

let mangle_flat_sanitizes_dots () =
  Alcotest.check Alcotest.string
    "fs_read_file"
    "fs_read_file"
    (N.mangle_tool_name
       ~style:T.Flat
       ~server_name:"fs"
       ~tool_name:"read.file")

let display_simple () =
  Alcotest.check Alcotest.string "fs.read"
    "fs.read"
    (N.display_title ~server_name:"fs" ~tool_name:"read")

let display_empty_server () =
  Alcotest.check Alcotest.string "" ""
    (N.display_title ~server_name:"" ~tool_name:"read")

let display_empty_tool () =
  Alcotest.check Alcotest.string "" ""
    (N.display_title ~server_name:"fs" ~tool_name:"")

let display_both_empty () =
  Alcotest.check Alcotest.string "" ""
    (N.display_title ~server_name:"" ~tool_name:"")

let display_preserves_case () =
  Alcotest.check Alcotest.string "filesystem.READ_FILE"
    "filesystem.READ_FILE"
    (N.display_title ~server_name:"filesystem"
       ~tool_name:"READ_FILE")

let collisions_empty_existing () =
  Alcotest.(check (list string))
    "no existing -> none" []
    (N.detect_collisions
       ~existing:[] ~to_add:["a"; "b"])

let collisions_empty_to_add () =
  Alcotest.(check (list string))
    "no to_add -> none" []
    (N.detect_collisions
       ~existing:["a"; "b"] ~to_add:[])

let collisions_one_match () =
  Alcotest.(check (list string))
    "a is in both" ["a"]
    (N.detect_collisions
       ~existing:["a"; "b"] ~to_add:["a"; "c"])

let collisions_multiple_preserves_order () =
  Alcotest.(check (list string))
    "a;b both collide" ["a"; "b"]
    (N.detect_collisions
       ~existing:["a"; "b"] ~to_add:["a"; "b"; "c"])

let collisions_single () =
  Alcotest.(check (list string))
    "a == a" ["a"]
    (N.detect_collisions
       ~existing:["a"] ~to_add:["a"])

let collisions_no_overlap () =
  Alcotest.(check (list string))
    "no overlap -> []" []
    (N.detect_collisions
       ~existing:["x"; "y"; "z"] ~to_add:["a"; "b"])

let () =
  let open Alcotest in
  run "Mcp_naming" [
    "sanitize", [
      test_case "empty -> \"_\"" `Quick sanitize_empty_becomes_underscore;
      test_case "abc unchanged"        `Quick sanitize_unchanged;
      test_case "hyphen preserved"     `Quick sanitize_hyphen_preserved;
      test_case "underscore preserved" `Quick sanitize_underscore_preserved;
      test_case "dot replaced"         `Quick sanitize_dot_replaced;
      test_case "slash replaced"       `Quick sanitize_slash_replaced;
      test_case "backslash replaced"   `Quick sanitize_backslash_replaced;
      test_case "colon replaced"       `Quick sanitize_colon_replaced;
      test_case "space replaced"       `Quick sanitize_space_replaced;
      test_case "specials replaced"    `Quick sanitize_special_chars_replaced;
      test_case "upper+digits kept"    `Quick sanitize_uppercase_digits_preserved;
      test_case "idempotent"           `Quick sanitize_idempotent;
      test_case "length preserved"     `Quick sanitize_length_preserved;
      test_case "output charset"       `Quick sanitize_output_charset;
    ];
    "validate_server_name", [
      test_case "accepts \"fs\""           `Quick validate_accepts_fs;
      test_case "accepts \"git_1\""        `Quick validate_accepts_git_1;
      test_case "accepts \"my-server\""    `Quick validate_accepts_hyphen;
      test_case "accepts \"ABC\""          `Quick validate_accepts_uppercase;
      test_case "accepts 32 chars"         `Quick validate_accepts_exactly_32;
      test_case "rejects empty"            `Quick validate_rejects_empty;
      test_case "rejects \":\""            `Quick validate_rejects_colon;
      test_case "rejects space"            `Quick validate_rejects_space;
      test_case "rejects 33 chars"         `Quick validate_rejects_too_long;
    ];
    "mangle_tool_name", [
      test_case "hierarchical short"        `Quick mangle_hierarchical_short;
      test_case "flat short"                `Quick mangle_flat_short;
      test_case "hierarchical filesystem"   `Quick mangle_hierarchical_filesystem;
      test_case "sanitizes colons"          `Quick mangle_sanitizes_colons;
      test_case "below 50 no warn"          `Quick mangle_below_50_no_warn_no_truncate;
      test_case "exactly 60 no truncate"    `Quick mangle_exactly_60;
      test_case "truncates 61 to 60"        `Quick mangle_truncates_61_to_60;
      test_case "warn zone no truncate"     `Quick mangle_warn_zone_no_truncate;
      test_case "flat sanitizes tool"       `Quick mangle_flat_sanitizes_dots;
    ];
    "display_title", [
      test_case "fs.read"               `Quick display_simple;
      test_case "empty server"          `Quick display_empty_server;
      test_case "empty tool"            `Quick display_empty_tool;
      test_case "both empty"            `Quick display_both_empty;
      test_case "preserves case"        `Quick display_preserves_case;
    ];
    "detect_collisions", [
      test_case "no existing"           `Quick collisions_empty_existing;
      test_case "no to_add"             `Quick collisions_empty_to_add;
      test_case "one match"             `Quick collisions_one_match;
      test_case "multiple preserve order" `Quick collisions_multiple_preserves_order;
      test_case "single"                `Quick collisions_single;
      test_case "no overlap"            `Quick collisions_no_overlap;
    ];
  ]
