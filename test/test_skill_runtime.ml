open Par.Types

let () =
  let open Alcotest in
  let tests = [
    test_case "make_skill valid" `Quick (fun () ->
      (match Par.Runtime.make_skill ~id:"test" ~description:"desc" () with
       | Result.Ok d -> check string "id" "test" d.id
       | Error _ -> failwith "should succeed"));

    test_case "make_skill empty id" `Quick (fun () ->
      (match Par.Runtime.make_skill ~id:"" ~description:"d" () with
       | Error _ -> ()
       | Result.Ok _ -> failwith "empty id should fail"));

    test_case "make_skill long description" `Quick (fun () ->
      (match Par.Runtime.make_skill ~id:"x" ~description:(String.make 2000 'x') () with
       | Error _ -> ()
       | Result.Ok _ -> failwith "long description should fail"));

    test_case "make_skill with options" `Quick (fun () ->
      (match Par.Runtime.make_skill ~id:"full" ~description:"d"
                ~system_prompt_override:"You are X"
                ~tool_filter:(Only ["a"; "b"])
                ~trigger:Manual () with
       | Result.Ok d ->
         check string "override" "You are X"
           (Option.value d.system_prompt_override ~default:"none");
         (match d.tool_filter with
          | Only ["a"; "b"] -> ()
          | _ -> failwith "wrong tool_filter");
         (match d.trigger with
          | Manual -> ()
          | _ -> failwith "wrong trigger")
       | Error _ -> failwith "should succeed"));
  ] in
  run "skill_runtime" [ "skill_runtime", tests ]
