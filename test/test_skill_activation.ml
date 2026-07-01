open Par.Types

let zone_str = function
  | Stable_prompt s | Volatile_prompt s -> s
  | Both_prompts { stable; _ } -> stable

let () =
  let open Alcotest in
  let tests = [
    test_case "compose empty" `Quick (fun () ->
      let c = Par.Runtime.compose_skill_effects [] in
      check bool "no override" true (c.system_prompt_override = None);
      check bool "all tools" true
        (match c.tool_filter_overlay with All_tools -> true | _ -> false));

    test_case "compose single identity" `Quick (fun () ->
      let e = { system_prompt_override = Some (Stable_prompt "x"); tool_filter_overlay = Only ["a"] } in
      let c = Par.Runtime.compose_skill_effects [e] in
      check (option string) "override" (Some "x") (Option.map zone_str c.system_prompt_override));

    test_case "compose two last-override-wins" `Quick (fun () ->
      let e1 = { system_prompt_override = Some (Stable_prompt "first"); tool_filter_overlay = All_tools } in
      let e2 = { system_prompt_override = Some (Stable_prompt "second"); tool_filter_overlay = All_tools } in
      let c = Par.Runtime.compose_skill_effects [e1; e2] in
      check (option string) "last wins" (Some "second") (Option.map zone_str c.system_prompt_override));

    test_case "compose intersection" `Quick (fun () ->
      let e1 = { system_prompt_override = None; tool_filter_overlay = Only ["a"; "b"; "c"] } in
      let e2 = { system_prompt_override = None; tool_filter_overlay = Only ["b"; "c"; "d"] } in
      let c = Par.Runtime.compose_skill_effects [e1; e2] in
      (match c.tool_filter_overlay with
       | Only result ->
         check int "intersection size" 2 (List.length result);
         check bool "has b" true (List.mem "b" result);
         check bool "has c" true (List.mem "c" result)
       | _ -> fail "expected Only"));

    test_case "compose All identity" `Quick (fun () ->
      let e = { system_prompt_override = None; tool_filter_overlay = Only ["x"] } in
      let c = Par.Runtime.compose_skill_effects [
        { system_prompt_override = None; tool_filter_overlay = All_tools }; e ] in
      (match c.tool_filter_overlay with
       | Only ["x"] -> ()
       | _ -> fail "expected Only [x]"));
  ] in
  run "skill_activation" [ "activation", tests ]
