open Par

let () =
  let module H = Hook in
  Alcotest.run "Bash_confirm" [
    ("bash_confirm", [
      Alcotest.test_case "non_bash_tool_passes_through" `Quick (fun () ->
        let config = { Types.default_policy = `Always; patterns = [] } in
        let hook = Bash_confirm.make_hook config in
        let ctx = { H.tool_name = "calculator"; H.tool_call_id = "1";
                    H.input = `Assoc []; H.has_ui = false } in
        (match hook ctx with H.Allow -> () | _ -> Alcotest.fail "expected Allow"));

      Alcotest.test_case "bash_with_never_policy_allows" `Quick (fun () ->
        let config = { Types.default_policy = `Never; patterns = [] } in
        let hook = Bash_confirm.make_hook config in
        let ctx = { H.tool_name = "bash"; H.tool_call_id = "1";
                    H.input = `Assoc []; H.has_ui = false } in
        (match hook ctx with H.Allow -> () | _ -> Alcotest.fail "expected Allow"));

      Alcotest.test_case "bash_with_always_policy_blocks_without_ui" `Quick (fun () ->
        let config = { Types.default_policy = `Always; patterns = [] } in
        let hook = Bash_confirm.make_hook config in
        let ctx = { H.tool_name = "bash"; H.tool_call_id = "1";
                    H.input = `Assoc []; H.has_ui = false } in
        (match hook ctx with H.Block _ -> () | _ -> Alcotest.fail "expected Block"));

      Alcotest.test_case "confirm_fn_true_allows_dangerous_command" `Quick (fun () ->
        let config = { Types.default_policy = `Always; patterns = [] } in
        let hook = Bash_confirm.make_hook ~confirm_fn:(fun _ -> true) config in
        let ctx = { H.tool_name = "bash"; H.tool_call_id = "1";
                    H.input = `Assoc [("command", `String "rm -rf /tmp")];
                    H.has_ui = false } in
        (match hook ctx with H.Allow -> () | _ -> Alcotest.fail "expected Allow"));

      Alcotest.test_case "confirm_fn_false_blocks_dangerous_command" `Quick (fun () ->
        let config = { Types.default_policy = `Always; patterns = [] } in
        let hook = Bash_confirm.make_hook ~confirm_fn:(fun _ -> false) config in
        let ctx = { H.tool_name = "bash"; H.tool_call_id = "1";
                    H.input = `Assoc [("command", `String "rm -rf /tmp")];
                    H.has_ui = false } in
        (match hook ctx with
         | H.Block { reason } ->
           Alcotest.(check string) "reason" "User denied bash command" reason
         | _ -> Alcotest.fail "expected Block"));
    ])
  ]
