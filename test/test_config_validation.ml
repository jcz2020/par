open Par
open Par.Types

let valid_event_bus = {
  Types.buffer_capacity = 100;
  delivery = {
    Types.max_delivery_attempts = 5;
    initial_retry_delay = 1.0;
    retry_backoff = Types.Exponential { base = 1.0; max_delay = 30.0 };
    delivery_timeout = 30.0;
  };
  dlq_enabled = false;
  critical_event_types = [];
}

let valid_shutdown = {
  Types.drain_timeout = 5.0;
  cancel_grace_period = 2.0;
  flush_batch_size = 10;
}

let valid_quota = {
  Types.max_concurrent_tasks = 10;
  max_concurrent_tools_per_agent = 5;
  max_tokens_per_turn = None;
  max_total_tokens = None;
}

let valid_eval_limits = {
  Types.max_depth = 10;
  max_node_visits = 1000;
}

let make_config ?(persistence = `Sqlite ":memory:") ?(llm_providers = []) () = {
  Types.persistence;
  event_bus = valid_event_bus;
  default_quota = valid_quota;
  shutdown = valid_shutdown;
  llm_providers;
  eval_limits = valid_eval_limits;
  parallel_tool_execution = true;
}

let suite = [
  Alcotest.test_case "valid config passes" `Quick (fun () ->
    match Validation.validate_runtime_config (make_config ()) with
    | Ok () -> ()
    | Error e -> Alcotest.failf "expected Ok, got: %s" e);

  Alcotest.test_case "buffer_capacity=0 fails" `Quick (fun () ->
    let bad_event_bus = { valid_event_bus with buffer_capacity = 0 } in
    let cfg = { (make_config ()) with event_bus = bad_event_bus } in
    match Validation.validate_runtime_config cfg with
    | Ok () -> Alcotest.fail "expected Error for buffer_capacity=0"
    | Error msg ->
      Alcotest.(check bool) "error mentions buffer_capacity" true
        (String.contains msg 'b'));

  Alcotest.test_case "negative drain_timeout fails" `Quick (fun () ->
    let bad_shutdown = { valid_shutdown with drain_timeout = -1.0 } in
    let cfg = { (make_config ()) with shutdown = bad_shutdown } in
    match Validation.validate_runtime_config cfg with
    | Ok () -> Alcotest.fail "expected Error for negative drain_timeout"
    | Error msg ->
      Alcotest.(check bool) "error mentions drain_timeout" true
        (String.contains msg 'd'));

  Alcotest.test_case "flush_batch_size=0 fails" `Quick (fun () ->
    let bad_shutdown = { valid_shutdown with flush_batch_size = 0 } in
    let cfg = { (make_config ()) with shutdown = bad_shutdown } in
    match Validation.validate_runtime_config cfg with
    | Ok () -> Alcotest.fail "expected Error for flush_batch_size=0"
    | Error _msg -> ());

  Alcotest.test_case "max_concurrent_tasks=0 fails" `Quick (fun () ->
    let bad_quota = { valid_quota with max_concurrent_tasks = 0 } in
    let cfg = { (make_config ()) with default_quota = bad_quota } in
    match Validation.validate_runtime_config cfg with
    | Ok () -> Alcotest.fail "expected Error"
    | Error _msg -> ());

  Alcotest.test_case "max_depth=0 fails" `Quick (fun () ->
    let bad_eval = { valid_eval_limits with max_depth = 0 } in
    let cfg = { (make_config ()) with eval_limits = bad_eval } in
    match Validation.validate_runtime_config cfg with
    | Ok () -> Alcotest.fail "expected Error"
    | Error _msg -> ());

  Alcotest.test_case "empty sqlite path fails" `Quick (fun () ->
    let cfg = { (make_config ()) with persistence = `Sqlite "" } in
    match Validation.validate_runtime_config cfg with
    | Ok () -> Alcotest.fail "expected Error for empty sqlite path"
    | Error msg ->
      Alcotest.(check bool) "error mentions persistence" true
        (String.contains msg 'p'));

  Alcotest.test_case "empty openai api_key fails" `Quick (fun () ->
    let cfg = { (make_config ()) with
                llm_providers = ["openai", Types.Openai { api_key = ""; base_url = None; organization = None }] } in
    match Validation.validate_runtime_config cfg with
    | Ok () -> Alcotest.fail "expected Error for empty api_key"
    | Error msg ->
      Alcotest.(check bool) "error mentions api_key" true
        (String.contains msg 'k'));

  Alcotest.test_case "valid openai config passes" `Quick (fun () ->
    let cfg = { (make_config ()) with
                llm_providers = ["openai", Types.Openai { api_key = "sk-valid"; base_url = None; organization = None }] } in
    match Validation.validate_runtime_config cfg with
    | Ok () -> ()
    | Error e -> Alcotest.failf "expected Ok, got: %s" e);

  Alcotest.test_case "Runtime.create rejects invalid config" `Quick (fun () ->
    let bad_quota = { valid_quota with max_concurrent_tasks = 0 } in
    let cfg = { (make_config ()) with default_quota = bad_quota } in
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        match Par.Runtime.create ~config:cfg sw with
        | Ok _ -> Alcotest.fail "Runtime.create should reject invalid config"
        | Error _ -> ())));

  Alcotest.test_case "temperature 0.0 accepted" `Quick (fun () ->
    match Validation.validate_temperature 0.0 with
    | Ok () -> ()
    | Error e -> Alcotest.failf "expected Ok, got: %s" e);

  Alcotest.test_case "temperature 0.7 accepted" `Quick (fun () ->
    match Validation.validate_temperature 0.7 with
    | Ok () -> ()
    | Error e -> Alcotest.failf "expected Ok, got: %s" e);

  Alcotest.test_case "temperature 2.0 accepted (upper bound inclusive)" `Quick (fun () ->
    match Validation.validate_temperature 2.0 with
    | Ok () -> ()
    | Error e -> Alcotest.failf "expected Ok, got: %s" e);

  Alcotest.test_case "temperature negative rejected" `Quick (fun () ->
    match Validation.validate_temperature (-0.1) with
    | Ok () -> Alcotest.fail "expected Error for negative temperature"
    | Error msg ->
      Alcotest.(check bool) "error mentions temperature" true
        (String.contains msg 't'));

  Alcotest.test_case "temperature above 2.0 rejected" `Quick (fun () ->
    match Validation.validate_temperature 2.5 with
    | Ok () -> Alcotest.fail "expected Error for temperature > 2.0"
    | Error msg ->
      Alcotest.(check bool) "error mentions temperature" true
        (String.contains msg 't'));

  Alcotest.test_case "temperature infinity rejected" `Quick (fun () ->
    match Validation.validate_temperature infinity with
    | Ok () -> Alcotest.fail "expected Error for infinity"
    | Error _ -> ());

  Alcotest.test_case "temperature NaN rejected" `Quick (fun () ->
    match Validation.validate_temperature nan with
    | Ok () -> Alcotest.fail "expected Error for NaN"
    | Error _ -> ());

  Alcotest.test_case "validate_temperature_result wraps as Invalid_input" `Quick (fun () ->
    match Validation.validate_temperature_result 3.0 with
    | Ok () -> Alcotest.fail "expected Error"
    | Error (Invalid_input _) -> ()
    | Error _ -> Alcotest.fail "expected Invalid_input");
]

let () =
  Alcotest.run "runtime_config_validation" [
    ("validation", suite);
  ]
