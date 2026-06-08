open Par.Types

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Par.Runtime.default_event_bus_config;
  default_quota = Par.Runtime.default_quota;
  shutdown = Par.Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = Par.Runtime.default_bash_confirm;
}

let make_rt () =
  Eio.Switch.run (fun sw ->
    match Par.Runtime.create ~config:test_config sw with
    | Ok r -> r
    | Error _ -> Alcotest.fail "create failed")

let suite = [
  Alcotest.test_case "initial health shows alive, never called" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      let h = Par.Runtime.health rt in
      Alcotest.(check bool) "alive" true h.runtime_alive;
      (match h.last_llm_call_at with
       | None -> ()
       | Some _ -> Alcotest.fail "expected None");
      (match h.last_llm_call_status with
       | `Never_called -> ()
       | _ -> Alcotest.fail "expected Never_called");
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "record_llm_success updates status" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.record_llm_success rt;
      let h = Par.Runtime.health rt in
      (match h.last_llm_call_status with
       | `Success -> ()
       | _ -> Alcotest.fail "expected Success");
      (match h.last_llm_call_at with
       | Some _ -> ()
       | None -> Alcotest.fail "expected Some");
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "record_llm_error updates status" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.record_llm_error rt (Par.Types.Internal "boom");
      let h = Par.Runtime.health rt in
      (match h.last_llm_call_status with
       | `Error (Par.Types.Internal _) -> ()
       | _ -> Alcotest.fail "expected Error Internal");
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "metrics starts at zero" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      let snap = Par.Runtime.metrics_snapshot rt in
      let count = function
        | "llm_requests_total" | "task_completed_total" | "task_failed_total"
        | "tool_invocations_total" | "events_published_total" | "events_dropped_total" -> true
        | _ -> false
      in
      Alcotest.(check int) "6 counters" 6 (List.length (List.filter (fun (k, _) -> count k) snap));
      Alcotest.(check bool) "all zero" true
        (List.for_all (fun (_, v) -> v = 0) snap);
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "record_llm increments counter" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.record_llm_success rt;
      Par.Runtime.record_llm_success rt;
      let snap = Par.Runtime.metrics_snapshot rt in
      let llm = List.assoc "llm_requests_total" snap in
      Alcotest.(check int) "llm count" 2 llm;
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "record_tool_invocation increments" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.record_tool_invocation rt;
      let snap = Par.Runtime.metrics_snapshot rt in
      Alcotest.(check int) "tool count" 1
        (List.assoc "tool_invocations_total" snap);
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "record_task_completed increments" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.record_task_completed rt;
      Par.Runtime.record_task_completed rt;
      Par.Runtime.record_task_completed rt;
      let snap = Par.Runtime.metrics_snapshot rt in
      Alcotest.(check int) "task_completed" 3
        (List.assoc "task_completed_total" snap);
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "record_task_failed increments" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.record_task_failed rt;
      let snap = Par.Runtime.metrics_snapshot rt in
      Alcotest.(check int) "task_failed" 1
        (List.assoc "task_failed_total" snap);
      ignore (Par.Runtime.close rt)));
]

let () =
  Alcotest.run "health_metrics" [
    ("health_metrics", suite);
  ]
