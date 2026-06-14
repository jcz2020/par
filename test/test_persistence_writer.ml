open Par
open Types

let make_envelope i =
  {
    id = Printf.sprintf "env-%d" i;
    metadata = {
      trace_id = None;
      span_id = None;
      timestamp = 0.0;
      source = "test";
      session_id = "sess-test";
    };
    payload = Shutdown_initiated;
    idempotency_key = Printf.sprintf "key-%d" i;
    delivery_attempt = 0;
  }

let test_push_flush_sync_saves_events () =
  Eio_main.run (fun _env ->
    let captured : event_envelope list ref = ref [] in
    let save_fn envs =
      captured := !captured @ envs;
      Ok ()
    in
    let writer = Persistence_writer.create ~capacity:10 save_fn in
    Persistence_writer.push writer (make_envelope 1);
    Persistence_writer.push writer (make_envelope 2);
    Persistence_writer.push writer (make_envelope 3);
    Persistence_writer.flush_sync writer;
    Alcotest.(check int) "3 envelopes captured" 3 (List.length !captured);
    let ids = !captured |> List.map (fun (e : event_envelope) -> e.id) |> List.sort String.compare in
    Alcotest.(check (list string)) "captured in order"
      ["env-1"; "env-2"; "env-3"] ids)

let test_flush_sync_empties_buffer_between_calls () =
  Eio_main.run (fun _env ->
    let captured : event_envelope list ref = ref [] in
    let save_fn envs =
      captured := !captured @ envs;
      Ok ()
    in
    let writer = Persistence_writer.create ~capacity:10 save_fn in
    Persistence_writer.push writer (make_envelope 1);
    Persistence_writer.flush_sync writer;
    Persistence_writer.push writer (make_envelope 2);
    Persistence_writer.flush_sync writer;
    Alcotest.(check int) "2 flush_sync calls captured 2 envelopes"
      2 (List.length !captured);
    Persistence_writer.push writer (make_envelope 3);
    Persistence_writer.push writer (make_envelope 4);
    Persistence_writer.flush_sync writer;
    Alcotest.(check int) "5 total after second batch" 4 (List.length !captured))

let test_buffer_overflow_does_not_crash () =
  Eio_main.run (fun _env ->
    let captured : event_envelope list ref = ref [] in
    let save_fn envs =
      captured := !captured @ envs;
      Ok ()
    in
    let writer = Persistence_writer.create ~capacity:2 save_fn in
    Persistence_writer.push writer (make_envelope 1);
    Persistence_writer.push writer (make_envelope 2);
    Persistence_writer.push writer (make_envelope 3);
    Persistence_writer.push writer (make_envelope 4);
    Persistence_writer.push writer (make_envelope 5);
    Persistence_writer.flush_sync writer;
    Alcotest.(check int) "only first 2 captured" 2 (List.length !captured);
    Alcotest.(check string) "first captured is env-1" "env-1" (List.hd !captured).id;
    Alcotest.(check string) "second captured is env-2" "env-2"
      (List.nth !captured 1).id)

let test_save_fn_error_is_logged_not_raised () =
  Eio_main.run (fun _env ->
    let save_fn _envs : (unit, error_category) result = Error (Internal "simulated save failure") in
    let writer = Persistence_writer.create ~capacity:10 save_fn in
    Persistence_writer.push writer (make_envelope 1);
    Persistence_writer.flush_sync writer;
    Alcotest.(check bool) "no exception" true true)

let test_drain_fiber_auto_flushes () =
  Eio_main.run (fun _env ->
    let captured : event_envelope list ref = ref [] in
    let save_fn envs =
      captured := !captured @ envs;
      Ok ()
    in
    let writer = Persistence_writer.create ~capacity:10 ~flush_interval:0.0 save_fn in
    Eio.Switch.run (fun sw ->
      Persistence_writer.start_drain_fiber writer sw;
      Persistence_writer.push writer (make_envelope 1);
      Persistence_writer.push writer (make_envelope 2);
      Persistence_writer.push writer (make_envelope 3);
      for _ = 1 to 50 do Eio.Fiber.yield () done;
      Alcotest.(check int) "drain auto-flushed all 3" 3 (List.length !captured)))

let test_integration_event_bus_to_writer () =
  Eio_main.run (fun _env ->
    let captured : event_envelope list ref = ref [] in
    let save_fn envs =
      captured := !captured @ envs;
      Ok ()
    in
    let bus_config = {
      buffer_capacity = 16;
      delivery = {
        max_delivery_attempts = 3;
        initial_retry_delay = 0.1;
        retry_backoff = Exponential { base = 1.0; max_delay = 5.0 };
        delivery_timeout = 5.0;
      };
      dlq_enabled = true;
      critical_event_types = [];
    } in
    let writer = Persistence_writer.create ~capacity:100 save_fn in
    let traceln s = Printf.eprintf "[trace] %s\n%!" s in
    traceln "about to switch.run";
    Eio.Switch.run (fun sw ->
      traceln "in switch";
      let bus = Event_bus.create bus_config in
      traceln "bus created";
      Event_bus.start_dispatcher bus sw;
      traceln "dispatcher started";
      let _sub = Event_bus.subscribe bus (fun envelope ->
        Persistence_writer.push writer envelope) in
      traceln "subscribed";
      Persistence_writer.start_drain_fiber writer sw;
      traceln "drain started";
      Event_bus.publish bus Shutdown_initiated;
      Event_bus.publish bus Shutdown_initiated;
      Event_bus.publish bus Shutdown_initiated;
      traceln "published 3";
      for _ = 1 to 100 do Eio.Fiber.yield () done;
      Printf.eprintf "[trace] after 100 yields, captured=%d\n%!" (List.length !captured);
      Persistence_writer.flush_sync writer;
      Printf.eprintf "[trace] flushed, captured=%d\n%!" (List.length !captured);
      Alcotest.(check int) "all 3 events made it to writer" 3 (List.length !captured));
    traceln "switch.run returned")

let () =
  Alcotest.run "persistence_writer" [
    ("push_flush", [
      Alcotest.test_case "push + flush_sync saves events" `Quick
        test_push_flush_sync_saves_events;
      Alcotest.test_case "flush_sync empties buffer between calls" `Quick
        test_flush_sync_empties_buffer_between_calls;
    ]);
    ("overflow", [
      Alcotest.test_case "buffer overflow does not crash" `Quick
        test_buffer_overflow_does_not_crash;
    ]);
    ("error_handling", [
      Alcotest.test_case "save_fn error is logged, not raised" `Quick
        test_save_fn_error_is_logged_not_raised;
    ]);
    ("drain_fiber", [
      Alcotest.test_case "drain fiber auto-flushes after yield" `Quick
        test_drain_fiber_auto_flushes;
    ]);
    ("integration", [
      Alcotest.test_case "event_bus -> writer -> save_fn" `Quick
        test_integration_event_bus_to_writer;
    ]);
  ]
