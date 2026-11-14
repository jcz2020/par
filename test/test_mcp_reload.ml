(* Runtime.reload_mcp_servers tests — GitHub #35.
   The runtime used to spawn MCP servers only in Runtime.create; the tool
   list was private and could not be rebuilt. These cases exercise spawning,
   keeping, changing and removing servers after startup, the transactional
   spawn path, and that a reloaded tool is actually callable. *)

open Par
open Types

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"
  | Cancelled _ -> "cancelled"

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None; context_window = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; reasoning = []; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let tool_call_response call : llm_response =
  { text = None; reasoning = []; tool_calls = Some [call];
    finish_reason = Tool_calls; usage = dummy_usage; model = "mock" }

let mock_llm responses =
  let counter = ref 0 in
  let next () =
    let idx = !counter in
    incr counter;
    match List.nth_opt responses idx with
    | Some resp -> resp
    | None -> text_response "default"
  in
  { complete_fn = (fun _model _tools _conv -> Ok (next ()));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None }

let test_config : runtime_config =
  { persistence = `Sqlite ":memory:";
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = true;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = 604800.0;
    max_tool_schema_tokens = None }

let mock_path =
  match Sys.getenv_opt "MCP_MOCK_PATH" with
  | Some p -> p
  | None ->
    let exe_dir = Filename.dirname Sys.executable_name in
    let sibling = Filename.concat exe_dir "mcp_mock_server.exe" in
    if Sys.file_exists sibling then sibling
    else
      let dev_tree =
        Filename.concat (Sys.getcwd ())
          "_build/default/test/mcp_mock_server.exe"
      in
      if Sys.file_exists dev_tree then dev_tree
      else "mcp_mock_server.exe"

let mock_config ?(name = "reload-server") ?(startup_timeout = 5.0) () :
    Mcp_types.server_config =
  Mcp_types.Stdio_server {
    name;
    command = mock_path;
    args = [];
    env = [];
    cwd = None;
    startup_timeout;
  }

let bad_config ?(name = "reload-server") () : Mcp_types.server_config =
  Mcp_types.Stdio_server {
    name;
    command = "/nonexistent/par_reload_binary_xyz";
    args = [];
    env = [];
    cwd = None;
    startup_timeout = 2.0;
  }

let htbl_count tbl =
  let n = ref 0 in
  Types.htbl_iter tbl (fun _ _ -> incr n);
  !n

let only_server_id tbl =
  let ids = ref [] in
  Types.htbl_iter tbl (fun id _ -> ids := id :: !ids);
  match !ids with
  | [id] -> id
  | _ -> Alcotest.failf "expected exactly one MCP server, got %d"
           (List.length !ids)

let contains haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let with_runtime ?(mcp_servers = []) ?(llm = mock_llm []) f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let mgr = Eio.Stdenv.process_mgr env in
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      match Par.Runtime.create ~config:test_config ~llm
              ~mcp_servers ~mcp_process_mgr:mgr ~mcp_net:net
              ~mcp_clock:clock sw with
      | Ok rt -> Fun.protect ~finally:(fun () -> ignore (Par.Runtime.close rt))
                   (fun () -> f rt)
      | Error e -> Alcotest.failf "create: %s" (error_to_string e)))

let reload rt servers =
  match Par.Runtime.reload_mcp_servers rt ~servers with
  | Ok descriptors -> descriptors
  | Error e -> Alcotest.failf "reload_mcp_servers: %s" (error_to_string e)

(* -------------------------------------------------------------------------- *)
(* Cases                                                                      *)
(* -------------------------------------------------------------------------- *)

let test_reload_empty_without_mcp_deps () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      match Par.Runtime.create ~config:test_config sw with
      | Error e -> Alcotest.failf "create: %s" (error_to_string e)
      | Ok rt ->
        (match Par.Runtime.reload_mcp_servers rt ~servers:[] with
         | Ok descriptors ->
           Alcotest.(check int) "no tools" 0 (List.length descriptors)
         | Error e -> Alcotest.failf "reload: %s" (error_to_string e));
        ignore (Par.Runtime.close rt)))

let test_reload_spawns_server () =
  with_runtime (fun rt ->
    let descriptors = reload rt [mock_config ()] in
    Alcotest.(check bool) "has echo" true
      (List.exists (fun (d : tool_descriptor) -> d.name = "echo") descriptors);
    Alcotest.(check int) "one live server" 1
      (htbl_count (Par.Runtime.mcp_servers rt));
    let listed = Par.Runtime.mcp_tool_descriptors rt in
    Alcotest.(check int) "descriptor count matches return"
      (List.length descriptors) (List.length listed))

let test_reload_unchanged_keeps_instance () =
  with_runtime (fun rt ->
    ignore (reload rt [mock_config ()]);
    let before = only_server_id (Par.Runtime.mcp_servers rt) in
    ignore (reload rt [mock_config ()]);
    let after = only_server_id (Par.Runtime.mcp_servers rt) in
    Alcotest.(check string) "same instance id"
      (Mcp_types.server_id_to_string before)
      (Mcp_types.server_id_to_string after))

let test_reload_changed_restarts_instance () =
  with_runtime (fun rt ->
    ignore (reload rt [mock_config ~startup_timeout:5.0 ()]);
    let before = only_server_id (Par.Runtime.mcp_servers rt) in
    ignore (reload rt [mock_config ~startup_timeout:6.0 ()]);
    let after = only_server_id (Par.Runtime.mcp_servers rt) in
    Alcotest.(check bool) "instance replaced" true
      (Mcp_types.server_id_to_string before
       <> Mcp_types.server_id_to_string after))

let test_reload_removes_server () =
  with_runtime (fun rt ->
    ignore (reload rt [mock_config ()]);
    let descriptors = reload rt [] in
    Alcotest.(check int) "no tools" 0 (List.length descriptors);
    Alcotest.(check int) "no live servers" 0
      (htbl_count (Par.Runtime.mcp_servers rt)))

let test_reload_rejects_duplicate_names () =
  with_runtime (fun rt ->
    (match Par.Runtime.reload_mcp_servers rt
             ~servers:[mock_config (); mock_config ()] with
     | Ok _ -> Alcotest.fail "expected duplicate-name rejection"
     | Error (Invalid_input msg) ->
       Alcotest.(check bool) "mentions duplicate" true
         (contains msg "duplicate")
     | Error e -> Alcotest.failf "unexpected error: %s" (error_to_string e));
    Alcotest.(check int) "nothing spawned" 0
      (htbl_count (Par.Runtime.mcp_servers rt)))

let test_reload_spawn_failure_keeps_old_set () =
  with_runtime (fun rt ->
    ignore (reload rt [mock_config ()]);
    let before = only_server_id (Par.Runtime.mcp_servers rt) in
    let before_tools = Par.Runtime.mcp_tool_descriptors rt in
    (match Par.Runtime.reload_mcp_servers rt ~servers:[bad_config ()] with
     | Ok _ -> Alcotest.fail "expected spawn failure"
     | Error _ -> ());
    let after = only_server_id (Par.Runtime.mcp_servers rt) in
    Alcotest.(check string) "old instance survived"
      (Mcp_types.server_id_to_string before)
      (Mcp_types.server_id_to_string after);
    Alcotest.(check int) "old tools survived"
      (List.length before_tools)
      (List.length (Par.Runtime.mcp_tool_descriptors rt)))

let test_reloaded_tool_is_callable () =
  let llm = mock_llm [
    tool_call_response
      { id = "tc-echo"; name = "echo";
        arguments = `Assoc [("message", `String "reload-echo-ok")] };
    text_response "done";
  ] in
  with_runtime ~llm (fun rt ->
    let descriptors = reload rt [mock_config ()] in
    let agent : agent_config =
      { id = "A"; system_prompt = stable_prompt "You are A";
        system_prompt_template = None;
        model = dummy_model; tools = descriptors; max_iterations = 5;
        middleware = []; retry_policy = None; context_strategy = None;
        resource_quota = None; max_execution_time = None; tool_timeout = None;
        early_stopping_method = Force; on_max_tokens = Some Return_partial;
        max_continuation_chunks = Some 3;
        context_compression_threshold = None;
        compression_cooldown_messages = None;
        context_window_override = None; cache_strategy = No_caching;
        approval_handler = None }
    in
    (match Par.Runtime.register_agent rt agent with
     | Ok () -> ()
     | Error e -> Alcotest.failf "register_agent: %s" (error_to_string e));
    match Par.Runtime.invoke rt ~agent_id:"A" ~message:"go" () with
    | Error (e, _) -> Alcotest.failf "invoke: %s" (error_to_string e)
    | Ok result ->
      let tool_text =
        result.conversation.messages
        |> List.filter_map (fun (m : message) ->
             if m.role = Tool then Some (Message.text_of_message m) else None)
        |> String.concat "\n"
      in
      Alcotest.(check bool) "echo tool ran through the reloaded handler" true
        (contains tool_text "reload-echo-ok"))

let () =
  Alcotest.run "mcp_reload" [
    ("mcp_reload", [
      Alcotest.test_case "reload [] works without MCP dependencies" `Quick
        test_reload_empty_without_mcp_deps;
      Alcotest.test_case "reload spawns a server and returns descriptors" `Quick
        test_reload_spawns_server;
      Alcotest.test_case "unchanged config keeps the running instance" `Quick
        test_reload_unchanged_keeps_instance;
      Alcotest.test_case "changed config replaces the running instance" `Quick
        test_reload_changed_restarts_instance;
      Alcotest.test_case "reload [] stops the server" `Quick
        test_reload_removes_server;
      Alcotest.test_case "duplicate names are rejected" `Quick
        test_reload_rejects_duplicate_names;
      Alcotest.test_case "spawn failure keeps the old set" `Quick
        test_reload_spawn_failure_keeps_old_set;
      Alcotest.test_case "reloaded tool is callable" `Quick
        test_reloaded_tool_is_callable;
    ]);
  ]
