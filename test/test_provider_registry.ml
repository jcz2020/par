(* v0.5.4 PAR-tiu: Provider_registry unit tests *)

open Par
open Types

let noop_llm : llm_service = {
  complete_fn = (fun _ _ _ -> Result.Error (Internal "noop"));
  stream_fn = (fun _ _ _ _ _ -> Result.Error (Internal "noop"));
  close_fn = ignore;
  complete_structured_fn = None;
}

let test_create_empty () =
  let r = Provider_registry.create () in
  Alcotest.(check (list string)) "empty ids" [] (Provider_registry.list_ids r);
  match Provider_registry.get_default r with
  | Error `No_default -> Alcotest.(check bool) "no default" true true
  | Ok _ -> Alcotest.fail "expected No_default"

let test_register_and_list () =
  let r = Provider_registry.create () in
  (match Provider_registry.register r ~id:"a" noop_llm with
   | Ok () -> ()
   | Error _ -> Alcotest.fail "register a failed");
  (match Provider_registry.register r ~id:"b" noop_llm with
   | Ok () -> ()
   | Error _ -> Alcotest.fail "register b should succeed");
  Alcotest.(check (list string)) "ids sorted" ["a"; "b"] (Provider_registry.list_ids r)

let test_first_registered_becomes_default () =
  let r = Provider_registry.create () in
  ignore (Provider_registry.register r ~id:"first" noop_llm);
  match Provider_registry.get_default r with
  | Ok _ -> ()
  | Error `No_default -> Alcotest.fail "first register should be default"

let test_duplicate_register_rejected () =
  let r = Provider_registry.create () in
  ignore (Provider_registry.register r ~id:"x" noop_llm);
  match Provider_registry.register r ~id:"x" noop_llm with
  | Error (`Duplicate _) -> ()
  | Ok _ -> Alcotest.fail "duplicate should be rejected"

let test_set_default_unknown_rejected () =
  let r = Provider_registry.create () in
  match Provider_registry.set_default r ~id:"nope" with
  | Error (`Unknown _) -> ()
  | Ok _ -> Alcotest.fail "unknown id should be rejected"

let test_get_by_id () =
  let r = Provider_registry.create () in
  ignore (Provider_registry.register r ~id:"q" noop_llm);
  match Provider_registry.get r ~id:"q" with
  | Ok _ -> ()
  | Error _ -> Alcotest.fail "get by id should succeed for registered id"

let () =
  let open Alcotest in
  run "Provider_registry" [
    "create_empty",               [ test_case "create_empty"               `Quick test_create_empty ];
    "register_and_list",          [ test_case "register_and_list"          `Quick test_register_and_list ];
    "first_is_default",           [ test_case "first_is_default"           `Quick test_first_registered_becomes_default ];
    "duplicate_rejected",         [ test_case "duplicate_rejected"         `Quick test_duplicate_register_rejected ];
    "set_default_unknown",        [ test_case "set_default_unknown"        `Quick test_set_default_unknown_rejected ];
    "get_by_id",                  [ test_case "get_by_id"                  `Quick test_get_by_id ];
  ]
