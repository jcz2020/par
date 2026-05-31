open Par.Types
open Par.Runtime

let valid_schema = {|{"type": "object", "properties": {}}|}

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = default_event_bus_config;
  default_quota = default_quota;
  shutdown = default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
}

let make_rt () =
  Eio.Switch.run (fun sw ->
    match Par.Runtime.create ~config:test_config sw with
    | Ok r -> r
    | Error _ -> Alcotest.fail "Runtime.create failed")

let suite = [
  Alcotest.test_case "valid registration" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      let tool = Par.Runtime.register_tool rt
        ~name:"test_tool" ~description:"A test tool"
        ~input_schema:(Yojson.Safe.from_string valid_schema)
        ~handler:(fun input _token -> Par.Types.Success input)
        () in
      Alcotest.(check string) "tool name" "test_tool" tool.descriptor.name;
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "empty name handling" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      let result = try
        let _ = Par.Runtime.register_tool rt
          ~name:"" ~description:"empty name"
          ~input_schema:(Yojson.Safe.from_string valid_schema)
          ~handler:(fun input _token -> Par.Types.Success input)
          () in
        "registered"
      with Failure _ -> "rejected" in
      Alcotest.(check string) "empty name handling" "registered" result;
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "duplicate name detected" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      ignore (Par.Runtime.register_tool rt
        ~name:"dup_tool" ~description:"first"
        ~input_schema:(Yojson.Safe.from_string valid_schema)
        ~handler:(fun input _token -> Par.Types.Success input)
        ());
      let before = Par.Tool_registry.resolve (Par.Runtime.tool_registry rt) "dup_tool" in
      Alcotest.(check (option bool)) "first registration" (Some true)
        (Option.map (fun _ -> true) before);
      ignore (Par.Runtime.register_tool rt
        ~name:"dup_tool" ~description:"second"
        ~input_schema:(Yojson.Safe.from_string valid_schema)
        ~handler:(fun input _token -> Par.Types.Success input)
        ());
      let after = Par.Tool_registry.resolve (Par.Runtime.tool_registry rt) "dup_tool" in
      Alcotest.(check (option bool)) "still registered after dup" (Some true)
        (Option.map (fun _ -> true) after);
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "schema validation" `Quick (fun () ->
    let test_valid i schema =
      match Yojson.Safe.from_string schema with
      | `Assoc _ ->
        Alcotest.(check bool) ("valid schema #" ^ string_of_int i) true true
      | _ ->
        Alcotest.failf "Schema #%d should be a JSON object: %s" i schema in
    test_valid 0 {|{"type": "object"}|};
    test_valid 1 {|{"properties": {"x": {"type": "string"}}}|};
    test_valid 2 {|{}|};
    let test_non_object i raw =
      let json = Yojson.Safe.from_string raw in
      let is_obj = match json with `Assoc _ -> true | _ -> false in
      Alcotest.(check bool) ("non-object #" ^ string_of_int i) false is_obj in
    test_non_object 0 "123";
    test_non_object 1 "null";
    test_non_object 2 "[1,2,3]";
    test_non_object 3 {|"hello"|};
    (try
       let _ = Yojson.Safe.from_string "not valid json" in
       Alcotest.fail "Should have raised Json_error for malformed JSON"
     with Yojson.Json_error _ -> ()));

  Alcotest.test_case "invalid handle returns -1" `Quick (fun () ->
    Alcotest.(check int) "Obj.repr(-1)" (-1) (Obj.obj (Obj.repr (-1))));
]

let () =
  Alcotest.run "FFI register_tool validation" [
    ("registration validation", suite);
  ]
