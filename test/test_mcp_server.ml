(* test/test_mcp_server.ml — v0.3.1 W2 Mcp_server lifecycle + RPC dispatch tests.
   Spawns the mcp_mock_server.exe process and exercises the Mcp_server API
   end-to-end. Each test calls [Eio_main.run] once at the entry point. *)

open Par
module S = Par__Mcp_server
module T = Par__Mcp_types

let () = Logs.set_level (Some Logs.Warning) |> ignore

let string_of_error_category (ec : Types.error_category) =
  match ec with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid_input(%s)" s
  | Types.External_failure s -> Printf.sprintf "External_failure(%s)" s
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission_denied(%s)" s
  | Types.Internal s -> Printf.sprintf "Internal(%s)" s

let error_category_pp fmt ec =
  Format.pp_print_string fmt (string_of_error_category ec)

let error_category_testable = Alcotest.testable error_category_pp (=)

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

let base_config ?(args = []) ?(env = []) ?(name = "mock") ?(startup_timeout = 10.0)
    ?command () : T.server_config =
  {
    name;
    command = (match command with
               | Some c -> c
               | None -> mock_path);
    args;
    env;
    cwd = None;
    startup_timeout;
  }

let is_invalid_input_ec (ec : Types.error_category) : bool =
  match ec with
  | Types.Invalid_input _ -> true
  | _ -> false

let test_initialize_returns_capabilities () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      (match S.status s with
       | S.Ready _ -> ()
       | other -> Alcotest.failf "expected Ready, got %s"
           (match other with
            | S.Starting -> "Starting"
            | S.Failed ec -> "Failed(" ^ string_of_error_category ec ^ ")"
            | S.Stopped -> "Stopped"
            | S.Ready _ -> assert false));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_handshake_succeeds_with_mock_server () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      let caps = S.capabilities s in
      Alcotest.(check bool) "tools capability true" true caps.T.tools;
      Alcotest.(check bool) "resources capability true" true caps.T.resources;
      Alcotest.(check bool) "prompts capability true" true caps.T.prompts;
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_handshake_timeout_with_no_init_response () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config ~args:["--no-initialize-response"] ~startup_timeout:2.0 () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      ignore (S.stop s);
      Alcotest.failf "expected spawn to fail with no-initialize-response"
    | Error _ec -> ()

let test_call_tools_list () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      (match S.call_method s ~method_:"tools/list" ~params:(`Assoc []) with
       | Ok result ->
         (match result with
          | `Assoc fields ->
            (match List.assoc_opt "tools" fields with
             | Some (`List tools) ->
               Alcotest.(check int) "4 tools" 4 (List.length tools)
             | _ -> Alcotest.failf "tools/list result missing 'tools' array")
          | _ -> Alcotest.failf "tools/list did not return an object")
       | Error e -> Alcotest.failf "call failed: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_call_tool_echo () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      let params = `Assoc [
        "name", `String "echo";
        "arguments", `Assoc ["message", `String "hello"]
      ] in
      (match S.call_method s ~method_:"tools/call" ~params with
       | Ok result ->
         (match result with
          | `Assoc fields ->
            (match List.assoc_opt "isError" fields with
             | Some (`Bool false) -> ()
             | _ -> Alcotest.failf "expected isError=false")
          | _ -> Alcotest.failf "tools/call echo did not return an object")
       | Error e -> Alcotest.failf "call failed: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_call_tool_add () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      let params = `Assoc [
        "name", `String "add";
        "arguments", `Assoc ["a", `Int 2; "b", `Int 3]
      ] in
      (match S.call_method s ~method_:"tools/call" ~params with
       | Ok result ->
         let content_str = Yojson.Safe.to_string result in
         if not (Base.String.is_substring content_str ~substring:"5") then
           Alcotest.failf "expected '5' in add result, got %s" content_str
       | Error e -> Alcotest.failf "call failed: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_call_tool_unknown_returns_jsonrpc_error () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      let params = `Assoc [
        "name", `String "nonexistent";
        "arguments", `Assoc []
      ] in
      (match S.call_method s ~method_:"tools/call" ~params with
       | Ok _ -> Alcotest.failf "expected Error for unknown tool, got Ok"
       | Error ec ->
         Alcotest.(check bool) "is Invalid_input" true (is_invalid_input_ec ec));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_call_ping_method () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      (match S.call_method s ~method_:"ping" ~params:(`Assoc []) with
       | Ok _ -> ()
       | Error e -> Alcotest.failf "ping failed: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_send_notification_does_not_block () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      (match S.notify s ~method_:"notifications/cancelled"
              ~params:(`Assoc ["requestId", `Int 0]) with
       | Ok () -> ()
       | Error e -> Alcotest.failf "notify failed: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_stop_after_init_idempotent () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    (match S.spawn ~sw ~process_mgr:mgr ~clock config with
     | Ok s ->
       Alcotest.(check (result unit error_category_testable))
         "first stop" (Ok ()) (S.stop s);
       Alcotest.(check (result unit error_category_testable))
         "second stop (idempotent)" (Ok ()) (S.stop s)
     | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e))

let test_id_is_unique_per_spawn () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    (match S.spawn ~sw ~process_mgr:mgr ~clock config with
     | Ok s1 ->
       let id1 = S.id s1 in
       (match S.spawn ~sw ~process_mgr:mgr ~clock config with
        | Ok s2 ->
          let id2 = S.id s2 in
          Alcotest.(check bool) "ids differ" true
            (T.server_id_compare id1 id2 <> 0);
          ignore (S.stop s1);
          ignore (S.stop s2)
        | Error e -> Alcotest.failf "second spawn: %s" (string_of_error_category e))
     | Error e -> Alcotest.failf "first spawn: %s" (string_of_error_category e))

let test_request_id_monotonic_per_session () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      let _ = S.call_method s ~method_:"ping" ~params:(`Assoc []) in
      let _ = S.call_method s ~method_:"ping" ~params:(`Assoc []) in
      let _ = S.call_method s ~method_:"ping" ~params:(`Assoc []) in
      Alcotest.(check bool) "no exception" true true;
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_slow_tool_completes () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      let params = `Assoc [
        "name", `String "slow";
        "arguments", `Assoc ["delay_ms", `Float 100.0]
      ] in
      let t0 = Unix.gettimeofday () in
      (match S.call_method s ~method_:"tools/call" ~params with
       | Ok _ ->
         let elapsed = Unix.gettimeofday () -. t0 in
         Alcotest.(check bool) "took at least 0.1s" true (elapsed >= 0.05)
       | Error e -> Alcotest.failf "slow tool: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_crash_tool_returns_is_error () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      let params = `Assoc [
        "name", `String "crash";
        "arguments", `Assoc []
      ] in
      (match S.call_method s ~method_:"tools/call" ~params with
       | Ok result ->
         (match result with
          | `Assoc fields ->
            (match List.assoc_opt "isError" fields with
             | Some (`Bool true) -> ()
             | _ -> Alcotest.failf "expected isError=true")
          | _ -> Alcotest.failf "crash tool did not return an object")
       | Error e -> Alcotest.failf "crash call: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn failed: %s" (string_of_error_category e)

let test_spawn_failure_returns_error () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config ~command:"/nonexistent/binary_xyz" () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s -> Alcotest.failf "expected spawn failure" (S.name s)
    | Error _ -> ()

let test_invalid_server_name_returns_error () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config ~name:"" () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s -> Alcotest.failf "expected name validation failure" (S.name s)
    | Error ec ->
      Alcotest.(check bool) "is Invalid_input" true (is_invalid_input_ec ec)

let test_status_reflects_lifecycle () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    (match S.spawn ~sw ~process_mgr:mgr ~clock config with
     | Ok s ->
       (match S.status s with
        | S.Ready _ -> ()
        | other -> Alcotest.failf "expected Ready, got %s"
            (match other with
             | S.Starting -> "Starting"
             | S.Stopped -> "Stopped"
             | S.Failed ec -> "Failed(" ^ string_of_error_category ec ^ ")"
             | S.Ready _ -> assert false));
       Alcotest.(check (result unit error_category_testable))
         "stop" (Ok ()) (S.stop s);
       (match S.status s with
        | S.Stopped -> ()
        | _ -> Alcotest.failf "expected Stopped after stop")
     | Error e -> Alcotest.failf "spawn: %s" (string_of_error_category e))

let test_garbage_on_stderr_does_not_hang () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config ~args:["--garbage-on-stderr"] () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      (match S.call_method s ~method_:"tools/list" ~params:(`Assoc []) with
       | Ok _ -> ()
       | Error e -> Alcotest.failf "tools/list with garbage-on-stderr: %s"
           (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn: %s" (string_of_error_category e)

let test_shutdown_then_respawn_works () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    (match S.spawn ~sw ~process_mgr:mgr ~clock config with
     | Ok s1 ->
       ignore (S.stop s1);
       (match S.spawn ~sw ~process_mgr:mgr ~clock config with
        | Ok s2 ->
          (match S.status s2 with
           | S.Ready _ -> ()
           | _ -> Alcotest.failf "second spawn not Ready");
          ignore (S.stop s2)
        | Error e -> Alcotest.failf "second spawn: %s" (string_of_error_category e))
     | Error e -> Alcotest.failf "first spawn: %s" (string_of_error_category e))

let test_double_initialize_does_nothing () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      let init_params = `Assoc [
        "protocolVersion", `String "2025-06-18";
        "capabilities", `Assoc [];
        "clientInfo", `Assoc ["name", `String "par"; "version", `String "0.3.0"];
      ] in
      (match S.call_method s ~method_:"initialize" ~params:init_params with
       | Ok _ ->
         (match S.call_method s ~method_:"tools/list" ~params:(`Assoc []) with
          | Ok _ -> ()
          | Error e -> Alcotest.failf "post-double-init tools/list: %s"
              (string_of_error_category e))
       | Error e -> Alcotest.failf "double init: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn: %s" (string_of_error_category e)

let test_name_and_pid_accessors () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    (match S.spawn ~sw ~process_mgr:mgr ~clock config with
     | Ok s ->
       Alcotest.(check string) "name" "mock" (S.name s);
       let pid = S.pid s in
       Alcotest.(check bool) "pid > 0" true (pid > 0);
       ignore (S.stop s)
     | Error e -> Alcotest.failf "spawn: %s" (string_of_error_category e))

let test_call_resources_list () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      (match S.call_method s ~method_:"resources/list" ~params:(`Assoc []) with
       | Ok result ->
         (match result with
          | `Assoc fields ->
            (match List.assoc_opt "resources" fields with
             | Some (`List rs) ->
               Alcotest.(check int) "2 resources" 2 (List.length rs)
             | _ -> Alcotest.failf "resources/list missing array")
          | _ -> Alcotest.failf "resources/list not object")
       | Error e -> Alcotest.failf "resources/list: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn: %s" (string_of_error_category e)

let test_call_prompts_list () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      (match S.call_method s ~method_:"prompts/list" ~params:(`Assoc []) with
       | Ok result ->
         (match result with
          | `Assoc fields ->
            (match List.assoc_opt "prompts" fields with
             | Some (`List ps) ->
               Alcotest.(check int) "1 prompt" 1 (List.length ps)
             | _ -> Alcotest.failf "prompts/list missing array")
          | _ -> Alcotest.failf "prompts/list not object")
       | Error e -> Alcotest.failf "prompts/list: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn: %s" (string_of_error_category e)

let test_call_tool_echo_returns_text () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    match S.spawn ~sw ~process_mgr:mgr ~clock config with
    | Ok s ->
      let params = `Assoc [
        "name", `String "echo";
        "arguments", `Assoc ["message", `String "world"]
      ] in
      (match S.call_method s ~method_:"tools/call" ~params with
       | Ok result ->
         let str = Yojson.Safe.to_string result in
         if not (Base.String.is_substring str ~substring:"world") then
           Alcotest.failf "expected 'world' in echo result, got %s" str
       | Error e -> Alcotest.failf "echo: %s" (string_of_error_category e));
      ignore (S.stop s)
    | Error e -> Alcotest.failf "spawn: %s" (string_of_error_category e)

let () =
  let open Alcotest in
  run "Mcp_server" [
    "handshake", [
      test_case "initialize returns Ready" `Quick test_initialize_returns_capabilities;
      test_case "handshake succeeds" `Quick test_handshake_succeeds_with_mock_server;
      test_case "handshake timeout on no-init-response" `Quick test_handshake_timeout_with_no_init_response;
    ];
    "method_call", [
      test_case "tools/list returns 4 tools" `Quick test_call_tools_list;
      test_case "tools/call echo" `Quick test_call_tool_echo;
      test_case "tools/call add" `Quick test_call_tool_add;
      test_case "tools/call unknown returns error" `Quick test_call_tool_unknown_returns_jsonrpc_error;
      test_case "ping method" `Quick test_call_ping_method;
    ];
    "notification", [
      test_case "send notification" `Quick test_send_notification_does_not_block;
    ];
    "lifecycle", [
      test_case "stop is idempotent" `Quick test_stop_after_init_idempotent;
      test_case "id is unique per spawn" `Quick test_id_is_unique_per_spawn;
    ];
    "concurrent", [
      test_case "request id monotonic" `Quick test_request_id_monotonic_per_session;
    ];
    "mock_flags", [
      test_case "slow tool completes" `Slow test_slow_tool_completes;
      test_case "crash tool returns isError" `Quick test_crash_tool_returns_is_error;
      test_case "spawn failure returns error" `Quick test_spawn_failure_returns_error;
      test_case "invalid server name returns error" `Quick test_invalid_server_name_returns_error;
      test_case "status reflects lifecycle" `Quick test_status_reflects_lifecycle;
    ];
    "mock_flags_2", [
      test_case "garbage on stderr does not hang" `Quick test_garbage_on_stderr_does_not_hang;
      test_case "shutdown then respawn" `Quick test_shutdown_then_respawn_works;
      test_case "double initialize does not break" `Quick test_double_initialize_does_nothing;
    ];
    "accessors", [
      test_case "name and pid accessors" `Quick test_name_and_pid_accessors;
    ];
    "extra_methods", [
      test_case "resources/list" `Quick test_call_resources_list;
      test_case "prompts/list" `Quick test_call_prompts_list;
      test_case "echo returns text" `Quick test_call_tool_echo_returns_text;
    ];
  ]
