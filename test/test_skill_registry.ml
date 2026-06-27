open Par
open Par.Types

(* test/test_skill_registry.ml — v0.5.2 / A.1 (PAR-haz)
   Coverage: CRUD operations on Skill_registry (Hashtbl-backed), mirroring
   the Tool_registry test pattern in test_duplicate_tool.ml.

   These tests do NOT call activate (which requires a real runtime value);
   A.1 only exercises the registry surface. Runtime integration lands in A.3a. *)

let make_skill ?(schema_version = 1) ?(system_prompt_override = None)
    ?(tool_filter = All_tools) ?(trigger = Auto)
    ?(expected_output = None) ?(body_path = "") id name description : Types.skill_descriptor =
  {
    schema_version;
    id;
    name;
    description;
    system_prompt_override;
    tool_filter;
    trigger;
    expected_output;
    body_path;
  }

let make_binding desc : Types.skill_binding =
  {
    descriptor = desc;
    activate = (fun () : Types.skill_effect ->
      { system_prompt_override = None; tool_filter_overlay = All_tools });
  }

let test_create_empty_registry () =
  let reg = Skill_registry.create () in
  Alcotest.(check (list string)) "empty list" [] (Skill_registry.list reg)

let test_register_one_skill () =
  let reg = Skill_registry.create () in
  let desc = make_skill "code-review" "Code Reviewer" "Reviews code" in
  Alcotest.(check (result unit string)) "register"
    (Ok ())
    (match Skill_registry.register reg (make_binding desc) with
     | Ok () -> Ok ()
     | Error `Duplicate_skill _ -> Error "dup");
  Alcotest.(check (list string)) "list"
    ["code-review"] (Skill_registry.list reg)

let test_register_duplicate_id () =
  let reg = Skill_registry.create () in
  let d1 = make_skill "foo" "Foo 1" "first" in
  let d2 = make_skill "foo" "Foo 2" "second" in
  let r1 = Skill_registry.register reg (make_binding d1) in
  let r2 = Skill_registry.register reg (make_binding d2) in
  Alcotest.(check (result unit string)) "first ok" (Ok ())
    (match r1 with Ok () -> Ok () | Error _ -> Error "should succeed");
  (match r2 with
   | Ok () -> Alcotest.fail "duplicate should fail"
   | Error (`Duplicate_skill id) ->
     Alcotest.(check string) "id in error" "foo" id)

let test_lookup_existing () =
  let reg = Skill_registry.create () in
  let desc = make_skill "summarizer" "Summarizer" "Summarizes text" in
  ignore (Skill_registry.register reg (make_binding desc));
  Alcotest.(check bool) "lookup found" true
    (Option.is_some (Skill_registry.resolve reg "summarizer"))

let test_lookup_nonexistent () =
  let reg = Skill_registry.create () in
  Alcotest.(check (option string)) "lookup None" None
    (Option.map
       (fun (_ : Skill_registry.activate_fn) -> "found")
       (Skill_registry.resolve reg "missing"))

let test_remove_existing () =
  let reg = Skill_registry.create () in
  let desc = make_skill "translator" "Translator" "Translates text" in
  ignore (Skill_registry.register reg (make_binding desc));
  Alcotest.(check (result unit string)) "remove"
    (Ok ())
    (match Skill_registry.remove reg "translator" with
     | Ok () -> Ok ()
     | Error `Not_found _ -> Error "should exist");
  Alcotest.(check (list string)) "empty after remove" [] (Skill_registry.list reg)

let test_remove_nonexistent () =
  let reg = Skill_registry.create () in
  (match Skill_registry.remove reg "ghost" with
   | Ok () -> Alcotest.fail "remove missing should fail"
   | Error `Not_found id ->
     Alcotest.(check string) "id in error" "ghost" id)

let test_register_three_list_all () =
  let reg = Skill_registry.create () in
  List.iter (fun (id, name) ->
    let d = make_skill id name ("desc for " ^ id) in
    ignore (Skill_registry.register reg (make_binding d)))
    ["a", "Alpha"; "b", "Beta"; "c", "Gamma"];
  Alcotest.(check (list string)) "all three sorted"
    ["a"; "b"; "c"] (Skill_registry.list reg)

let test_replace_existing () =
  let reg = Skill_registry.create () in
  let d1 = make_skill "x" "X v1" "first" in
  ignore (Skill_registry.register reg (make_binding d1));
  let new_activate : Skill_registry.activate_fn =
    fun () -> { system_prompt_override = Some "replaced";
                 tool_filter_overlay = All_tools } in
  Skill_registry.replace reg "x" new_activate;
  Alcotest.(check bool) "still has x" true
    (Option.is_some (Skill_registry.resolve reg "x"));
  Alcotest.(check (list string)) "still one entry" ["x"] (Skill_registry.list reg)

let test_find_descriptor () =
  let skills : Types.skill_descriptor list = [
    make_skill "a" "Alpha" "first";
    make_skill "b" "Beta" "second";
  ] in
  let found = Skill_registry.find_descriptor skills "b" in
  Alcotest.(check (option string)) "found b" (Some "Beta")
    (Option.map (fun (d : Types.skill_descriptor) -> d.name) found);
  Alcotest.(check (option string)) "missing c" None
    (Option.map (fun (d : Types.skill_descriptor) -> d.name)
       (Skill_registry.find_descriptor skills "c"))

let test_keyword_trigger_storage () =
  (* Verify all three trigger ADT cases survive registry round-trip. *)
  let reg = Skill_registry.create () in
  let d_auto = make_skill "auto-1" "A" "auto" ~trigger:Auto in
  let d_manual = make_skill "manual-1" "M" "manual" ~trigger:Manual in
  let d_kw = make_skill "kw-1" "K" "kw"
    ~trigger:(Keyword { keywords = ["pdf"; "form"]; llm_confirm = false }) in
  List.iter (fun d -> ignore (Skill_registry.register reg (make_binding d)))
    [d_auto; d_manual; d_kw];
  Alcotest.(check (int)) "count" 3 (List.length (Skill_registry.list reg))

let () =
  Alcotest.run "skill_registry" [
    ("skill_registry", [
      Alcotest.test_case "create empty registry" `Quick test_create_empty_registry;
      Alcotest.test_case "register one skill" `Quick test_register_one_skill;
      Alcotest.test_case "register duplicate id" `Quick test_register_duplicate_id;
      Alcotest.test_case "lookup existing skill" `Quick test_lookup_existing;
      Alcotest.test_case "lookup non-existent" `Quick test_lookup_nonexistent;
      Alcotest.test_case "remove existing" `Quick test_remove_existing;
      Alcotest.test_case "remove non-existent" `Quick test_remove_nonexistent;
      Alcotest.test_case "register three list all" `Quick test_register_three_list_all;
      Alcotest.test_case "replace existing" `Quick test_replace_existing;
      Alcotest.test_case "find_descriptor" `Quick test_find_descriptor;
      Alcotest.test_case "keyword trigger storage" `Quick test_keyword_trigger_storage;
    ]);
  ]
