open Par.Types

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Par.Runtime.default_event_bus_config;
  default_quota = Par.Runtime.default_quota;
  shutdown = Par.Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
}

let make_rt () =
  Eio.Switch.run (fun sw ->
    match Par.Runtime.create ~config:test_config sw with
    | Ok r -> r
    | Error _ -> Alcotest.fail "create failed")

let suite = [
  Alcotest.test_case "register_tool accepts on_update" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      let calls = ref [] in
      let _ = match Par.Runtime.register_tool rt
        ~name:"progress_tool"
        ~description:"test"
        ~input_schema:(`Assoc [("type", `String "object")])
        ~handler:(fun input _tok -> Success input)
        ~on_update:(Some (fun msg -> calls := msg :: !calls))
        () with
      | Ok _ -> ()
      | Error _ -> Alcotest.fail "registration failed" in
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "register_tool without on_update still works" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      let _ = match Par.Runtime.register_tool rt
        ~name:"no_progress"
        ~description:"no on_update"
        ~input_schema:(`Assoc [("type", `String "object")])
        ~handler:(fun input _tok -> Success input)
        () with
      | Ok _ -> ()
      | Error _ -> Alcotest.fail "registration failed" in
      ignore (Par.Runtime.close rt)));
]

let () =
  Alcotest.run "on_update" [
    ("on_update", suite);
  ]
