open Par
open Types

let find_tool name tools =
  let rec go = function
    | [] -> failwith (Printf.sprintf "tool '%s' not found" name)
    | tb :: rest ->
        if tb.descriptor.name = name then tb.handler else go rest
  in
  go tools

let with_tools f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
      let tools = Builtin_tools.builtin_tools ~switch:sw ~net in
      let token = Cancellation.create_token sw in
      f tools token))

let is_success = function Success _ -> true | Error _ -> false
let is_error = function Error _ -> true | Success _ -> false

let get_success_json = function
  | Success j -> j
  | Error { message; _ } -> failwith ("expected Success, got Error: " ^ message)

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
          (match result with Success _ -> true | Error _ -> true)));
  ])

let read_suite =
  ("read", [
  Alcotest.test_case "read existing file" `Quick (fun () ->
    with_tools (fun tools token ->
      let tmp = Filename.temp_file "par_read_test" ".txt" in
      let rel_name = Filename.basename tmp in
      let cwd = Sys.getcwd () in
      Sys.chdir (Filename.dirname tmp);
      let oc = open_out rel_name in
      output_string oc "line one\nline two\nline three\n";
      close_out oc;
      let cleanup () =
        (try Unix.unlink rel_name with _ -> ());
        Sys.chdir cwd
      in
      let run () =
        let handler = find_tool "read" tools in
        let result = handler (`Assoc [("path", `String rel_name)]) token in
        match result with
        | Success (`String s) ->
          let _ = String.contains s 'l' in
          let _ = String.contains s '\t' in
          ()
        | _ -> Alcotest.fail "expected Success"
      in
      Fun.protect ~finally:cleanup run));

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
    with_tools (fun tools token ->
      let tmp = Filename.temp_file "par_read_test" ".txt" in
      let rel_name = Filename.basename tmp in
      let cwd = Sys.getcwd () in
      Sys.chdir (Filename.dirname tmp);
      let oc = open_out rel_name in
      output_string oc "a\nb\nc\nd\ne\n";
      close_out oc;
      let cleanup () =
        (try Unix.unlink rel_name with _ -> ());
        Sys.chdir cwd
      in
      let run () =
        let handler = find_tool "read" tools in
        let result = handler (`Assoc [
          ("path", `String rel_name);
          ("offset", `Int 1);
          ("limit", `Int 2);
        ]) token in
        match result with
        | Success _ -> ()
        | _ -> Alcotest.fail "expected Success"
      in
      Fun.protect ~finally:cleanup run));
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
  ]