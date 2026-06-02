open Par
open Par.Types
open Par.Runtime

let valid_schema = `Assoc [("type", `String "object"); ("properties", `Assoc [])]

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
    match Runtime.create ~config:test_config sw with
    | Ok r -> r
    | Error _ -> Alcotest.fail "Runtime.create failed")

let suite = [
  Alcotest.test_case "first registration succeeds" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      (match Runtime.register_tool rt
         ~name:"my_tool" ~description:"test"
         ~input_schema:valid_schema
         ~handler:(fun input _token -> Success input) () with
       | Ok _ -> ()
       | Error _ -> Alcotest.fail "first registration should succeed");
      ignore (Runtime.close rt)));

  Alcotest.test_case "duplicate registration returns error" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      (match Runtime.register_tool rt
         ~name:"dup" ~description:"first"
         ~input_schema:valid_schema
         ~handler:(fun input _token -> Success input) () with
       | Ok _ -> ()
       | Error _ -> Alcotest.fail "first should succeed");
      let second = Runtime.register_tool rt
        ~name:"dup" ~description:"second"
        ~input_schema:valid_schema
        ~handler:(fun input _token -> Success input) () in
      (match second with
       | Ok _ -> Alcotest.fail "duplicate should fail"
       | Error (Invalid_input msg) ->
         Alcotest.(check bool) "error mentions tool name" true
           (String.contains msg 'd');
         Alcotest.(check bool) "error mentions 'registered'" true
           (String.contains msg 'r')
       | Error _ -> Alcotest.fail "expected Invalid_input error");
      ignore (Runtime.close rt)));

  Alcotest.test_case "tool_registry rejects duplicate" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let reg = Tool_registry.create () in
      let desc = {
        Types.name = "x";
        description = "x";
        input_schema = valid_schema;
        permission = Allow;
        timeout = None;
        concurrency_limit = None;
      } in
      let h : Tool_registry.handler_fn = fun input _token -> Success input in
      Alcotest.(check (result unit string)) "first" (Ok ())
        (match Tool_registry.register reg desc h with
         | Ok () -> Ok ()
         | Error `Duplicate_tool _ -> Error "should succeed");
      Alcotest.(check (result unit string)) "second" (Error "dup")
        (match Tool_registry.register reg desc h with
         | Ok () -> Ok ()
         | Error `Duplicate_tool _ -> Error "dup");
      ignore (Runtime.close (make_rt ()))));

  Alcotest.test_case "different names both succeed" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      (match Runtime.register_tool rt
         ~name:"tool_a" ~description:"a"
         ~input_schema:valid_schema
         ~handler:(fun input _token -> Success input) () with
       | Ok _ -> () | Error _ -> Alcotest.fail "a should succeed");
      (match Runtime.register_tool rt
         ~name:"tool_b" ~description:"b"
         ~input_schema:valid_schema
         ~handler:(fun input _token -> Success input) () with
       | Ok _ -> () | Error _ -> Alcotest.fail "b should succeed");
      ignore (Runtime.close rt)));
]

let () =
  Alcotest.run "duplicate_tool" [
    ("duplicate_tool", suite);
  ]
