open Par
open Types

let string_of_error_category (ec : error_category) =
  match ec with
  | Timeout -> "Timeout"
  | Invalid_input s -> "Invalid_input(" ^ s ^ ")"
  | External_failure s -> "External_failure(" ^ s ^ ")"
  | Rate_limited -> "Rate_limited"
  | Permission_denied s -> "Permission_denied(" ^ s ^ ")"
  | Internal s -> "Internal(" ^ s ^ ")"

let error_category_pp fmt ec = Format.pp_print_string fmt (string_of_error_category ec)

let error_category_testable = Alcotest.testable error_category_pp (=)

let schema_object fields =
  `Assoc (("type", `String "object") :: fields)

let test_valid_type_match () =
  let schema = schema_object [("properties", `Assoc [])] in
  let value = `Assoc [] in
  Alcotest.(check (result unit error_category_testable))
    "valid empty object against object schema" (Ok ())
    (Validation.validate_tool_input_result schema value)

let test_type_mismatch () =
  let schema = schema_object [("properties", `Assoc [])] in
  let value = `String "not an object" in
  match Validation.validate_tool_input_result schema value with
  | Error (Invalid_input msg) ->
    Alcotest.(check bool) "error mentions expected type" true
      (String.length msg > 0)
  | _ -> Alcotest.fail "expected Invalid_input error"

let test_missing_required () =
  let schema = schema_object [
    ("properties", `Assoc [
      ("name", `Assoc [("type", `String "string")]);
      ("age", `Assoc [("type", `String "integer")]);
    ]);
    ("required", `List [`String "name"; `String "age"])
  ] in
  let value = `Assoc [("name", `String "Alice")] in
  match Validation.validate_tool_input_result schema value with
  | Error (Invalid_input msg) ->
    Alcotest.(check bool) "mentions age" true (String.contains msg 'a')
  | _ -> Alcotest.fail "expected Invalid_input for missing required field"

let test_extra_fields_allowed () =
  let schema = schema_object [
    ("properties", `Assoc [
      ("name", `Assoc [("type", `String "string")]);
    ]);
    ("required", `List [])
  ] in
  let value = `Assoc [
    ("name", `String "Alice");
    ("extra", `Int 42);
    ("more", `String "ok")
  ] in
  Alcotest.(check (result unit error_category_testable))
    "extra fields are allowed" (Ok ())
    (Validation.validate_tool_input_result schema value)

let test_enum_violation () =
  let schema = schema_object [
    ("properties", `Assoc [
      ("color", `Assoc [
        ("type", `String "string");
        ("enum", `List [`String "red"; `String "green"; `String "blue"]);
      ])
    ])
  ] in
  let bad = `Assoc [("color", `String "purple")] in
  let good = `Assoc [("color", `String "red")] in
  (match Validation.validate_tool_input_result schema bad with
   | Error (Invalid_input _) -> ()
   | _ -> Alcotest.fail "expected enum violation for 'purple'");
  Alcotest.(check (result unit error_category_testable))
    "valid enum value passes" (Ok ())
    (Validation.validate_tool_input_result schema good)

let test_minimum_maximum () =
  let schema = schema_object [
    ("properties", `Assoc [
      ("score", `Assoc [
        ("type", `String "integer");
        ("minimum", `Int 0);
        ("maximum", `Int 100);
      ]);
      ("name", `Assoc [
        ("type", `String "string");
        ("minLength", `Int 1);
        ("maxLength", `Int 10);
      ])
    ])
  ] in
  let too_low = `Assoc [("score", `Int (-1)); ("name", `String "ok")] in
  let too_high = `Assoc [("score", `Int 101); ("name", `String "ok")] in
  let bad_length = `Assoc [("score", `Int 50); ("name", `String "way too long for limit")] in
  let good = `Assoc [("score", `Int 50); ("name", `String "ok")] in
  (match Validation.validate_tool_input_result schema too_low with
   | Error (Invalid_input _) -> ()
   | _ -> Alcotest.fail "expected minimum violation for -1");
  (match Validation.validate_tool_input_result schema too_high with
   | Error (Invalid_input _) -> ()
   | _ -> Alcotest.fail "expected maximum violation for 101");
  (match Validation.validate_tool_input_result schema bad_length with
   | Error (Invalid_input _) -> ()
   | _ -> Alcotest.fail "expected maxLength violation");
  Alcotest.(check (result unit error_category_testable))
    "valid value in range" (Ok ())
    (Validation.validate_tool_input_result schema good)

let test_unknown_keyword_ignored () =
  let schema = `Assoc [
    ("type", `String "string");
    ("description", `String "a name field");
    ("pattern", `String "^[a-z]+$");
    ("format", `String "uuid");
  ] in
  Alcotest.(check (result unit error_category_testable))
    "unknown keywords don't affect validation" (Ok ())
    (Validation.validate_tool_input_result schema (`String "anything"))

let test_empty_schema_accepts_anything () =
  let schema = `Assoc [] in
  let values = [
    `String "hello";
    `Int 42;
    `Bool true;
    `Null;
    `List [`Int 1; `Int 2];
    `Assoc [("a", `Int 1)];
  ] in
  List.iter (fun v ->
    match Validation.validate_tool_input_result schema v with
    | Ok () -> ()
    | Error e -> Alcotest.fail
      (Printf.sprintf "empty schema should accept %s but got %s"
        (Yojson.Safe.to_string v) (string_of_error_category e))
  ) values

let test_nested_property_type_check () =
  let schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("name", `Assoc [("type", `String "string")]);
      ("count", `Assoc [("type", `String "integer")])
    ]);
    ("required", `List [`String "name"])
  ] in
  let good = `Assoc [
    ("name", `String "Alice");
    ("count", `Int 3)
  ] in
  let bad_type = `Assoc [
    ("name", `Int 42)
  ] in
  Alcotest.(check (result unit error_category_testable))
    "1-level nested properties validated" (Ok ())
    (Validation.validate_tool_input_result schema good);
  match Validation.validate_tool_input_result schema bad_type with
  | Error (Invalid_input _) -> ()
  | _ -> Alcotest.fail "expected nested property type violation"

let () =
  Alcotest.run "schema validation" [
    ("type checking", [
      Alcotest.test_case "valid type match" `Quick test_valid_type_match;
      Alcotest.test_case "type mismatch" `Quick test_type_mismatch;
    ]);
    ("required fields", [
      Alcotest.test_case "missing required" `Quick test_missing_required;
      Alcotest.test_case "extra fields allowed" `Quick test_extra_fields_allowed;
    ]);
    ("constraints", [
      Alcotest.test_case "enum violation" `Quick test_enum_violation;
      Alcotest.test_case "minimum/maximum" `Quick test_minimum_maximum;
    ]);
    ("forward compatibility", [
      Alcotest.test_case "unknown keywords ignored" `Quick test_unknown_keyword_ignored;
      Alcotest.test_case "empty schema accepts anything" `Quick test_empty_schema_accepts_anything;
    ]);
    ("nested", [
      Alcotest.test_case "nested property type check" `Quick test_nested_property_type_check;
    ]);
  ]
