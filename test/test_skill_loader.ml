open Par
open Par.Types

let () =
  let open Alcotest in
  let module T = Par.Types in

  let parse_tool_filter_tests = [
    test_case "All" `Quick (fun () ->
      match Skill_loader.parse_tool_filter "All" with
      | Ok All_tools -> ()
      | Ok _ -> Alcotest.fail "expected All_tools"
      | Error e -> Alcotest.fail ("expected Ok, got: " ^ e));

    test_case "Only list" `Quick (fun () ->
      match Skill_loader.parse_tool_filter "Only [read_file, write_file]" with
      | Ok (T.Only ["read_file"; "write_file"]) -> ()
      | other -> failwith ("expected Only, got " ^ (match other with Ok _ -> "wrong" | Error e -> e)));

    test_case "Except list" `Quick (fun () ->
      match Skill_loader.parse_tool_filter "Except [dangerous]" with
      | Ok (T.Except ["dangerous"]) -> ()
      | other -> failwith ("expected Except, got " ^ (match other with Ok _ -> "wrong" | Error e -> e)));
  ] in

  let parse_trigger_tests = [
    test_case "Auto" `Quick (fun () ->
      match Skill_loader.parse_trigger "Auto" with
      | Ok T.Auto -> ()
      | other -> failwith ("expected Auto, got " ^ (match other with Ok _ -> "wrong" | Error e -> e)));

    test_case "Manual" `Quick (fun () ->
      match Skill_loader.parse_trigger "Manual" with
      | Ok T.Manual -> ()
      | other -> failwith ("expected Manual, got " ^ (match other with Ok _ -> "wrong" | Error e -> e)));

    test_case "Keyword confirm (default)" `Quick (fun () ->
      match Skill_loader.parse_trigger "Keyword [pdf, form]" with
      | Ok (T.Keyword { keywords = ["pdf"; "form"]; llm_confirm = true }) -> ()
      | other -> failwith ("expected Keyword confirm, got " ^ (match other with Ok _ -> "wrong" | Error e -> e)));

    test_case "Keyword deterministic" `Quick (fun () ->
      match Skill_loader.parse_trigger "Keyword [pdf] deterministic" with
      | Ok (T.Keyword { keywords = ["pdf"]; llm_confirm = false }) -> ()
      | other -> failwith ("expected Keyword deterministic, got " ^ (match other with Ok _ -> "wrong" | Error e -> e)));

    test_case "Keyword explicit confirm" `Quick (fun () ->
      match Skill_loader.parse_trigger "Keyword [pdf] confirm" with
      | Ok (T.Keyword { keywords = ["pdf"]; llm_confirm = true }) -> ()
      | other -> failwith ("expected Keyword confirm, got " ^ (match other with Ok _ -> "wrong" | Error e -> e)));
  ] in

  let parse_skill_file_tests = [
    test_case "valid minimal" `Quick (fun () ->
      let tmp = Filename.temp_file "skill_min" ".md" in
      let oc = Stdlib.open_out tmp in
      output_string oc "---\nschema_version: 1\nid: test-skill\nname: Test\ndescription: A test skill\n---\n# Body\n";
      close_out oc;
      (match Skill_loader.parse_skill_file ~path:tmp with
       | Ok d ->
         check string "id" "test-skill" d.T.id;
         check string "name" "Test" d.T.name;
         check string "description" "A test skill" d.T.description;
         check bool "trigger default Auto" true (match d.T.trigger with T.Auto -> true | _ -> false);
         check bool "tool_filter default All" true (match d.T.tool_filter with T.All_tools -> true | _ -> false)
       | Error e -> failwith ("expected Ok, got Error: " ^ e));
      Sys.remove tmp);

    test_case "missing schema_version" `Quick (fun () ->
      let tmp = Filename.temp_file "skill_nosv" ".md" in
      let oc = Stdlib.open_out tmp in
      output_string oc "---\nid: x\nname: X\ndescription: d\n---\n";
      close_out oc;
      (match Skill_loader.parse_skill_file ~path:tmp with
       | Ok _ -> failwith "expected Error for missing schema_version"
       | Error e ->
         let mentions = (String.length e > 0) in
         check bool "error non-empty" true mentions);
      Sys.remove tmp);

    test_case "wrong schema_version" `Quick (fun () ->
      let tmp = Filename.temp_file "skill_wsv" ".md" in
      let oc = Stdlib.open_out tmp in
      output_string oc "---\nschema_version: 99\nid: x\nname: X\ndescription: d\n---\n";
      close_out oc;
      (match Skill_loader.parse_skill_file ~path:tmp with
       | Ok _ -> failwith "expected Error for wrong schema_version"
       | Error _ -> ());
      Sys.remove tmp);

    test_case "description too long" `Quick (fun () ->
      let tmp = Filename.temp_file "skill_long" ".md" in
      let oc = Stdlib.open_out tmp in
      let long_desc = String.make 2000 'x' in
      Printf.fprintf oc "---\nschema_version: 1\nid: x\nname: X\ndescription: %s\n---\n" long_desc;
      close_out oc;
      (match Skill_loader.parse_skill_file ~path:tmp with
       | Ok _ -> failwith "expected Error for long description"
       | Error _ -> ());
      Sys.remove tmp);

    test_case "with tool_filter and trigger" `Quick (fun () ->
      let tmp = Filename.temp_file "skill_full" ".md" in
      let oc = Stdlib.open_out tmp in
      output_string oc "---\nschema_version: 1\nid: full\nname: Full\ndescription: desc\ntool_filter: Only [a, b]\ntrigger: Keyword [x] deterministic\n---\n";
      close_out oc;
      (match Skill_loader.parse_skill_file ~path:tmp with
       | Ok d ->
         (match d.T.tool_filter with
          | T.Only ["a"; "b"] -> ()
          | _ -> failwith "wrong tool_filter");
         (match d.T.trigger with
          | T.Keyword { keywords = ["x"]; llm_confirm = false } -> ()
          | _ -> failwith "wrong trigger")
       | Error e -> failwith ("expected Ok, got: " ^ e));
      Sys.remove tmp);
  ] in

  let discover_tests = [
    test_case "discover from non-existent dir" `Quick (fun () ->
      let result = Skill_loader.discover ~user_dir:"/nonexistent/path" ~project_dir:"/another/nonexistent" () in
      check int "empty list" 0 (List.length result));
  ] in

  run "skill_loader"
    [ "tool_filter", parse_tool_filter_tests
    ; "trigger", parse_trigger_tests
    ; "parse_skill_file", parse_skill_file_tests
    ; "discover", discover_tests
    ]
