open Par.Types

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Par.Runtime.default_event_bus_config;
  default_quota = Par.Runtime.default_quota;
  shutdown = Par.Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
}

let make_rt () =
  Eio.Switch.run (fun sw ->
    match Par.Runtime.create ~config:test_config sw with
    | Ok r -> r
    | Error _ -> Alcotest.fail "create failed")

let dummy_ctx = {
  Par.Hook.tool_name = "test";
  tool_call_id = "tc-1";
  input = `Assoc [];
  has_ui = false;
}

let suite = [
  Alcotest.test_case "empty hook chain returns allow" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      let result = Par.Runtime.run_tool_call_hooks rt dummy_ctx in
      (match result with
       | Par.Hook.Final_allow -> ()
       | _ -> Alcotest.fail "expected Final_allow");
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "allow hook returns allow" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.register_tool_call_hook rt (fun _ctx -> Par.Hook.Allow);
      let result = Par.Runtime.run_tool_call_hooks rt dummy_ctx in
      (match result with
       | Par.Hook.Final_allow -> ()
       | _ -> Alcotest.fail "expected Final_allow");
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "block hook returns block" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.register_tool_call_hook rt (fun _ctx ->
        Par.Hook.Block { reason = "denied" });
      let result = Par.Runtime.run_tool_call_hooks rt dummy_ctx in
      (match result with
       | Par.Hook.Final_block msg ->
         Alcotest.(check string) "reason" "denied" msg
       | _ -> Alcotest.fail "expected Final_block");
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "modify hook transforms input" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.register_tool_call_hook rt (fun _ctx ->
        Par.Hook.Modify { input = `String "modified" });
      let result = Par.Runtime.run_tool_call_hooks rt dummy_ctx in
      (match result with
       | Par.Hook.Final_modify (`String s) ->
         Alcotest.(check string) "modified" "modified" s
       | _ -> Alcotest.fail "expected Final_modify");
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "block wins over allow (first block wins)" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.register_tool_call_hook rt (fun _ctx -> Par.Hook.Allow);
      Par.Runtime.register_tool_call_hook rt (fun _ctx ->
        Par.Hook.Block { reason = "second blocks" });
      let result = Par.Runtime.run_tool_call_hooks rt dummy_ctx in
      (match result with
       | Par.Hook.Final_block "second blocks" -> ()
       | _ -> Alcotest.fail "first block wins");
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "clear_tool_call_hooks resets chain" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.register_tool_call_hook rt (fun _ctx ->
        Par.Hook.Block { reason = "denied" });
      Par.Runtime.clear_tool_call_hooks rt;
      let result = Par.Runtime.run_tool_call_hooks rt dummy_ctx in
      (match result with
       | Par.Hook.Final_allow -> ()
       | _ -> Alcotest.fail "expected allow after clear");
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "chain applies modifies in order" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.register_tool_call_hook rt (fun _ctx ->
        Par.Hook.Modify { input = `String "step1" });
      Par.Runtime.register_tool_call_hook rt (fun ctx ->
        match ctx.input with
        | `String "step1" -> Par.Hook.Modify { input = `String "step2" }
        | _ -> Par.Hook.Allow);
      let result = Par.Runtime.run_tool_call_hooks rt dummy_ctx in
      (match result with
       | Par.Hook.Final_modify (`String "step2") -> ()
       | Par.Hook.Final_modify s ->
         Alcotest.failf "got %s, expected step2" (Yojson.Safe.to_string s)
       | _ -> Alcotest.fail "expected Final_modify");
      ignore (Par.Runtime.close rt)));
]

let () =
  Alcotest.run "tool_call_hooks" [
    ("tool_call_hooks", suite);
  ]
