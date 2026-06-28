(* Tests for the Jsonschema conventions module and the
   ppx_deriving_jsonschema integration. PAR-g4c foundation.

   These tests verify the round-trip on a small sample type: the
   ppx produces a `Yojson.Safe.t`, the [Jsonschema] wrapper enforces
   OpenAI-strict-mode invariants, and the FFI guard (top-level
   `` `Assoc _ ``) is honoured.

   No runtime is constructed — the tests are pure value-level
   reasoning over JSON values, so they don't need a Runtime. *)

open Par

type sample_input = {
  x : int;
  y : string;
  optional_z : string option;
}
[@@deriving yojson { strict = false }, jsonschema]

let assoc_field key = function
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> None

let string_of_member = function
  | `String s -> Some s
  | _ -> None

let list_string_keys = function
  | `List items -> List.filter_map string_of_member items
  | _ -> []

let alcootest_json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let test_derived_schema_is_assoc () =
  let schema = sample_input_jsonschema in
  match schema with
  | `Assoc _ -> ()
  | _ -> Alcotest.fail "derived schema must be `Assoc _"

let test_strict_wrapper_preserves_assoc () =
  let schema = sample_input_jsonschema in
  let wrapped = Jsonschema.to_strict_object_schema schema in
  match wrapped with
  | `Assoc _ -> ()
  | _ -> Alcotest.fail "wrapped schema must be `Assoc _"

let test_strict_wrapper_adds_additional_properties_false () =
  let schema = sample_input_jsonschema in
  let wrapped = Jsonschema.to_strict_object_schema schema in
  match assoc_field "additionalProperties" wrapped with
  | Some (`Bool false) -> ()
  | Some (`Bool true) ->
    Alcotest.fail "additionalProperties must be false in strict mode"
  | Some other ->
    Alcotest.fail
      (Printf.sprintf "additionalProperties must be `Bool false, got: %s"
         (Yojson.Safe.to_string other))
  | None ->
    Alcotest.fail "additionalProperties key must be present in wrapped schema"

let test_strict_wrapper_includes_all_properties_in_required () =
  let schema = sample_input_jsonschema in
  let wrapped = Jsonschema.to_strict_object_schema schema in
  let properties =
    match assoc_field "properties" wrapped with
    | Some (`Assoc pairs) -> List.map fst pairs
    | _ -> Alcotest.fail "wrapped schema must contain an `Assoc properties"
  in
  let required =
    match assoc_field "required" wrapped with
    | Some (`List _) as r -> list_string_keys (Option.get r)
    | _ -> Alcotest.fail "wrapped schema must contain a `List required"
  in
  let required_set = List.sort String.compare required in
  let properties_set = List.sort String.compare properties in
  Alcotest.(check (list string) "required ⊇ properties"
    properties_set required_set)

let test_passthrough_for_non_object () =
  Alcotest.check alcootest_json "string passthrough"
    (`String "not a schema")
    (Jsonschema.to_strict_object_schema (`String "not a schema"));
  Alcotest.check alcootest_json "int passthrough"
    (`Int 42)
    (Jsonschema.to_strict_object_schema (`Int 42));
  Alcotest.check alcootest_json "null passthrough"
    `Null
    (Jsonschema.to_strict_object_schema `Null);
  let non_object_schema : Yojson.Safe.t =
    `Assoc [ "type", `String "string" ]
  in
  Alcotest.check alcootest_json "non-object schema passthrough"
    non_object_schema
    (Jsonschema.to_strict_object_schema non_object_schema)

let () =
  Alcotest.run "test_jsonschema"
    [
      "derivation", [
        Alcotest.test_case "derived_schema_is_assoc" `Quick
          test_derived_schema_is_assoc;
        Alcotest.test_case "strict_wrapper_preserves_assoc" `Quick
          test_strict_wrapper_preserves_assoc;
        Alcotest.test_case "strict_wrapper_adds_additional_properties_false" `Quick
          test_strict_wrapper_adds_additional_properties_false;
        Alcotest.test_case "strict_wrapper_includes_all_properties_in_required" `Quick
          test_strict_wrapper_includes_all_properties_in_required;
        Alcotest.test_case "passthrough_for_non_object" `Quick
          test_passthrough_for_non_object;
      ];
    ]
