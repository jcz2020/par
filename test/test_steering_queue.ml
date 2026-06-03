open Par
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
  Alcotest.test_case "steer enqueues message" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.steer rt "user: redirect please";
      Alcotest.(check bool) "has pending" true
        (Par.Runtime.has_pending_steering rt);
      let msgs = Par.Runtime.drain_steering rt in
      Alcotest.(check (list string)) "messages" ["user: redirect please"] msgs;
      Alcotest.(check bool) "drained" false
        (Par.Runtime.has_pending_steering rt);
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "follow_up enqueues message" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.follow_up rt "next task";
      Alcotest.(check bool) "has pending" true
        (Par.Runtime.has_pending_followup rt);
      let msgs = Par.Runtime.drain_followup rt in
      Alcotest.(check (list string)) "messages" ["next task"] msgs;
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "FIFO ordering preserved" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.steer rt "first";
      Par.Runtime.steer rt "second";
      Par.Runtime.steer rt "third";
      let msgs = Par.Runtime.drain_steering rt in
      Alcotest.(check (list string)) "FIFO"
        ["first"; "second"; "third"] msgs;
      ignore (Par.Runtime.close rt)));

  Alcotest.test_case "queue overflow drops oldest" `Quick (fun () ->
    let q = Steering_queue.create ~capacity:3 () in
    Steering_queue.enqueue q "a";
    Steering_queue.enqueue q "b";
    Steering_queue.enqueue q "c";
    Steering_queue.enqueue q "d";
    Steering_queue.enqueue q "e";
    let msgs = Steering_queue.drain_all q in
    Alcotest.(check (list string)) "kept newest 3"
      ["c"; "d"; "e"] msgs;
    Alcotest.(check int) "count" 3 (Steering_queue.count q));

  Alcotest.test_case "has_items on empty queue" `Quick (fun () ->
    let q = Steering_queue.create () in
    Alcotest.(check bool) "empty" false (Steering_queue.has_items q);
    Steering_queue.enqueue q "x";
    Alcotest.(check bool) "after enqueue" true (Steering_queue.has_items q);
    ignore (Steering_queue.drain_all q);
    Alcotest.(check bool) "after drain" false (Steering_queue.has_items q));

  Alcotest.test_case "close prevents enqueue" `Quick (fun () ->
    let q = Steering_queue.create () in
    Steering_queue.enqueue q "before";
    Steering_queue.close q;
    Steering_queue.enqueue q "after";
    let msgs = Steering_queue.drain_all q in
    Alcotest.(check (list string)) "only before close" ["before"] msgs);

  Alcotest.test_case "steering and followup are independent" `Quick (fun () ->
    Eio_main.run (fun _env ->
      let rt = make_rt () in
      Par.Runtime.steer rt "steer-1";
      Par.Runtime.follow_up rt "follow-1";
      Alcotest.(check int) "steering count" 1
        (List.length (Par.Runtime.drain_steering rt));
      Alcotest.(check int) "followup count" 1
        (List.length (Par.Runtime.drain_followup rt));
      ignore (Par.Runtime.close rt)));
]

let () =
  Alcotest.run "steering_queue" [
    ("steering_queue", suite);
  ]
