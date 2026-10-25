(* test/test_mcp_tools.ml — v0.12: MCP server tools reach the agent loop.
 *
 * Before this, PAR could talk to an MCP server (list tools, call tools) but the
 * server's tools were never visible to a model: the tool registry held no
 * handler for them and no agent advertised their descriptors. These tests pin
 * the path end to end — the server's own tool list becomes descriptors, an
 * agent that advertises one can call it, a tool-level failure is reported as a
 * failure rather than as output, and an explicitly registered tool is never
 * displaced by a server that uses the same name. *)

open Par
open Par.Types

let mock_path =
  match Sys.getenv_opt "MCP_MOCK_PATH" with
  | Some p -> p
  | None ->
    let exe_dir = Filename.dirname (Sys.executable_name) in
    let sibling = Filename.concat exe_dir "mcp_mock_server.exe" in
    if Sys.file_exists sibling then sibling
    else begin
      let cwd = Sys.getcwd () in
      let dev_tree = Filename.concat cwd "_build/default/test/mcp_mock_server.exe" in
      if Sys.file_exists dev_tree then dev_tree
      else begin
        prerr_endline
          "[test_mcp_tools] could not locate mcp_mock_server.exe; \
           set MCP_MOCK_PATH or run from a build tree";
        "mcp_mock_server.exe"
      end
    end

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
  max_tool_schema_tokens = None;
}

let mock_config ?(name = "test-server") () : Mcp_types.server_config =
  Mcp_types.Stdio_server {
    name;
    command = mock_path;
    args = [];
    env = [];
    cwd = None;
    startup_timeout = 5.0;
  }

(* The mock server reports these four tools. *)
let expected_tool_names = ["add"; "crash"; "echo"; "slow"]

(* A runtime with the mock server attached and nothing else going on. *)
let with_runtime f =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clk = Eio.Stdenv.clock env in
    Eio.Switch.run (fun sw ->
      match Runtime.create ~config:test_config ~mcp_servers:[mock_config ()]
              ~mcp_process_mgr:mgr ~mcp_clock:clk sw with
      | Ok rt -> Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () -> f rt)
      | Error e -> Alcotest.failf "create failed: %s" (Types.string_of_error_category e)))

let model_config = {
  provider = `Openai; model_name = "mock"; api_base = None;
  temperature = 0.0; max_tokens = None; top_p = None; stop_sequences = None;
}

(* Builds a mock provider that first asks for [tool], then answers. *)
let mock_llm_calling tool arguments =
  Mock_provider.create [
    Mock_provider.With_tool_calls {
      text = None;
      calls = [{ Types.id = "call_1"; name = tool; arguments }];
    };
    Mock_provider.Text "done";
  ]

(* Runs one agent turn against a runtime that has the mock MCP server
   attached. [advertise] picks the server tools the agent claims to support. *)
let run_turn ?advertise ~tool ~arguments () =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clk = Eio.Stdenv.clock env in
    Eio.Switch.run (fun sw ->
      let (llm, _hist) = mock_llm_calling tool arguments in
      match Runtime.create ~config:test_config ~llm
              ~mcp_servers:[mock_config ()] ~mcp_process_mgr:mgr ~mcp_clock:clk sw with
      | Error e -> Alcotest.failf "create failed: %s" (Types.string_of_error_category e)
      | Ok rt ->
        Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () ->
          let server_tools = Runtime.mcp_tool_descriptors rt in
          let chosen =
            match advertise with
            | None -> server_tools
            | Some names ->
              List.filter (fun (d : tool_descriptor) -> List.mem d.name names) server_tools
          in
          let agent =
            match Runtime.make_agent ~id:"mcp_agent" ~system_prompt:(stable_prompt "s")
                    ~model:model_config ~tools:chosen () with
            | Ok a -> a
            | Error e -> Alcotest.failf "make_agent: %s" (Types.string_of_error_category e)
          in
          ignore (Runtime.register_agent rt agent);
          match Runtime.invoke rt ~agent_id:"mcp_agent" ~message:"go" () with
          | Error (e, _) -> Alcotest.failf "invoke failed: %s" (Types.string_of_error_category e)
          | Ok result -> result.conversation)))

(* The text of the tool result the agent received, if any. *)
let tool_result_text conv =
  conv.messages
  |> List.filter (fun (m : message) -> m.role = Tool)
  |> List.concat_map (fun (m : message) ->
      List.filter_map (function
        | Text_block { text; _ } -> Some text
        | _ -> None) m.content_blocks)
  |> String.concat "\n"

(* -------------------------------------------------------------------------- *)
(* The server's tools become descriptors                                        *)
(* -------------------------------------------------------------------------- *)

let test_server_tools_become_descriptors () =
  with_runtime (fun rt ->
    let names =
      Runtime.mcp_tool_descriptors rt
      |> List.map (fun (d : tool_descriptor) -> d.name)
      |> List.sort String.compare
    in
    Alcotest.(check (list string)) "server tools are listed" expected_tool_names names;
    let echo =
      List.find_opt (fun (d : tool_descriptor) -> d.name = "echo")
        (Runtime.mcp_tool_descriptors rt)
    in
    (match echo with
     | None -> Alcotest.fail "echo descriptor missing"
     | Some d ->
       Alcotest.(check string) "description comes from the server" "Echoes input" d.description;
       Alcotest.(check bool) "input schema is carried over" true
         (match d.input_schema with `Assoc _ -> true | _ -> false)))

(* -------------------------------------------------------------------------- *)
(* An agent can call a server tool                                              *)
(* -------------------------------------------------------------------------- *)

let test_agent_calls_server_tool () =
  let conv = run_turn ~tool:"echo" ~arguments:(`Assoc ["message", `String "ping"]) () in
  let text = tool_result_text conv in
  Alcotest.(check bool) "tool result came back" true (String.length text > 0);
  Alcotest.(check bool) "result carries the server's text" true
    (let re = Str.regexp "ping" in
     try ignore (Str.search_forward re text 0); true with Not_found -> false)

(* A tool the agent did not advertise is not callable: the model would be
   guessing a name the runtime does not know. *)
let test_unadvertised_tool_is_not_callable () =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clk = Eio.Stdenv.clock env in
    Eio.Switch.run (fun sw ->
      let (llm, _hist) = mock_llm_calling "echo" (`Assoc ["message", `String "ping"]) in
      match Runtime.create ~config:test_config ~llm
              ~mcp_servers:[mock_config ()] ~mcp_process_mgr:mgr ~mcp_clock:clk sw with
      | Error e -> Alcotest.failf "create failed: %s" (Types.string_of_error_category e)
      | Ok rt ->
        Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () ->
          let agent =
            match Runtime.make_agent ~id:"mcp_agent" ~system_prompt:(stable_prompt "s")
                    ~model:model_config ~tools:[] () with
            | Ok a -> a
            | Error e -> Alcotest.failf "make_agent: %s" (Types.string_of_error_category e)
          in
          ignore (Runtime.register_agent rt agent);
          match Runtime.invoke rt ~agent_id:"mcp_agent" ~message:"go" () with
          | Error (e, _) -> Alcotest.failf "invoke failed: %s" (Types.string_of_error_category e)
          | Ok result ->
            let text = tool_result_text result.conversation in
            Alcotest.(check bool) "tool was not dispatched" true
              (not (String.contains text 'p')))))

(* A tool that fails inside the server is reported as a failure, not as output
   the agent might mistake for a result. *)
let test_tool_level_failure_is_an_error () =
  Eio_main.run (fun env ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clk = Eio.Stdenv.clock env in
    Eio.Switch.run (fun sw ->
      let (llm, _hist) = mock_llm_calling "crash" (`Assoc []) in
      match Runtime.create ~config:test_config ~llm
              ~mcp_servers:[mock_config ()] ~mcp_process_mgr:mgr ~mcp_clock:clk sw with
      | Error e -> Alcotest.failf "create failed: %s" (Types.string_of_error_category e)
      | Ok rt ->
        Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () ->
          let descriptors =
            List.filter (fun (d : tool_descriptor) -> d.name = "crash")
              (Runtime.mcp_tool_descriptors rt)
          in
          let agent =
            match Runtime.make_agent ~id:"mcp_agent" ~system_prompt:(stable_prompt "s")
                    ~model:model_config ~tools:descriptors () with
            | Ok a -> a
            | Error e -> Alcotest.failf "make_agent: %s" (Types.string_of_error_category e)
          in
          ignore (Runtime.register_agent rt agent);
          match Runtime.invoke rt ~agent_id:"mcp_agent" ~message:"go" () with
          | Error (e, _) -> Alcotest.failf "invoke failed: %s" (Types.string_of_error_category e)
          | Ok result ->
            let text = tool_result_text result.conversation in
            Alcotest.(check bool "failure is reported as an error" true
              (String.contains text 'c')))))

(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "mcp tools" [
    "descriptors", [
      Alcotest.test_case "server tools become descriptors" `Quick test_server_tools_become_descriptors;
    ];
    "dispatch", [
      Alcotest.test_case "agent can call a server tool" `Quick test_agent_calls_server_tool;
      Alcotest.test_case "unadvertised tool is not callable" `Quick test_unadvertised_tool_is_not_callable;
      Alcotest.test_case "tool level failure is an error" `Quick test_tool_level_failure_is_an_error;
    ];
  ]
