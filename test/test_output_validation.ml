open Par

let () =
  Alcotest.run "Output_validation" [
    ("output_validation", [
      Alcotest.test_case "middleware_name" `Quick (fun () ->
        let hook = Output_validation.validation () in
        Alcotest.(check string) "name" "output_validation" hook.Types.name);

      Alcotest.test_case "on_after_tool_none_on_success" `Quick (fun () ->
        let hook = Output_validation.validation () in
        let call = { Types.id = "t"; name = "echo"; arguments = `Assoc [] } in
        let result : Types.handler_result = Types.Success (`String "ok") in
        let out = match hook.Types.on_after_tool with
          | Some f -> f (call, result)
          | None -> None
        in
        match out with None -> () | Some _ -> Alcotest.fail "expected None");

      Alcotest.test_case "on_after_tool_none_on_error" `Quick (fun () ->
        let hook = Output_validation.validation () in
        let call = { Types.id = "t"; name = "echo"; arguments = `Assoc [] } in
        let err : Types.handler_result = Types.Error {
          category = Types.Internal "fail";
          message = "fail"; retryable = false; metadata = []
        } in
        let out = match hook.Types.on_after_tool with
          | Some f -> f (call, err)
          | None -> None
        in
        match out with None -> () | Some _ -> Alcotest.fail "expected None");
    ])
  ]
