open Par
open Types

let small_config capacity = {
  buffer_capacity = capacity;
  delivery = {
    max_delivery_attempts = 3;
    initial_retry_delay = 0.1;
    retry_backoff = Exponential { base = 1.0; max_delay = 5.0 };
    delivery_timeout = 5.0;
  };
  dlq_enabled = true;
  critical_event_types = [];
}

let test_publish_does_not_block_when_stream_full () =
  let bus = Event_bus.create (small_config 1) in
  Event_bus.publish bus
    (Mcp_server_started { server_id = "srv-1"; server_name = "alpha" });
  Event_bus.publish bus
    (Mcp_server_started { server_id = "srv-2"; server_name = "beta" });
  Event_bus.publish bus
    (Mcp_server_started { server_id = "srv-3"; server_name = "gamma" });
  let dlq = Event_bus.get_dead_letters bus in
  Alcotest.(check int) "stream-full publishes route to DLQ" 2 (List.length dlq);
  let entries = Event_bus.dlq_entries bus in
  let server_id ev = match ev with
    | Mcp_server_started { server_id; _ } -> server_id
    | _ -> "other"
  in
  let ids = entries |> List.map server_id |> List.sort String.compare in
  Alcotest.(check (list string)) "DLQ entries are the rejected events"
    ["srv-2"; "srv-3"] ids

let test_publish_does_not_block_when_buffer_capacity_one () =
  let bus = Event_bus.create (small_config 1) in
  Event_bus.publish bus
    (Mcp_server_started { server_id = "srv-A"; server_name = "a" });
  Alcotest.(check int) "first event fits in buffer, no DLQ entry"
    0 (List.length (Event_bus.get_dead_letters bus))

let test_publish_under_capacity_never_uses_dlq () =
  let bus = Event_bus.create (small_config 8) in
  for _ = 1 to 4 do
    Event_bus.publish bus
      (Mcp_server_started { server_id = "srv"; server_name = "n" })
  done;
  Alcotest.(check int) "under-capacity publishes never route to DLQ"
    0 (List.length (Event_bus.get_dead_letters bus))

let test_dlq_entry_records_backpressure_reason () =
  let bus = Event_bus.create (small_config 1) in
  Event_bus.publish bus
    (Mcp_server_started { server_id = "srv-1"; server_name = "alpha" });
  Event_bus.publish bus
    (Mcp_server_started { server_id = "srv-2"; server_name = "beta" });
  let dlq = Event_bus.get_dead_letters bus in
  match dlq with
  | [ entry ] ->
    Alcotest.(check bool) "failure reason mentions backpressure"
      true (String.contains entry.error 'b' || String.contains entry.error 'B')
  | _ -> Alcotest.failf "expected 1 DLQ entry, got %d" (List.length dlq)

let () =
  Alcotest.run "event_bus_backpressure" [
    ("publish", [
      Alcotest.test_case "does not block when stream full" `Quick
        test_publish_does_not_block_when_stream_full;
      Alcotest.test_case "under-capacity never uses DLQ" `Quick
        test_publish_under_capacity_never_uses_dlq;
      Alcotest.test_case "first publish into size-1 buffer fits" `Quick
        test_publish_does_not_block_when_buffer_capacity_one;
      Alcotest.test_case "DLQ entry records backpressure reason" `Quick
        test_dlq_entry_records_backpressure_reason;
    ]);
  ]
