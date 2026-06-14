(* test/test_mcp_runtime.ml — v0.3.1 W2
   Tests for Runtime.create MCP server spawning + Runtime.close MCP shutdown.
   Each test calls [Eio_main.run] once at the entry point. Events published
   by Runtime.create / Runtime.close are captured via a custom event_bus_service
   record and asserted on after the operation completes. *)

open Par.Types

let captured_events : event list ref = ref []

let capture_bus : event_bus_service = {
  publish_fn = (fun evt -> captured_events := evt :: !captured_events);
  subscribe_fn = (fun _handler -> "");
  unsubscribe_fn = (fun _sub -> ());
  set_session_id_fn = (fun _sid -> ());
  start_dispatcher_fn = (fun _sw -> ());
}

let reset_capture () = captured_events := []

let string_of_error_category (ec : Par.Types.error_category) =
  match ec with
  | Par.Types.Timeout -> "Timeout"
  | Par.Types.Invalid_input s -> Printf.sprintf "Invalid_input(%s)" s
  | Par.Types.External_failure s -> Printf.sprintf "External_failure(%s)" s
  | Par.Types.Rate_limited -> "Rate_limited"
  | Par.Types.Permission_denied s -> Printf.sprintf "Permission_denied(%s)" s
  | Par.Types.Internal s -> Printf.sprintf "Internal(%s)" s

let mock_path =
  match Sys.getenv_opt "MCP_MOCK_PATH" with
  | Some p -> p
  | None ->
    let cwd = Sys.getcwd () in
    let here = Filename.concat cwd "mcp_mock_server.exe" in
    if Sys.file_exists here then here
    else begin
      let abs_here = Filename.concat cwd "_build/default/test/mcp_mock_server.exe" in
      if Sys.file_exists abs_here then abs_here
      else "/root/dev/PAR/_build/default/test/mcp_mock_server.exe"
    end

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Par.Runtime.default_event_bus_config;
  default_quota = Par.Runtime.default_quota;
  shutdown = Par.Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = Par.Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
}

let htbl_count tbl =
  let n = ref 0 in
  Par.Types.htbl_iter tbl (fun _ _ -> incr n);
  !n

let htbl_keys tbl =
  let acc = ref [] in
  Par.Types.htbl_iter tbl (fun k _ -> acc := k :: !acc);
  List.rev !acc

let is_mcp_event (e : Par.Types.event) =
  match e with
  | Mcp_server_started _ | Mcp_server_failed _ | Mcp_server_stopped _ -> true
  | _ -> false

let count_stopped () =
  List.fold_left (fun acc e ->
    match e with Mcp_server_stopped _ -> acc + 1 | _ -> acc
  ) 0 !captured_events

let mock_config ?(name = "test-server") ?(startup_timeout = 5.0) () : Par.Mcp_types.server_config =
  {
    name;
    command = mock_path;
    args = [];
    env = [];
    cwd = None;
    startup_timeout;
  }

let bad_config () : Par.Mcp_types.server_config =
  {
    name = "bad-server";
    command = "/nonexistent/binary_xyz";
    args = [];
    env = [];
    cwd = None;
    startup_timeout = 2.0;
  }

let test_create_no_mcp_servers () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      match Par.Runtime.create ~config:test_config sw with
      | Ok rt ->
        Alcotest.(check int) "mcp_servers empty" 0
          (htbl_count (Par.Runtime.mcp_servers rt));
        ignore (Par.Runtime.close rt)
      | Error e -> Alcotest.failf "create failed: %s" (string_of_error_category e)))

let test_create_with_mcp_servers_spawns () =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clk = Eio.Stdenv.clock env in
    Eio.Switch.run (fun sw ->
      let cfg = mock_config () in
      match Par.Runtime.create ~config:test_config
             ~mcp_servers:[cfg] ~mcp_process_mgr:mgr ~mcp_clock:clk sw with
      | Ok rt ->
        Alcotest.(check int) "one server spawned" 1
          (htbl_count (Par.Runtime.mcp_servers rt));
        ignore (Par.Runtime.close rt)
      | Error e -> Alcotest.failf "create failed: %s" (string_of_error_category e)))

let test_create_without_process_mgr_returns_error () =
  Eio_main.run (fun env ->
    let _ = Eio.Stdenv.clock env in
    Eio.Switch.run (fun sw ->
      let cfg = mock_config () in
      match Par.Runtime.create ~config:test_config ~mcp_servers:[cfg] sw with
      | Ok _ -> Alcotest.fail "expected error when mcp_process_mgr missing"
      | Error ec ->
        match ec with
        | Par.Types.Invalid_input _ -> ()
        | _ -> Alcotest.failf "expected Invalid_input, got %s" (string_of_error_category ec)))

let test_create_without_clock_returns_error () =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    Eio.Switch.run (fun sw ->
      let cfg = mock_config () in
      match Par.Runtime.create ~config:test_config
             ~mcp_servers:[cfg] ~mcp_process_mgr:mgr sw with
      | Ok _ -> Alcotest.fail "expected error when mcp_clock missing"
      | Error ec ->
        match ec with
        | Par.Types.Invalid_input _ -> ()
        | _ -> Alcotest.failf "expected Invalid_input, got %s" (string_of_error_category ec)))

let test_create_log_and_continue_skips_bad () =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clk = Eio.Stdenv.clock env in
    Eio.Switch.run (fun sw ->
      let good = mock_config () in
      let bad = bad_config () in
      match Par.Runtime.create ~config:test_config
             ~mcp_servers:[bad; good]
             ~mcp_process_mgr:mgr ~mcp_clock:clk
             ~mcp_startup_policy:Par.Mcp_types.Log_and_continue
             sw with
      | Ok rt ->
        Alcotest.(check int) "only good server in table" 1
          (htbl_count (Par.Runtime.mcp_servers rt));
        ignore (Par.Runtime.close rt)
      | Error e -> Alcotest.failf "Log_and_continue should not error: %s"
          (string_of_error_category e)))

let test_create_fail_fast_aborts () =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clk = Eio.Stdenv.clock env in
    Eio.Switch.run (fun sw ->
      let bad = bad_config () in
      match Par.Runtime.create ~config:test_config
             ~mcp_servers:[bad]
             ~mcp_process_mgr:mgr ~mcp_clock:clk
             ~mcp_startup_policy:Par.Mcp_types.Fail_fast
             sw with
      | Ok _ -> Alcotest.fail "expected Fail_fast to return Error"
      | Error ec ->
        match ec with
        | Par.Types.Invalid_input _ | Par.Types.External_failure _ | Par.Types.Internal _ -> ()
        | _ -> Alcotest.failf "expected spawn-related error, got %s"
            (string_of_error_category ec)))

let test_close_publishes_stopped_event () =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clk = Eio.Stdenv.clock env in
    reset_capture ();
    Eio.Switch.run (fun sw ->
      let cfg = mock_config () in
      match Par.Runtime.create ~config:test_config
             ~event_bus:capture_bus
             ~mcp_servers:[cfg] ~mcp_process_mgr:mgr ~mcp_clock:clk sw with
      | Ok rt ->
        reset_capture ();
        let _ = Par.Runtime.close rt in
        let stopped = count_stopped () in
        Alcotest.(check bool) "at least one stopped event" true (stopped >= 1)
      | Error e -> Alcotest.failf "create: %s" (string_of_error_category e)))

let test_close_with_no_mcp_servers_is_noop () =
  Eio_main.run (fun _env ->
    reset_capture ();
    Eio.Switch.run (fun sw ->
      match Par.Runtime.create ~config:test_config
             ~event_bus:capture_bus sw with
      | Ok rt ->
        reset_capture ();
        let _ = Par.Runtime.close rt in
        let mcp_events = List.filter is_mcp_event !captured_events in
        Alcotest.(check int) "no MCP events" 0 (List.length mcp_events)
      | Error e -> Alcotest.failf "create: %s" (string_of_error_category e)))

let test_mcp_server_accessor_found () =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clk = Eio.Stdenv.clock env in
    Eio.Switch.run (fun sw ->
      let cfg = mock_config () in
      match Par.Runtime.create ~config:test_config
             ~mcp_servers:[cfg] ~mcp_process_mgr:mgr ~mcp_clock:clk sw with
      | Ok rt ->
        let tbl = Par.Runtime.mcp_servers rt in
        let ids = htbl_keys tbl in
        Alcotest.(check int) "one id" 1 (List.length ids);
        let first_id = List.hd ids in
        (match Par.Runtime.mcp_server rt first_id with
         | Ok _ -> ()
         | Error e -> Alcotest.failf "mcp_server accessor: %s" (string_of_error_category e));
        ignore (Par.Runtime.close rt)
      | Error e -> Alcotest.failf "create: %s" (string_of_error_category e)))

let test_mcp_server_accessor_not_found () =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clk = Eio.Stdenv.clock env in
    Eio.Switch.run (fun sw ->
      let cfg = mock_config () in
      match Par.Runtime.create ~config:test_config
             ~mcp_servers:[cfg] ~mcp_process_mgr:mgr ~mcp_clock:clk sw with
      | Ok rt ->
        (match Par.Mcp_types.server_id_of_string "does-not-exist" with
         | Error _ -> Alcotest.fail "could not construct sentinel id"
         | Ok sentinel ->
           (match Par.Runtime.mcp_server rt sentinel with
            | Ok _ -> Alcotest.fail "expected Error for unknown id"
            | Error ec ->
              match ec with
              | Par.Types.Invalid_input _ -> ()
              | _ -> Alcotest.failf "expected Invalid_input, got %s"
                  (string_of_error_category ec)));
        ignore (Par.Runtime.close rt)
      | Error e -> Alcotest.failf "create: %s" (string_of_error_category e)))

let () =
  let open Alcotest in
  run "Mcp_runtime" [
    "create", [
      test_case "vanilla create with no MCP fields" `Quick test_create_no_mcp_servers;
      test_case "create with one mock server spawns" `Quick test_create_with_mcp_servers_spawns;
      test_case "create without mcp_process_mgr returns Error" `Quick test_create_without_process_mgr_returns_error;
      test_case "create without mcp_clock returns Error" `Quick test_create_without_clock_returns_error;
      test_case "Log_and_continue skips bad cfg" `Quick test_create_log_and_continue_skips_bad;
      test_case "Fail_fast aborts on bad cfg" `Quick test_create_fail_fast_aborts;
    ];
    "close", [
      test_case "close publishes Mcp_server_stopped" `Quick test_close_publishes_stopped_event;
      test_case "close with no MCP servers is no-op" `Quick test_close_with_no_mcp_servers_is_noop;
    ];
    "accessors", [
      test_case "mcp_server found by id" `Quick test_mcp_server_accessor_found;
      test_case "mcp_server not found returns Error" `Quick test_mcp_server_accessor_not_found;
    ];
  ]
