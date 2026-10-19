open Par
open Types

let find_tool name (tools : tool_binding list) =
  let rec go (lst : tool_binding list) = match lst with
    | [] -> failwith (Printf.sprintf "tool '%s' not found" name)
    | tb :: rest ->
        if tb.descriptor.name = name then tb.handler else go rest
  in
  go tools

let with_tools f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
      let ws = match Workspace.of_cwd () with Ok w -> w | Error _ -> failwith "ws" in
      let tools = Builtin_tools.builtin_tools ~switch:sw ~net ~workspace:ws in
      let token = Cancellation.create_token sw in
      f tools token))

let with_tools_in dir f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
      let ws = match Workspace.of_dir dir with Ok w -> w | Error _ -> failwith "ws" in
      let tools = Builtin_tools.builtin_tools ~switch:sw ~net ~workspace:ws in
      let token = Cancellation.create_token sw in
      f tools token))

let is_success = function Success _ -> true | Error _ | Handoff _ | Approval_required _ -> false
let is_error = function Error _ -> true | Success _ | Handoff _ | Approval_required _ -> false

let get_success_json = function
  | Success j -> j
  | Error { message; _ } -> failwith ("expected Success, got Error: " ^ message)
  | Handoff _ -> failwith "expected Success, got Handoff"
  | Approval_required _ -> failwith "expected Success, got Approval_required"

let str_field json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | _ -> failwith (Printf.sprintf "expected string field '%s'" key))
  | _ -> failwith "expected JSON object"

let float_field json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Float f) -> f
       | Some (`Int n) -> float_of_int n
       | _ -> failwith (Printf.sprintf "expected numeric field '%s'" key))
  | _ -> failwith "expected JSON object"

let int_field json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Int n) -> n
       | _ -> failwith (Printf.sprintf "expected int field '%s'" key))
  | _ -> failwith "expected JSON object"

let string_contains haystack needle =
  try let _ = Str.search_forward (Str.regexp_string needle) haystack 0 in true
  with Not_found -> false

let calculator_suite =
  ("calculator", [
    Alcotest.test_case "adds two numbers" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "calculator" tools in
        let result = handler (`Assoc [("expression", `String "2+3")]) token in
        match result with
        | Success (`Float f) -> Alcotest.(check (float 0.001)) "2+3=5" 5.0 f
        | Success (`Int n) -> Alcotest.(check (float 0.001)) "2+3=5" 5.0 (float_of_int n)
        | _ -> Alcotest.fail "expected float"));

    Alcotest.test_case "empty expression returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "calculator" tools in
        let result = handler (`Assoc [("expression", `String "")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "division left-to-right" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "calculator" tools in
        let result = handler (`Assoc [("expression", `String "8 / 2 / 2")]) token in
        match result with
        | Success (`Float f) -> Alcotest.(check (float 0.001)) "8/2/2=2" 2.0 f
        | Success (`Int n) -> Alcotest.(check (float 0.001)) "8/2/2=2" 2.0 (float_of_int n)
        | _ -> Alcotest.fail "expected float"));
  ])

let get_time_suite =
  ("get_time", [
    Alcotest.test_case "returns ISO format string" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "get_time" tools in
        let result = handler (`Assoc []) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.bool "is string" true
          (match json with `String _ -> true | _ -> false)));

    Alcotest.test_case "contains T separator" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "get_time" tools in
        let result = handler (`Assoc []) token in
        let json = get_success_json result in
        let s = match json with `String s -> s | _ -> "" in
        Alcotest.check Alcotest.bool "has T separator" true (String.contains s 'T')));

    Alcotest.test_case "ignores extra input gracefully" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "get_time" tools in
        let result = handler (`Assoc [("extra", `Int 42)]) token in
        Alcotest.check Alcotest.bool "is success" true (is_success result)));
  ])

let echo_suite =
  ("echo", [
    Alcotest.test_case "echoes back text" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "echo" tools in
        let result = handler (`Assoc [("text", `String "hello")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.string "echo" "hello"
          (match json with `String s -> s | _ -> failwith "expected string")));

    Alcotest.test_case "empty text returns empty string" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "echo" tools in
        let result = handler (`Assoc [("text", `String "")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.string "empty" ""
          (match json with `String s -> s | _ -> failwith "expected string")));

    Alcotest.test_case "missing text field returns JSON representation" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "echo" tools in
        let result = handler (`Assoc []) token in
        Alcotest.check Alcotest.bool "is success" true (is_success result)));
  ])

let generate_uuid_suite =
  ("generate_uuid", [
    Alcotest.test_case "produces non-empty string" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "generate_uuid" tools in
        let result = handler (`Assoc []) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.bool "non-empty" true
          (match json with `String s -> String.length s > 0 | _ -> false)));

    Alcotest.test_case "contains hyphens (v4 format)" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "generate_uuid" tools in
        let result = handler (`Assoc []) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.bool "has hyphens" true
          (String.contains (match json with `String s -> s | _ -> "") '-')));

    Alcotest.test_case "two calls produce different UUIDs" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "generate_uuid" tools in
        let r1 = get_success_json (handler (`Assoc []) token) in
        let r2 = get_success_json (handler (`Assoc []) token) in
        let s1 = match r1 with `String s -> s | _ -> "" in
        let s2 = match r2 with `String s -> s | _ -> "" in
        Alcotest.check Alcotest.bool "unique" true (s1 <> s2)));
  ])

let hash_text_suite =
  ("hash_text", [
    Alcotest.test_case "sha256 default produces 64-char hex" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "hash_text" tools in
        let result = handler (`Assoc [("text", `String "hello")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.string "algorithm" "sha256" (str_field json "algorithm");
        Alcotest.check Alcotest.int "sha256 length" 64 (String.length (str_field json "hash"))));

    Alcotest.test_case "empty text produces known sha256" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "hash_text" tools in
        let result = handler (`Assoc [("text", `String "")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.string "sha256 empty"
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
          (str_field json "hash")));

    Alcotest.test_case "md5 algorithm produces 32-char hash" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "hash_text" tools in
        let result = handler (`Assoc [("text", `String "test"); ("algorithm", `String "md5")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.string "algorithm" "md5" (str_field json "algorithm");
        Alcotest.check Alcotest.int "md5 length" 32 (String.length (str_field json "hash"))));
  ])

let generate_password_suite =
  ("generate_password", [
    Alcotest.test_case "default length 16" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "generate_password" tools in
        let result = handler (`Assoc []) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.int "length" 16
          (String.length (match json with `String s -> s | _ -> failwith "expected string"))));

    Alcotest.test_case "custom length 8" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "generate_password" tools in
        let result = handler (`Assoc [("length", `Int 8)]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.int "length 8" 8
          (String.length (match json with `String s -> s | _ -> failwith "expected string"))));

    Alcotest.test_case "length clamped to minimum 4" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "generate_password" tools in
        let result = handler (`Assoc [("length", `Int 2)]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.bool "min length" true
          (let s = match json with `String s -> s | _ -> "" in String.length s >= 4)));
  ])

let string_stats_suite =
  ("string_stats", [
    Alcotest.test_case "counts chars words lines" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "string_stats" tools in
        let result = handler (`Assoc [("text", `String "hello world")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.int "chars" 11 (int_field json "characters");
        Alcotest.check Alcotest.int "words" 2 (int_field json "words");
        Alcotest.check Alcotest.int "lines" 1 (int_field json "lines")));

    Alcotest.test_case "empty string returns zeros" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "string_stats" tools in
        let result = handler (`Assoc [("text", `String "")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.int "chars 0" 0 (int_field json "characters");
        Alcotest.check Alcotest.int "words 0" 0 (int_field json "words")));

    Alcotest.test_case "multiline text counts lines" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "string_stats" tools in
        let result = handler (`Assoc [("text", `String "a\nb\nc")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.int "lines 3" 3 (int_field json "lines")));
  ])

let json_format_suite =
  ("json_format", [
    Alcotest.test_case "formats valid JSON" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "json_format" tools in
        let result = handler (`Assoc [("json", `String "{\"a\":1}")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.bool "contains key" true
          (String.contains (match json with `String s -> s | _ -> "") 'a')));

    Alcotest.test_case "invalid JSON returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "json_format" tools in
        let result = handler (`Assoc [("json", `String "{bad")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "missing json field uses default empty" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "json_format" tools in
        let result = handler (`Assoc []) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.string "default {}" "{}"
          (match json with `String s -> s | _ -> failwith "expected string")));
  ])

let convert_temperature_suite =
  ("convert_temperature", [
    Alcotest.test_case "Celsius to Fahrenheit" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "convert_temperature" tools in
        let result = handler (`Assoc [("value", `Int 100); ("from", `String "C"); ("to", `String "F")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.string "unit" "F" (str_field json "unit");
        Alcotest.(check (float 0.001)) "100C=212F" 212.0 (float_field json "value")));

    Alcotest.test_case "Fahrenheit to Celsius" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "convert_temperature" tools in
        let result = handler (`Assoc [("value", `Int 32); ("from", `String "F"); ("to", `String "C")]) token in
        let json = get_success_json result in
        Alcotest.(check (float 0.001)) "32F=0C" 0.0 (float_field json "value")));

    Alcotest.test_case "same unit returns same value" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "convert_temperature" tools in
        let result = handler (`Assoc [("value", `Int 100); ("from", `String "K"); ("to", `String "K")]) token in
        let json = get_success_json result in
        Alcotest.(check (float 0.001)) "100K=100K" 100.0 (float_field json "value")));
  ])

let url_encode_suite =
  ("url_encode", [
    Alcotest.test_case "encodes spaces as %20" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "url_encode" tools in
        let result = handler (`Assoc [("text", `String "hello world")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.bool "contains %" true
          (String.contains (match json with `String s -> s | _ -> "") '%')));

    Alcotest.test_case "decodes percent-encoded string" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "url_encode" tools in
        let result = handler (`Assoc [("text", `String "hello%20world"); ("decode", `Bool true)]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.string "decoded" "hello world"
          (match json with `String s -> s | _ -> failwith "expected string")));

    Alcotest.test_case "empty text returns empty" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "url_encode" tools in
        let result = handler (`Assoc [("text", `String "")]) token in
        let json = get_success_json result in
        Alcotest.check Alcotest.string "empty" ""
          (match json with `String s -> s | _ -> failwith "expected string")));
  ])

let fetch_url_suite =
  ("fetch_url", [
    Alcotest.test_case "missing url returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "fetch_url" tools in
        let result = handler (`Assoc []) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "empty url returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "fetch_url" tools in
        let result = handler (`Assoc [("url", `String "")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "unsupported scheme returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "fetch_url" tools in
        let result = handler (`Assoc [("url", `String "ftp://example.com")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));
  ])

let read_webpage_suite =
  ("read_webpage", [
    Alcotest.test_case "missing url returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "read_webpage" tools in
        let result = handler (`Assoc []) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "empty url returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "read_webpage" tools in
        let result = handler (`Assoc [("url", `String "")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "unsupported scheme returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "read_webpage" tools in
        let result = handler (`Assoc [("url", `String "file:///etc/passwd")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));
  ])

let web_search_suite =
  ("web_search", [
    Alcotest.test_case "missing query returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "web_search" tools in
        let result = handler (`Assoc []) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "empty query returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "web_search" tools in
        let result = handler (`Assoc [("query", `String "")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "valid query does not crash" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "web_search" tools in
        let result = handler (`Assoc [("query", `String "test")]) token in
        Alcotest.check Alcotest.bool "result valid" true
          (match result with Success _ | Error _ | Handoff _ | Approval_required _ -> true)));
  ])

let read_suite =
  ("read", [
  Alcotest.test_case "read existing file" `Quick (fun () ->
    let tmp = Filename.temp_file "par_read_test" ".txt" in
    let rel_name = Filename.basename tmp in
    let dir = Filename.dirname tmp in
    let oc = open_out tmp in
    output_string oc "line one\nline two\nline three\n";
    close_out oc;
    let cleanup () = (try Unix.unlink tmp with _ -> ()) in
    let run () =
      with_tools_in dir (fun tools token ->
        let handler = find_tool "read" tools in
        let result = handler (`Assoc [("path", `String rel_name)]) token in
        match result with
        | Success (`String s) ->
          let _ = String.contains s 'l' in
          let _ = String.contains s '\t' in
          ()
        | _ -> Alcotest.fail "expected Success")
    in
    Fun.protect ~finally:cleanup run);

  Alcotest.test_case "empty path rejected" `Quick (fun () ->
    with_tools (fun tools token ->
      let handler = find_tool "read" tools in
      let result = handler (`Assoc [("path", `String "")]) token in
      Alcotest.check Alcotest.bool "is error" true (is_error result)));

  Alcotest.test_case "absolute path rejected" `Quick (fun () ->
    with_tools (fun tools token ->
      let handler = find_tool "read" tools in
      let result = handler (`Assoc [("path", `String "/etc/passwd")]) token in
      Alcotest.check Alcotest.bool "is error" true (is_error result)));

  Alcotest.test_case "nonexistent file error" `Quick (fun () ->
    with_tools (fun tools token ->
      let handler = find_tool "read" tools in
      let result = handler (`Assoc [("path", `String "no_such_file_xyz.txt")]) token in
      Alcotest.check Alcotest.bool "is error" true (is_error result)));

  Alcotest.test_case "offset and limit" `Quick (fun () ->
    let tmp = Filename.temp_file "par_read_test" ".txt" in
    let rel_name = Filename.basename tmp in
    let dir = Filename.dirname tmp in
    let oc = open_out tmp in
    output_string oc "a\nb\nc\nd\ne\n";
    close_out oc;
    let cleanup () = (try Unix.unlink tmp with _ -> ()) in
    let run () =
      with_tools_in dir (fun tools token ->
        let handler = find_tool "read" tools in
        let result = handler (`Assoc [
          ("path", `String rel_name);
          ("offset", `Int 1);
          ("limit", `Int 2);
        ]) token in
        match result with
        | Success _ -> ()
        | _ -> Alcotest.fail "expected Success")
    in
    Fun.protect ~finally:cleanup run);
  ])

let ls_suite =
  ("ls", [
    Alcotest.test_case "list current directory" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "ls" tools in
        let result = handler (`Assoc [("path", `String ".")]) token in
        match result with
        | Success _ -> ()
        | _ -> Alcotest.fail "expected Success"));

    Alcotest.test_case "empty path rejected" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "ls" tools in
        let result = handler (`Assoc [("path", `String "")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "absolute path rejected" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "ls" tools in
        let result = handler (`Assoc [("path", `String "/etc")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));
  ])

let find_suite =
  ("find", [
    Alcotest.test_case "find existing files" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "find" tools in
        let result = handler (`Assoc [
          ("pattern", `String "*.ml");
          ("path", `String "lib/core");
        ]) token in
        match result with
        | Success _ -> ()
        | _ -> Alcotest.fail "expected Success"));

    Alcotest.test_case "empty pattern rejected" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "find" tools in
        let result = handler (`Assoc [
          ("pattern", `String "");
          ("path", `String ".");
        ]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "double-star pattern" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "find" tools in
        let result = handler (`Assoc [
          ("pattern", `String "**/*.ml");
          ("path", `String "lib");
        ]) token in
        match result with
        | Success _ -> ()
        | _ -> Alcotest.fail "expected Success"));
  ])

let grep_suite =
  ("grep", [
    Alcotest.test_case "search for pattern" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "grep" tools in
        let result = handler (`Assoc [
          ("pattern", `String "let");
          ("path", `String "lib/core");
          ("glob", `String "types.ml");
        ]) token in
        match result with
        | Success _ -> ()
        | _ -> Alcotest.fail "expected Success"));

    Alcotest.test_case "empty pattern rejected" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "grep" tools in
        let result = handler (`Assoc [
          ("pattern", `String "");
          ("path", `String ".");
        ]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "no match returns empty list" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "grep" tools in
        let result = handler (`Assoc [
          ("pattern", `String "no_such_pattern_xyz_123");
          ("path", `String "lib");
        ]) token in
        match result with
        | Success (`List l) -> Alcotest.(check int) "no matches" 0 (List.length l)
        | _ -> Alcotest.fail "expected Success with empty list"));
  ])

let write_suite =
  ("write", [
    Alcotest.test_case "write new file" `Quick (fun () ->
      with_tools (fun tools token ->
        let rel_name = "par_test_write.txt" in
        let cwd = Sys.getcwd () in
        let cleanup () = (try Unix.unlink rel_name with _ -> ()); Sys.chdir cwd in
        let run () =
          let handler = find_tool "write" tools in
          let result = handler (`Assoc [
            ("path", `String rel_name);
            ("content", `String "hello world");
          ]) token in
          match result with
          | Success _ -> ()
          | _ -> Alcotest.fail "expected Success"
        in
        Fun.protect ~finally:cleanup run));

    Alcotest.test_case "empty path rejected" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "write" tools in
        let result = handler (`Assoc [
          ("path", `String "");
          ("content", `String "x");
        ]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "absolute path rejected" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "write" tools in
        let result = handler (`Assoc [
          ("path", `String "/etc/passwd");
          ("content", `String "x");
        ]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));
  ])

let edit_suite =
  ("edit", [
    Alcotest.test_case "apply single edit" `Quick (fun () ->
      with_tools (fun tools token ->
        let rel_name = "par_test_edit.txt" in
        let cwd = Sys.getcwd () in
        let oc = open_out rel_name in
        output_string oc "hello world";
        close_out oc;
        let cleanup () = (try Unix.unlink rel_name with _ -> ()); Sys.chdir cwd in
        let run () =
          let handler = find_tool "edit" tools in
          let result = handler (`Assoc [
            ("path", `String rel_name);
            ("edits", `List [`Assoc [
              ("old", `String "world");
              ("new", `String "OCaml");
            ]]);
          ]) token in
          match result with
          | Success _ -> ()
          | _ -> Alcotest.fail "expected Success"
        in
        Fun.protect ~finally:cleanup run));

    Alcotest.test_case "empty path rejected" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "edit" tools in
        let result = handler (`Assoc [
          ("path", `String "");
          ("edits", `List []);
        ]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result)));

    Alcotest.test_case "old_text not found returns error" `Quick (fun () ->
      with_tools (fun tools token ->
        let rel_name = "par_test_edit_missing.txt" in
        let cwd = Sys.getcwd () in
        let oc = open_out rel_name in
        output_string oc "hello world";
        close_out oc;
        let cleanup () = (try Unix.unlink rel_name with _ -> ()); Sys.chdir cwd in
        let run () =
          let handler = find_tool "edit" tools in
          let result = handler (`Assoc [
            ("path", `String rel_name);
            ("edits", `List [`Assoc [
              ("old", `String "nonexistent text");
              ("new", `String "replacement");
            ]]);
          ]) token in
          Alcotest.check Alcotest.bool "is error" true (is_error result);
          let msg = match result with
            | Error { message; _ } -> message
            | _ -> Alcotest.fail "expected Error"
          in
          Alcotest.(check bool "contains old_text not found"
            true (string_contains msg "old_text was not found"));
          Alcotest.(check bool "contains Read the file first"
            true (string_contains msg "Read the file first"))
        in
        Fun.protect ~finally:cleanup run));
  ])

(* ------------------------------------------------------------------ *)
(* Wave 2A: actionable tool-error feedback — message-content tests     *)
(* ------------------------------------------------------------------ *)

let get_error_msg = function
  | Error { message; _ } -> message
  | _ -> Alcotest.fail "expected Error"

let error_contains result needle =
  string_contains (get_error_msg result) needle

let error_metadata_code = function
  | Error { metadata; _ } ->
    (match List.assoc_opt "code" metadata with
     | Some (`String s) -> s
     | _ -> "")
  | _ -> ""

let wave2a_file_tools_suite =
  ("wave2a_file_tool_errors", [
    (* ---- read ---- *)
    Alcotest.test_case "read: .. path → [workspace] + traversal" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "read" tools in
        let result = handler (`Assoc [("path", `String "../secret.txt")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
        Alcotest.check Alcotest.bool "mentions .." true (error_contains result "contains '..'")));

    Alcotest.test_case "read: colon path → [workspace] + colon" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "read" tools in
        let result = handler (`Assoc [("path", `String "file:name.txt")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
        Alcotest.check Alcotest.bool "mentions :" true (error_contains result "contains ':'")));

    Alcotest.test_case "read: absolute outside → [workspace] + outside" `Quick (fun () ->
      let tmp = Sys.getcwd () in
      let test_dir = Filename.concat tmp "par_ws_test_read_abs" in
      (try Unix.mkdir test_dir 0o755 with _ -> ());
      let cleanup () = (try Unix.rmdir test_dir with _ -> ()); Sys.chdir tmp in
      Fun.protect ~finally:cleanup (fun () ->
        with_tools_in test_dir (fun tools token ->
          let handler = find_tool "read" tools in
          let result = handler (`Assoc [("path", `String "/definitely/outside/file.txt")]) token in
          Alcotest.check Alcotest.bool "is error" true (is_error result);
          Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
          Alcotest.check Alcotest.bool "mentions outside" true
            (error_contains result "absolute path outside the workspace"))));

    Alcotest.test_case "read: sensitive prefix → [workspace] + protected" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "read" tools in
        let result = handler (`Assoc [("path", `String "/etc/passwd")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
        (* /etc/passwd hits sensitive-prefix check when /etc is in the sensitive list *)
        Alcotest.check Alcotest.bool "mentions protected or outside" true
          (error_contains result "protected location" || error_contains result "outside the workspace")));

    Alcotest.test_case "read: empty path → Path is required" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "read" tools in
        let result = handler (`Assoc [("path", `String "")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
        Alcotest.check Alcotest.bool "says Path is required" true (error_contains result "Path is required")));

    (* ---- write ---- *)
    Alcotest.test_case "write: .. path → [workspace] + traversal" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "write" tools in
        let result = handler (`Assoc [("path", `String "../secret.txt"); ("content", `String "x")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
        Alcotest.check Alcotest.bool "mentions .." true (error_contains result "contains '..'")));

    Alcotest.test_case "write: colon path → [workspace] + colon" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "write" tools in
        let result = handler (`Assoc [("path", `String "a:b.txt"); ("content", `String "x")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
        Alcotest.check Alcotest.bool "mentions :" true (error_contains result "contains ':'")));

    Alcotest.test_case "write: empty path → Path is required" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "write" tools in
        let result = handler (`Assoc [("path", `String ""); ("content", `String "x")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
        Alcotest.check Alcotest.bool "says Path is required" true (error_contains result "Path is required")));

    (* ---- edit ---- *)
    Alcotest.test_case "edit: .. path → [workspace] + traversal" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "edit" tools in
        let result = handler (`Assoc [("path", `String "../x.txt"); ("edits", `List [])]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
        Alcotest.check Alcotest.bool "mentions .." true (error_contains result "contains '..'")));

    Alcotest.test_case "edit: colon path → [workspace] + colon" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "edit" tools in
        let result = handler (`Assoc [("path", `String "a:b.txt"); ("edits", `List [])]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
        Alcotest.check Alcotest.bool "mentions :" true (error_contains result "contains ':'")));

    Alcotest.test_case "edit: empty path → Path is required" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "edit" tools in
        let result = handler (`Assoc [("path", `String ""); ("edits", `List [])]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true (error_contains result "[workspace]");
        Alcotest.check Alcotest.bool "says Path is required" true (error_contains result "Path is required")));

    (* ---- metadata code assertions ---- *)
    Alcotest.test_case "read: .. path → code workspace_parent_traversal" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "read" tools in
        let result = handler (`Assoc [("path", `String "../x")]) token in
        Alcotest.check Alcotest.string "code" "workspace_parent_traversal"
          (error_metadata_code result)));

    Alcotest.test_case "read: colon path → code workspace_colon" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "read" tools in
        let result = handler (`Assoc [("path", `String "a:b")]) token in
        Alcotest.check Alcotest.string "code" "workspace_colon"
          (error_metadata_code result)));
  ])

let apply_patch_suite =
  ("apply_patch", [
    Alcotest.test_case "empty patch rejected by handler" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "apply_patch" tools in
        let result = handler (`Assoc [("patch", `String "")]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [patch]" true
          (error_contains result "[patch]")));

    Alcotest.test_case "malformed hunk header rejected" `Quick (fun () ->
      let diff = "--- a/test.txt\n+++ b/test.txt\n@@ bad header @@\n line\n" in
      match Apply_patch.parse_diff diff with
      | Error { message; _ } ->
        Alcotest.check Alcotest.bool "mentions malformed" true
          (string_contains message "Malformed")
      | Ok _ -> Alcotest.fail "expected parse error");

    Alcotest.test_case "empty diff rejected" `Quick (fun () ->
      match Apply_patch.parse_diff "" with
      | Error { message; _ } ->
        Alcotest.check Alcotest.bool "mentions empty" true
          (string_contains message "Empty")
      | Ok _ -> Alcotest.fail "expected parse error");

    Alcotest.test_case "single hunk parse + apply" `Quick (fun () ->
      let diff = "--- a/test.txt\n+++ b/test.txt\n@@ -1,3 +1,3 @@\n line1\n-line2\n+line2_modified\n line3\n" in
      match Apply_patch.parse_diff diff with
      | Error e -> Alcotest.failf "parse error: %s" e.message
      | Ok patches ->
        let read_file _ = Some "line1\nline2\nline3\n" in
        let file_exists _ = true in
        (match Apply_patch.apply ~read_file ~file_exists patches with
         | Error e -> Alcotest.failf "apply error: %s" (Apply_patch.string_of_apply_error e)
         | Ok { report; staged } ->
           Alcotest.check Alcotest.int "files_changed" 1 report.files_changed;
           Alcotest.check Alcotest.int "hunks_applied" 1 report.hunks_applied;
           Alcotest.check Alcotest.int "insertions" 1 report.insertions;
           Alcotest.check Alcotest.int "deletions" 1 report.deletions;
           let content = List.assoc "test.txt" staged in
           Alcotest.check Alcotest.bool "has modified line" true
             (string_contains content "line2_modified")));

    Alcotest.test_case "multi-file patch" `Quick (fun () ->
      let diff = "--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n hello\n-world\n+ocaml\n\n--- a/b.txt\n+++ b/b.txt\n@@ -1,2 +1,2 @@\n foo\n-bar\n+baz\n" in
      match Apply_patch.parse_diff diff with
      | Error e -> Alcotest.failf "parse error: %s" e.message
      | Ok patches ->
        Alcotest.check Alcotest.int "2 files" 2 (List.length patches);
        let files = Hashtbl.create 2 in
        Hashtbl.replace files "a.txt" "hello\nworld\n";
        Hashtbl.replace files "b.txt" "foo\nbar\n";
        let read_file p = Hashtbl.find_opt files p in
        let file_exists p = Hashtbl.mem files p in
        (match Apply_patch.apply ~read_file ~file_exists patches with
         | Error e -> Alcotest.failf "apply error: %s" (Apply_patch.string_of_apply_error e)
         | Ok { report; _ } ->
           Alcotest.check Alcotest.int "files_changed" 2 report.files_changed;
           Alcotest.check Alcotest.int "hunks_applied" 2 report.hunks_applied));

    Alcotest.test_case "offset recovery when context shifted" `Quick (fun () ->
      let diff = "--- a/test.txt\n+++ b/test.txt\n@@ -5,3 +5,3 @@\n context_before\n-old_line\n+new_line\n context_after\n" in
      match Apply_patch.parse_diff diff with
      | Error e -> Alcotest.failf "parse error: %s" e.message
      | Ok patches ->
        let original =
          "line1\nline2\nline3\nline4\n\
           context_before\nold_line\ncontext_after\nline8\n"
        in
        let read_file _ = Some original in
        let file_exists _ = true in
        (match Apply_patch.apply ~read_file ~file_exists patches with
         | Error e -> Alcotest.failf "offset recovery failed: %s"
                        (Apply_patch.string_of_apply_error e)
         | Ok { report; staged } ->
           Alcotest.check Alcotest.int "hunks_applied" 1 report.hunks_applied;
           let content = List.assoc "test.txt" staged in
           Alcotest.check Alcotest.bool "has new_line" true
             (string_contains content "new_line")));

    Alcotest.test_case "context mismatch error reports details" `Quick (fun () ->
      let diff = "--- a/test.txt\n+++ b/test.txt\n@@ -1,3 +1,3 @@\n line1\n-line2\n+line2_mod\n line3\n" in
      match Apply_patch.parse_diff diff with
      | Error e -> Alcotest.failf "parse error: %s" e.message
      | Ok patches ->
        let read_file _ = Some "completely\ndifferent\ncontent\n" in
        let file_exists _ = true in
        (match Apply_patch.apply ~read_file ~file_exists patches with
         | Ok _ -> Alcotest.fail "expected context mismatch"
         | Error e ->
           let msg = Apply_patch.string_of_apply_error e in
           Alcotest.check Alcotest.bool "has [patch]" true
             (string_contains msg "[patch]");
           Alcotest.check Alcotest.bool "has file name" true
             (string_contains msg "test.txt");
           Alcotest.check Alcotest.bool "mentions context mismatch" true
             (string_contains msg "Context mismatch")));

    Alcotest.test_case "binary files skipped" `Quick (fun () ->
      let diff = "Binary files a/image.png and b/image.png differ\n--- a/text.txt\n+++ b/text.txt\n@@ -1,1 +1,1 @@\n-old\n+new\n" in
      match Apply_patch.parse_diff diff with
      | Error e -> Alcotest.failf "parse error: %s" e.message
      | Ok patches ->
        let binary_p = List.find (fun p -> p.Apply_patch.is_binary) patches in
        let text_p = List.find (fun p -> not p.Apply_patch.is_binary) patches in
        Alcotest.check Alcotest.string "binary path" "image.png"
          binary_p.new_path;
        Alcotest.check Alcotest.string "text path" "text.txt"
          text_p.new_path);

    Alcotest.test_case "file not found error" `Quick (fun () ->
      let diff = "--- a/missing.txt\n+++ b/missing.txt\n@@ -1,1 +1,1 @@\n-old\n+new\n" in
      match Apply_patch.parse_diff diff with
      | Error e -> Alcotest.failf "parse error: %s" e.message
      | Ok patches ->
        let read_file _ = None in
        let file_exists _ = false in
        (match Apply_patch.apply ~read_file ~file_exists patches with
         | Ok _ -> Alcotest.fail "expected file not found"
         | Error (Apply_patch.File_not_found p) ->
           Alcotest.check Alcotest.string "path" "missing.txt" p
         | Error e -> Alcotest.failf "wrong error: %s"
                        (Apply_patch.string_of_apply_error e)));

    Alcotest.test_case "new file creation" `Quick (fun () ->
      let diff = "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+hello\n+world\n" in
      match Apply_patch.parse_diff diff with
      | Error e -> Alcotest.failf "parse error: %s" e.message
      | Ok patches ->
        Alcotest.check Alcotest.bool "is_new" true
          (List.hd patches).Apply_patch.is_new;
        let read_file _ = None in
        let file_exists _ = false in
        (match Apply_patch.apply ~read_file ~file_exists patches with
         | Error e -> Alcotest.failf "apply error: %s"
                        (Apply_patch.string_of_apply_error e)
         | Ok { staged; _ } ->
           let content = List.assoc "new.txt" staged in
           Alcotest.check Alcotest.bool "has hello" true
             (string_contains content "hello")));

    Alcotest.test_case "new file already exists rejected" `Quick (fun () ->
      let diff = "--- /dev/null\n+++ b/existing.txt\n@@ -0,0 +1,1 @@\n+content\n" in
      match Apply_patch.parse_diff diff with
      | Error e -> Alcotest.failf "parse error: %s" e.message
      | Ok patches ->
        let read_file _ = Some "old content" in
        let file_exists _ = true in
        (match Apply_patch.apply ~read_file ~file_exists patches with
         | Ok _ -> Alcotest.fail "expected already exists error"
         | Error (Apply_patch.File_already_exists p) ->
           Alcotest.check Alcotest.string "path" "existing.txt" p
         | Error e -> Alcotest.failf "wrong error: %s"
                        (Apply_patch.string_of_apply_error e)));

    Alcotest.test_case "deletion hunk" `Quick (fun () ->
      let diff = "--- a/deleteme.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-line1\n-line2\n" in
      match Apply_patch.parse_diff diff with
      | Error e -> Alcotest.failf "parse error: %s" e.message
      | Ok patches ->
        Alcotest.check Alcotest.bool "is_deleted" true
          (List.hd patches).Apply_patch.is_deleted);

    Alcotest.test_case "handler dry_run writes nothing" `Quick (fun () ->
      let rel_name = "par_test_dry_run.txt" in
      let oc = open_out rel_name in
      output_string oc "original content\n";
      close_out oc;
      let cleanup () = (try Unix.unlink rel_name with _ -> ()) in
      let run () =
        with_tools (fun tools token ->
          let handler = find_tool "apply_patch" tools in
          let diff = Printf.sprintf
            "--- a/%s\n\
             +++ b/%s\n\
             @@ -1,1 +1,1 @@\n\
             -original content\n\
             +modified content\n"
            rel_name rel_name
          in
          let result = handler (`Assoc [
            ("patch", `String diff);
            ("dry_run", `Bool true);
          ]) token in
          match result with
          | Success json ->
            Alcotest.check Alcotest.bool "dry_run flag" true
              (Yojson.Safe.Util.(json |> member "dry_run" |> to_bool));
            let ic = open_in rel_name in
            let actual = input_line ic in
            close_in ic;
            Alcotest.check Alcotest.bool "file unchanged" true
              (string_contains actual "original content")
          | Error { message; _ } -> Alcotest.failf "handler error: %s" message
          | _ -> Alcotest.fail "unexpected result")
      in
      Fun.protect ~finally:cleanup run);

    Alcotest.test_case "handler workspace path-traversal rejected" `Quick (fun () ->
      with_tools (fun tools token ->
        let handler = find_tool "apply_patch" tools in
        let diff = "--- a/../secret.txt\n+++ b/../secret.txt\n@@ -1,1 +1,1 @@\n-x\n+y\n" in
        let result = handler (`Assoc [("patch", `String diff)]) token in
        Alcotest.check Alcotest.bool "is error" true (is_error result);
        Alcotest.check Alcotest.bool "has [workspace]" true
          (error_contains result "[workspace]")));

    Alcotest.test_case "handler applies and writes file" `Quick (fun () ->
      let rel_name = "par_test_apply_write.txt" in
      let oc = open_out rel_name in
      output_string oc "hello world\n";
      close_out oc;
      let cleanup () = (try Unix.unlink rel_name with _ -> ()) in
      let run () =
        with_tools (fun tools token ->
          let handler = find_tool "apply_patch" tools in
          let diff = Printf.sprintf
            "--- a/%s\n\
             +++ b/%s\n\
             @@ -1,1 +1,1 @@\n\
             -hello world\n\
             +hello ocaml\n"
            rel_name rel_name
          in
          let result = handler (`Assoc [("patch", `String diff)]) token in
          match result with
          | Success json ->
            Alcotest.check Alcotest.int "files_changed" 1
              (int_field json "files_changed");
            let ic = open_in rel_name in
            let actual = input_line ic in
            close_in ic;
            Alcotest.check Alcotest.string "written" "hello ocaml" actual
          | Error { message; _ } -> Alcotest.failf "handler error: %s" message
          | _ -> Alcotest.fail "unexpected result")
      in
      Fun.protect ~finally:cleanup run);
  ])

let () =
  Alcotest.run "Builtin Tools" [
    calculator_suite;
    get_time_suite;
    echo_suite;
    generate_uuid_suite;
    hash_text_suite;
    generate_password_suite;
    string_stats_suite;
    json_format_suite;
    convert_temperature_suite;
    url_encode_suite;
    fetch_url_suite;
    read_webpage_suite;
    web_search_suite;
    read_suite;
    ls_suite;
    find_suite;
    grep_suite;
    write_suite;
    edit_suite;
    wave2a_file_tools_suite;
    apply_patch_suite;
  ]
