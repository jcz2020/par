open Par

let valid_config = {
  Types.buffer_capacity = 16;
  delivery = {
    Types.max_delivery_attempts = 3;
    initial_retry_delay = 0.1;
    retry_backoff = Types.Exponential { base = 1.0; max_delay = 5.0 };
    delivery_timeout = 5.0;
  };
  dlq_enabled = true;
  critical_event_types = [];
}

let test_dlq_entries_empty_initially () =
  let bus = Event_bus.create valid_config in
  Alcotest.(check int) "DLQ starts empty" 0 (List.length (Event_bus.dlq_entries bus))

let test_dlq_entries_agrees_with_get_dead_letters () =
  let bus = Event_bus.create valid_config in
  Alcotest.(check int) "empty projection matches empty DLQ"
    (List.length (Event_bus.get_dead_letters bus))
    (List.length (Event_bus.dlq_entries bus))

let () =
  Alcotest.run "event_bus_dlq" [
    ("dlq_entries", [
      Alcotest.test_case "empty initially" `Quick test_dlq_entries_empty_initially;
      Alcotest.test_case "agrees with get_dead_letters on empty" `Quick
        test_dlq_entries_agrees_with_get_dead_letters;
    ]);
  ]
