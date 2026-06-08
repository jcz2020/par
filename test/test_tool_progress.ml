open Par.Types

let captured_events : event list ref = ref []

module Capture_bus : EVENT_BUS_SERVICE = struct
  type t = unit
  type subscription = unit
  let publish () evt = captured_events := evt :: !captured_events
  let subscribe () _h = ()
  let unsubscribe () _s = ()
end

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Par.Runtime.default_event_bus_config;
  default_quota = Par.Runtime.default_quota;
  shutdown = Par.Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = false;
  bash_confirm = Par.Runtime.default_bash_confirm;
}

let make_rt_with_capture () =
  captured_events := [];
  Eio.Switch.run (fun sw ->
    match Par.Runtime.create ~config:test_config
      ~event_bus:(module Capture_bus : EVENT_BUS_SERVICE)
      sw with
    | Ok r -> (r, sw)
    | Error _ -> Alcotest.fail "create failed")

let suite = [
  Alcotest.test_case "Runtime.publish_event writes to event_bus" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt, _sw = make_rt_with_capture () in
      let evt = Par.Types.Tool_progress {
        task_id = Par.Types.Task_id.create ();
        tool_name = "test";
        message = "hello";
      } in
      Par.Runtime.publish_event rt evt;
      Alcotest.(check int) "one event captured" 1 (List.length !captured_events);
      match List.hd !captured_events with
      | Tool_progress { message; _ } ->
        Alcotest.(check string) "message matches" "hello" message
      | _ -> Alcotest.fail "wrong event captured"));

  Alcotest.test_case "Noop_event_bus publish is a no-op" `Quick (fun () ->
    Eio_main.run (fun _env ->
      captured_events := [];
      Eio.Switch.run (fun sw ->
        match Par.Runtime.create ~config:test_config sw with
        | Ok rt ->
          let evt = Par.Types.Tool_progress {
            task_id = Par.Types.Task_id.create ();
            tool_name = "x";
            message = "y";
          } in
          Par.Runtime.publish_event rt evt;
          Alcotest.(check int) "default does not capture" 0 (List.length !captured_events)
        | Error _ -> Alcotest.fail "create failed")));
]

let () =
  Alcotest.run "tool_progress" [
    ("tool_progress", suite);
  ]
