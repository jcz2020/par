open Par_core
open Types

let eval_ok ctx expr =
  match Expression.evaluate ctx expr with
  | Result.Ok v -> v
  | Result.Error e ->
      let msg = match e with
        | Timeout -> "Timeout"
        | Invalid_input s -> "Invalid_input: " ^ s
        | External_failure s -> "External_failure: " ^ s
        | Rate_limited -> "Rate_limited"
        | Permission_denied s -> "Permission_denied: " ^ s
        | Internal s -> "Internal: " ^ s
      in
      Alcotest.fail ("expected Ok, got Error: " ^ msg)

let eval_bool_ok ctx expr =
  match Expression.evaluate_to_bool ctx expr with
  | Result.Ok b -> b
  | Result.Error e ->
      let msg = match e with
        | Internal s -> "Internal: " ^ s
        | _ -> "other error"
      in
      Alcotest.fail ("expected Ok bool, got Error: " ^ msg)

let eval_error ctx expr =
  match Expression.evaluate ctx expr with
  | Result.Error e -> e
  | Result.Ok _ -> Alcotest.fail "expected Error, got Ok"

let make_deep_not_chain n =
  let rec go i =
    if i <= 0 then Literal (`Bool true)
    else Not (go (i - 1))
  in
  go n

let make_balanced_and_tree depth =
  let rec go d =
    if d <= 0 then Literal (`Bool true)
    else
      let sub = go (d - 1) in
      And (sub, sub)
  in
  go depth

let literal_and_variable_suite =
  ("Literals and Variables", [
    Alcotest.test_case "Literal string evaluates to itself" `Quick (fun () ->
      let result = eval_ok [] (Literal (`String "hello")) in
      Yojson.Safe.equal (`String "hello") result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Literal int evaluates to itself" `Quick (fun () ->
      let result = eval_ok [] (Literal (`Int 42)) in
      Yojson.Safe.equal (`Int 42) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Literal bool evaluates to itself" `Quick (fun () ->
      let result = eval_ok [] (Literal (`Bool true)) in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Literal null evaluates to itself" `Quick (fun () ->
      let result = eval_ok [] (Literal `Null) in
      Yojson.Safe.equal `Null result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Variable resolves from context" `Quick (fun () ->
      let ctx = [("x", `Int 42)] in
      let result = eval_ok ctx (Variable "x") in
      Yojson.Safe.equal (`Int 42) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Variable with string value" `Quick (fun () ->
      let ctx = [("name", `String "alice")] in
      let result = eval_ok ctx (Variable "name") in
      Yojson.Safe.equal (`String "alice") result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Unknown variable returns Null" `Quick (fun () ->
      let result = eval_ok [] (Variable "missing") in
      Yojson.Safe.equal `Null result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Nested variable path (assoc)" `Quick (fun () ->
      let ctx = [("user", `Assoc [("name", `String "bob")])] in
      let result = eval_ok ctx (Variable "user.name") in
      Yojson.Safe.equal (`String "bob") result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Nested variable path (list index)" `Quick (fun () ->
      let ctx = [("items", `List [`String "a"; `String "b"; `String "c"])] in
      let result = eval_ok ctx (Variable "items.1") in
      Yojson.Safe.equal (`String "b") result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "List index out of bounds returns Null" `Quick (fun () ->
      let ctx = [("items", `List [`String "a"])] in
      let result = eval_ok ctx (Variable "items.5") in
      Yojson.Safe.equal `Null result
      |> Alcotest.check Alcotest.bool "equal" true);
  ])

let comparison_suite =
  ("Comparison operators", [
    Alcotest.test_case "Equals: identical literals are true" `Quick (fun () ->
      let expr = Equals (Literal (`Int 1), Literal (`Int 1)) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Equals: different literals are false" `Quick (fun () ->
      let expr = Equals (Literal (`String "a"), Literal (`String "b")) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Equals: variable matches literal" `Quick (fun () ->
      let ctx = [("x", `Int 10)] in
      let expr = Equals (Variable "x", Literal (`Int 10)) in
      let result = eval_ok ctx expr in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Not_equals: different values are true" `Quick (fun () ->
      let expr = Not_equals (Literal (`Int 1), Literal (`Int 2)) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Not_equals: same values are false" `Quick (fun () ->
      let expr = Not_equals (Literal (`Int 1), Literal (`Int 1)) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Greater_than: 5 > 3 is true" `Quick (fun () ->
      let expr = Greater_than (Literal (`Int 5), Literal (`Int 3)) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Greater_than: 3 > 5 is false" `Quick (fun () ->
      let expr = Greater_than (Literal (`Int 3), Literal (`Int 5)) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Less_than: 3 < 5 is true" `Quick (fun () ->
      let expr = Less_than (Literal (`Int 3), Literal (`Int 5)) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Less_than: 5 < 3 is false" `Quick (fun () ->
      let expr = Less_than (Literal (`Int 5), Literal (`Int 3)) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Greater_than with string numbers" `Quick (fun () ->
      let expr = Greater_than (Literal (`String "10"), Literal (`Int 5)) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);
  ])

let logic_suite =
  ("Logical operators", [
    Alcotest.test_case "And: true && true = true" `Quick (fun () ->
      let result = eval_ok [] (And (Literal (`Bool true), Literal (`Bool true))) in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "And: true && false = false" `Quick (fun () ->
      let result = eval_ok [] (And (Literal (`Bool true), Literal (`Bool false))) in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "And: false && true = false" `Quick (fun () ->
      let result = eval_ok [] (And (Literal (`Bool false), Literal (`Bool true))) in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Or: false || true = true" `Quick (fun () ->
      let result = eval_ok [] (Or (Literal (`Bool false), Literal (`Bool true))) in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Or: false || false = false" `Quick (fun () ->
      let result = eval_ok [] (Or (Literal (`Bool false), Literal (`Bool false))) in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Not: not true = false" `Quick (fun () ->
      let result = eval_ok [] (Not (Literal (`Bool true))) in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Not: not false = true" `Quick (fun () ->
      let result = eval_ok [] (Not (Literal (`Bool false))) in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "And with truthy ints: 1 && 2 = true" `Quick (fun () ->
      let result = eval_ok [] (And (Literal (`Int 1), Literal (`Int 2))) in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "And with falsy int: 0 && 1 = false" `Quick (fun () ->
      let result = eval_ok [] (And (Literal (`Int 0), Literal (`Int 1))) in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Not with truthy string: not 'hello' = false" `Quick (fun () ->
      let result = eval_ok [] (Not (Literal (`String "hello"))) in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Null is falsy" `Quick (fun () ->
      let result = eval_ok [] (Not (Literal `Null)) in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);
  ])

let container_suite =
  ("Container operators", [
    Alcotest.test_case "Contains: element in list" `Quick (fun () ->
      let expr = Contains (
        Literal (`List [`Int 1; `Int 2; `Int 3]),
        Literal (`Int 2)
      ) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Contains: element not in list" `Quick (fun () ->
      let expr = Contains (
        Literal (`List [`Int 1; `Int 2; `Int 3]),
        Literal (`Int 99)
      ) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Contains: substring in string" `Quick (fun () ->
      let expr = Contains (
        Literal (`String "hello world"),
        Literal (`String "wor")
      ) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Has_key: key exists in assoc" `Quick (fun () ->
      let expr = Has_key (
        Literal (`Assoc [("name", `String "bob"); ("age", `Int 30)]),
        "name"
      ) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Has_key: key missing from assoc" `Quick (fun () ->
      let expr = Has_key (
        Literal (`Assoc [("name", `String "bob")]),
        "email"
      ) in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Is_empty: null is empty" `Quick (fun () ->
      let result = eval_ok [] (Is_empty (Literal `Null)) in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Is_empty: empty list is empty" `Quick (fun () ->
      let result = eval_ok [] (Is_empty (Literal (`List []))) in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Is_empty: empty string is empty" `Quick (fun () ->
      let result = eval_ok [] (Is_empty (Literal (`String ""))) in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Is_empty: non-empty list is not empty" `Quick (fun () ->
      let result = eval_ok [] (Is_empty (Literal (`List [`Int 1]))) in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Matches: regex matches string" `Quick (fun () ->
      let result = eval_ok [] (
        Matches (Literal (`String "hello-123"), "hello-[0-9]+")
      ) in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Matches: regex does not match" `Quick (fun () ->
      let result = eval_ok [] (
        Matches (Literal (`String "hello"), "^[0-9]+$")
      ) in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Matches on non-string returns false" `Quick (fun () ->
      let result = eval_ok [] (
        Matches (Literal (`Int 42), ".*")
      ) in
      Yojson.Safe.equal (`Bool false) result
      |> Alcotest.check Alcotest.bool "equal" true);
  ])

let limit_suite =
  ("Resource limits", [
    Alcotest.test_case "Depth limit exceeded raises error" `Quick (fun () ->
      Expression.reset_visit ();
      let expr = make_deep_not_chain 11 in
      let err = eval_error [] expr in
      (match err with
       | Internal msg ->
           Alcotest.check Alcotest.bool "contains depth" true
             (String.contains msg 'd')
       | _ -> Alcotest.fail "expected Internal error"));

    Alcotest.test_case "Depth at limit (10) succeeds" `Quick (fun () ->
      Expression.reset_visit ();
      let expr = make_deep_not_chain 10 in
      let result = eval_ok [] expr in
      Yojson.Safe.equal (`Bool true) result
      |> Alcotest.check Alcotest.bool "equal" true);

    Alcotest.test_case "Node visit limit exceeded raises error" `Quick (fun () ->
      Expression.reset_visit ();
      let expr = make_balanced_and_tree 10 in
      let err = eval_error [] expr in
      (match err with
       | Internal msg ->
           Alcotest.check Alcotest.bool "contains visits" true
             (String.contains msg 'v')
       | _ -> Alcotest.fail "expected Internal error"));

    Alcotest.test_case "evaluate_to_bool returns bool" `Quick (fun () ->
      let result = eval_bool_ok [] (Literal (`Bool true)) in
      Alcotest.check Alcotest.bool "result" true result);

    Alcotest.test_case "evaluate_to_bool with comparison" `Quick (fun () ->
      let ctx = [("x", `Int 5)] in
      let expr = Greater_than (Variable "x", Literal (`Int 3)) in
      let result = eval_bool_ok ctx expr in
      Alcotest.check Alcotest.bool "5 > 3" true result);
  ])

let suite = [
  literal_and_variable_suite;
  comparison_suite;
  logic_suite;
  container_suite;
  limit_suite;
]
