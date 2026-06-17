(* test/test_mcp_client.ml — v0.3.1 W2 Mcp_client high-level API tests.
   Spawns the mcp_mock_server.exe process and exercises the Mcp_client API
   end-to-end. Each test calls [Eio_main.run] once at the entry point. *)

open Par
module C = Par__Mcp_client
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
  T.Stdio_server {
    name;
    command = (match command with
               | Some c -> c
               | None -> mock_path);
    args;
    env;
    cwd = None;
    startup_timeout;
  }

let with_client ~sw ~mgr ~clock ?args config_fn =
  let config = base_config ?args () in
  match C.connect ~sw ~process_mgr:mgr ~clock config with
  | Ok c ->
    let result = config_fn c in
    ignore (C.disconnect c);
    result
  | Error e -> Alcotest.failf "connect failed: %s" (string_of_error_category e)

let test_connect_returns_ready () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.status c with
      | S.Ready _ -> ()
      | other -> Alcotest.failf "expected Ready, got %s"
          (match other with
           | S.Starting -> "Starting"
           | S.Failed ec -> "Failed(" ^ string_of_error_category ec ^ ")"
           | S.Stopped -> "Stopped"
           | S.Ready _ -> assert false))

let test_connect_timeout () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config ~args:["--no-initialize-response"] ~startup_timeout:2.0 () in
    (match C.connect ~sw ~process_mgr:mgr ~clock config with
     | Ok c ->
       ignore (C.disconnect c);
       Alcotest.failf "expected connect failure"
     | Error _ -> ())

let test_list_tools_returns_4 () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.list_tools c with
      | Ok tools -> Alcotest.(check int) "4 tools" 4 (List.length tools)
      | Error e -> Alcotest.failf "list_tools: %s" (string_of_error_category e))

let test_list_tools_names () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.list_tools c with
      | Ok tl ->
        let names = List.map (fun (t : T.mcp_tool) -> t.name) tl |> List.sort String.compare in
        Alcotest.(check (list string)) "tool names"
          ["add"; "crash"; "echo"; "slow"] names
      | Error e -> Alcotest.failf "list_tools: %s" (string_of_error_category e))

let test_call_tool_echo () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      let args = `Assoc ["message", `String "hello"] in
      match C.call_tool c ~name:"echo" ~arguments:args with
      | Ok result ->
        (match result with
         | `Assoc fields ->
           (match List.assoc_opt "isError" fields with
            | Some (`Bool false) -> ()
            | _ -> Alcotest.failf "expected isError=false")
         | _ -> Alcotest.failf "echo result not an object")
      | Error e -> Alcotest.failf "call_tool echo: %s" (string_of_error_category e))

let test_call_tool_add () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      let args = `Assoc ["a", `Int 7; "b", `Int 3] in
      match C.call_tool c ~name:"add" ~arguments:args with
      | Ok result ->
        let str = Yojson.Safe.to_string result in
        if not (Base.String.is_substring str ~substring:"10") then
          Alcotest.failf "expected '10' in add result, got %s" str
      | Error e -> Alcotest.failf "call_tool add: %s" (string_of_error_category e))

let test_call_tool_unknown_returns_error () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      let args = `Assoc [] in
      match C.call_tool c ~name:"nonexistent" ~arguments:args with
      | Ok _ -> Alcotest.failf "expected error for unknown tool"
      | Error _ -> ())

let test_list_resources_returns_2 () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.list_resources c with
      | Ok resources -> Alcotest.(check int) "2 resources" 2 (List.length resources)
      | Error e -> Alcotest.failf "list_resources: %s" (string_of_error_category e))

let test_read_resource_hello () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.read_resource c ~uri:"mock://hello" with
      | Ok result ->
        let str = Yojson.Safe.to_string result in
        if not (Base.String.is_substring str ~substring:"Hello, MCP!") then
          Alcotest.failf "expected 'Hello, MCP!' in resource, got %s" str
      | Error e -> Alcotest.failf "read_resource: %s" (string_of_error_category e))

let test_read_resource_data_base64 () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.read_resource c ~uri:"mock://data" with
      | Ok result ->
        let str = Yojson.Safe.to_string result in
        if not (Base.String.is_substring str ~substring:"AAEC") then
          Alcotest.failf "expected base64 blob in resource, got %s" str
      | Error e -> Alcotest.failf "read_resource data: %s" (string_of_error_category e))

let test_read_resource_unknown_returns_error () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.read_resource c ~uri:"mock://nonexistent" with
      | Ok _ -> Alcotest.failf "expected error for unknown resource"
      | Error _ -> ())

let test_list_prompts_returns_1 () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.list_prompts c with
      | Ok prompts -> Alcotest.(check int) "1 prompt" 1 (List.length prompts)
      | Error e -> Alcotest.failf "list_prompts: %s" (string_of_error_category e))

let test_get_prompt_greeting () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.get_prompt c ~name:"greeting" ~arguments:["name", "World"] () with
      | Ok result ->
        let str = Yojson.Safe.to_string result in
        if not (Base.String.is_substring str ~substring:"Hello, World!") then
          Alcotest.failf "expected 'Hello, World!' in prompt, got %s" str
      | Error e -> Alcotest.failf "get_prompt: %s" (string_of_error_category e))

let test_get_prompt_default_args () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.get_prompt c ~name:"greeting" () with
      | Ok result ->
        let str = Yojson.Safe.to_string result in
        if not (Base.String.is_substring str ~substring:"Hello") then
          Alcotest.failf "expected greeting in prompt, got %s" str
      | Error e -> Alcotest.failf "get_prompt: %s" (string_of_error_category e))

let test_ping () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      match C.ping c with
      | Ok _ -> ()
      | Error e -> Alcotest.failf "ping: %s" (string_of_error_category e))

let test_of_server_wraps () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    (match S.spawn ~sw ~process_mgr:mgr ~clock config with
     | Ok s ->
       let c = C.of_server s in
       Alcotest.(check string) "name" "mock" (C.name c);
       Alcotest.(check bool) "pid > 0" true (S.pid (C.server c) > 0);
       ignore (C.disconnect c)
     | Error e -> Alcotest.failf "spawn: %s" (string_of_error_category e))

let test_accessors () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    with_client ~sw ~mgr ~clock (fun c ->
      Alcotest.(check string) "name" "mock" (C.name c);
      let caps = C.capabilities c in
      Alcotest.(check bool) "tools" true caps.T.tools;
      Alcotest.(check bool) "resources" true caps.T.resources;
      Alcotest.(check bool) "prompts" true caps.T.prompts;
      let pid = S.pid (C.server c) in
      Alcotest.(check bool) "pid > 0" true (pid > 0))

let test_disconnect_idempotent () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config () in
    (match C.connect ~sw ~process_mgr:mgr ~clock config with
     | Ok c ->
       let error_category_pp fmt ec =
         Format.pp_print_string fmt (string_of_error_category ec) in
       let error_category_testable = Alcotest.testable error_category_pp (=) in
       Alcotest.(check (result unit error_category_testable))
         "first disconnect" (Ok ()) (C.disconnect c);
       Alcotest.(check (result unit error_category_testable))
         "second disconnect" (Ok ()) (C.disconnect c)
     | Error e -> Alcotest.failf "connect: %s" (string_of_error_category e))

let test_connect_failure_bad_command () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
    let config = base_config ~command:"/nonexistent/binary_xyz" () in
    (match C.connect ~sw ~process_mgr:mgr ~clock config with
     | Ok c -> Alcotest.failf "expected connect failure" (C.name c)
     | Error _ -> ())

let () =
  let open Alcotest in
  run "Mcp_client" [
    "connect", [
      test_case "connect returns Ready" `Quick test_connect_returns_ready;
      test_case "connect timeout" `Quick test_connect_timeout;
      test_case "connect failure bad command" `Quick test_connect_failure_bad_command;
    ];
    "tools", [
      test_case "list_tools returns 4" `Quick test_list_tools_returns_4;
      test_case "list_tools names" `Quick test_list_tools_names;
      test_case "call_tool echo" `Quick test_call_tool_echo;
      test_case "call_tool add" `Quick test_call_tool_add;
      test_case "call_tool unknown returns error" `Quick test_call_tool_unknown_returns_error;
    ];
    "resources", [
      test_case "list_resources returns 2" `Quick test_list_resources_returns_2;
      test_case "read_resource hello" `Quick test_read_resource_hello;
      test_case "read_resource data base64" `Quick test_read_resource_data_base64;
      test_case "read_resource unknown error" `Quick test_read_resource_unknown_returns_error;
    ];
    "prompts", [
      test_case "list_prompts returns 1" `Quick test_list_prompts_returns_1;
      test_case "get_prompt greeting" `Quick test_get_prompt_greeting;
      test_case "get_prompt default args" `Quick test_get_prompt_default_args;
    ];
    "utility", [
      test_case "ping" `Quick test_ping;
      test_case "of_server wraps" `Quick test_of_server_wraps;
    ];
    "accessors", [
      test_case "name, capabilities, pid" `Quick test_accessors;
      test_case "disconnect idempotent" `Quick test_disconnect_idempotent;
    ];
  ]
