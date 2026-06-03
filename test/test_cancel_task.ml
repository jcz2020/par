open Par.Types
open Par.Runtime

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = default_event_bus_config;
  default_quota = default_quota;
  shutdown = default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
}

let make_rt () =
  Eio.Switch.run (fun sw ->
    match Par.Runtime.create ~config:test_config sw with
    | Ok r -> r
    | Error _ -> Alcotest.fail "Runtime.create failed")

let suite = [
  Alcotest.test_case "cancel unknown task returns error" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      let task_id = match Task_id.of_string "00000000-0000-0000-0000-000000000000" with
        | Ok id -> id
        | Error _ -> Alcotest.fail "invalid UUID" in
      let result = cancel_task rt task_id in
      (match result with
       | Ok () -> Alcotest.fail "expected Error, got Ok"
       | Error (Invalid_input msg) ->
         Alcotest.(check string) "error message" "Task not found" msg
       | Error _ -> Alcotest.fail "expected Invalid_input error");
      ignore (close rt)));
]

let () =
  Alcotest.run "cancel_task tests" [
    ("cancel_task", suite);
  ]
