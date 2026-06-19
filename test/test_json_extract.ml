(* Tests for Json_extract — lenient JSON extraction from LLM free-form text. *)

open Par

let pp_yojson fmt j = Yojson.Safe.pretty_print fmt j

let yojson_testable = Alcotest.testable pp_yojson (=)

let check_ok_json msg expected actual =
  match actual with
  | Ok j -> Alcotest.(check yojson_testable) msg expected j
  | Error e ->
    Alcotest.failf "expected Ok %s, got Error %s"
      (Yojson.Safe.to_string expected) e

let check_error _msg actual =
  match actual with
  | Ok j ->
    Alcotest.failf "expected Error, got Ok %s" (Yojson.Safe.to_string j)
  | Error _ -> ()

let get_string field json =
  Yojson.Safe.Util.(json |> member field |> to_string)

let get_int field json =
  Yojson.Safe.Util.(json |> member field |> to_int)

let test_plain_object () =
  let input = {|{"name": "Alice", "age": 30}|} in
  let expected = `Assoc [("name", `String "Alice"); ("age", `Int 30)] in
  check_ok_json "plain object" expected
    (Json_extract.extract_json_from_text input)

let test_plain_array () =
  let input = "[1, 2, 3]" in
  let expected = `List [`Int 1; `Int 2; `Int 3] in
  check_ok_json "plain array" expected
    (Json_extract.extract_json_from_text input)

let test_whitespace_padding () =
  let input = "   \n  {\"x\": 1}  \t\n  " in
  let expected = `Assoc [("x", `Int 1)] in
  check_ok_json "whitespace padded" expected
    (Json_extract.extract_json_from_text input)

let test_json_fenced () =
  let input = "```json\n{\"name\": \"Bob\", \"age\": 25}\n```" in
  let expected = `Assoc [("name", `String "Bob"); ("age", `Int 25)] in
  check_ok_json "json-fenced" expected
    (Json_extract.extract_json_from_text input)

let test_bare_fenced () =
  let input = "```\n[true, false, null]\n```" in
  let expected = `List [`Bool true; `Bool false; `Null] in
  check_ok_json "bare fence" expected
    (Json_extract.extract_json_from_text input)

let test_json_in_prose () =
  let input = "Sure! Here's the answer: {\"result\": 42}. Hope that helps!" in
  let expected = `Assoc [("result", `Int 42)] in
  check_ok_json "json in prose" expected
    (Json_extract.extract_json_from_text input)

let test_array_in_prose () =
  let input = "Here are the items: [1, 2, 3] end of message" in
  let expected = `List [`Int 1; `Int 2; `Int 3] in
  check_ok_json "array in prose" expected
    (Json_extract.extract_json_from_text input)

let test_nested_object () =
  let input = {|{"outer": {"inner": {"deep": "value"}}}|} in
  match Json_extract.extract_json_from_text input with
  | Ok json ->
    Alcotest.(check string) "deep string" "value" (get_string "deep"
      (Yojson.Safe.Util.(json |> member "outer" |> member "inner")))
  | Error e -> Alcotest.failf "expected Ok, got Error %s" e

let test_array_of_objects () =
  let input = "[{\"x\": 1}, {\"y\": 2}]" in
  match Json_extract.extract_json_from_text input with
  | Ok (`List items) ->
    Alcotest.(check int) "list length" 2 (List.length items);
    (match items with
     | [`Assoc [("x", `Int 1)]; _] -> ()
     | _ -> Alcotest.fail "first element mismatch")
  | Ok j -> Alcotest.failf "expected list, got %s" (Yojson.Safe.to_string j)
  | Error e -> Alcotest.failf "expected Ok, got Error %s" e

let test_empty_input () =
  check_error "empty string"
    (Json_extract.extract_json_from_text "")

let test_whitespace_only_input () =
  check_error "whitespace only"
    (Json_extract.extract_json_from_text "   \n\t  ")

let test_no_json_input () =
  check_error "no json"
    (Json_extract.extract_json_from_text "hello world, no JSON here")

let test_malformed_json () =
  check_error "malformed json"
    (Json_extract.extract_json_from_text "{not valid")

let test_malformed_after_valid_prefix () =
  check_error "unbalanced braces"
    (Json_extract.extract_json_from_text "{unclosed object")

let test_braces_in_string_literal () =
  let input = {|{"msg": "contains { and } inside"}|} in
  match Json_extract.extract_json_from_text input with
  | Ok json ->
    Alcotest.(check string) "msg value"
      "contains { and } inside" (get_string "msg" json)
  | Error e -> Alcotest.failf "expected Ok, got Error %s" e

let test_escaped_quote_in_string () =
  let input = {|{"msg": "she said \"hi\"", "ok": true}|} in
  match Json_extract.extract_json_from_text input with
  | Ok json ->
    Alcotest.(check string) "msg with escapes"
      {|she said "hi"|} (get_string "msg" json);
    Alcotest.(check bool) "ok flag" true
      (Yojson.Safe.Util.(json |> member "ok" |> to_bool))
  | Error e -> Alcotest.failf "expected Ok, got Error %s" e

let test_array_in_prose_with_braces_in_strings () =
  let input = {|Prefix text: [{"a": "{brace}"}] trailing|} in
  match Json_extract.extract_json_from_text input with
  | Ok (`List [`Assoc [("a", `String "{brace}")]]) -> ()
  | Ok j -> Alcotest.failf "expected specific shape, got %s" (Yojson.Safe.to_string j)
  | Error e -> Alcotest.failf "expected Ok, got Error %s" e

let test_multiple_blocks_returns_first () =
  let input = {|{"a": 1} some text {"b": 2}|} in
  match Json_extract.extract_json_from_text input with
  | Ok json ->
    Alcotest.(check int) "first block value" 1 (get_int "a" json)
  | Error e -> Alcotest.failf "expected Ok, got Error %s" e

let test_fenced_with_prose_around () =
  let input = "Sure, here you go:\n```json\n{\"k\": \"v\"}\n```\nBye!" in
  match Json_extract.extract_json_from_text input with
  | Ok json ->
    Alcotest.(check string) "k value" "v" (get_string "k" json)
  | Error e -> Alcotest.failf "expected Ok, got Error %s" e

let () =
  Alcotest.run "Json_extract" [
    ("happy path", [
      Alcotest.test_case "plain object" `Quick test_plain_object;
      Alcotest.test_case "plain array" `Quick test_plain_array;
      Alcotest.test_case "whitespace padding" `Quick test_whitespace_padding;
      Alcotest.test_case "json-fenced" `Quick test_json_fenced;
      Alcotest.test_case "bare fence" `Quick test_bare_fenced;
      Alcotest.test_case "json in prose" `Quick test_json_in_prose;
      Alcotest.test_case "array in prose" `Quick test_array_in_prose;
      Alcotest.test_case "nested object" `Quick test_nested_object;
      Alcotest.test_case "array of objects" `Quick test_array_of_objects;
    ]);
    ("edge cases", [
      Alcotest.test_case "empty input" `Quick test_empty_input;
      Alcotest.test_case "whitespace-only input" `Quick test_whitespace_only_input;
      Alcotest.test_case "no json input" `Quick test_no_json_input;
      Alcotest.test_case "malformed json" `Quick test_malformed_json;
      Alcotest.test_case "unbalanced braces" `Quick test_malformed_after_valid_prefix;
    ]);
    ("string awareness", [
      Alcotest.test_case "braces in string literal" `Quick test_braces_in_string_literal;
      Alcotest.test_case "escaped quote in string" `Quick test_escaped_quote_in_string;
      Alcotest.test_case "array in prose with braces in strings"
        `Quick test_array_in_prose_with_braces_in_strings;
      Alcotest.test_case "multiple blocks returns first"
        `Quick test_multiple_blocks_returns_first;
      Alcotest.test_case "fenced with prose around" `Quick test_fenced_with_prose_around;
    ]);
  ]
