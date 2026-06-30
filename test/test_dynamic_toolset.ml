open Par
open Par.Types
open Par.Runtime

let valid_schema = `Assoc [("type", `String "object"); ("properties", `Assoc [])]

let test_config : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = default_event_bus_config;
  default_quota = default_quota;
  shutdown = default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = default_bash_confirm;
  event_retention_seconds = 604800.0;
}

let make_rt () =
  Eio.Switch.run (fun sw ->
    match Runtime.create ~config:test_config sw with
    | Ok r -> r
    | Error _ -> Alcotest.fail "Runtime.create failed")

let dummy_model : model_config =
  { provider = `Openai; model_name = "gpt-4"; api_base = None;
    temperature = 0.0; max_tokens = Some 1024; top_p = None;
    stop_sequences = None }

let basic_agent ?(tools : tool_descriptor list = []) ?(id = "test-agent") () : agent_config =
  { id; system_prompt = "You are a test agent.";
    system_prompt_template = None;
    model = dummy_model; tools; max_iterations = 10; middleware = [];
    retry_policy = None; context_strategy = None; resource_quota = None;
    max_execution_time = None; tool_timeout = None;
    early_stopping_method = Force;
    on_max_tokens = Some Return_partial; max_continuation_chunks = Some 3;
    context_compression_threshold = None; compression_cooldown_messages = None; context_window_override = None; cache_strategy = No_caching }

let make_descriptor ?(description = "test") name =
  { Types.name; description; input_schema = valid_schema;
    output_schema = None; permission = Allow; timeout = None;
    concurrency_limit = None; on_update = None }

let handler_returning json : Tool_registry.handler_fn =
  fun _input _token -> Success json

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid_input %S" s
  | Types.External_failure s -> Printf.sprintf "External_failure %S" s
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission_denied %S" s
  | Types.Internal s -> Printf.sprintf "Internal %S" s
  | Types.Embedding_unsupported -> "Embedding_unsupported"

let agent_has_tool_named rt agent_id tool_name =
  match Runtime.list_agents rt
        |> List.find_opt (fun (a : agent_config) -> a.id = agent_id) with
  | None -> Alcotest.failf "agent %s not found" agent_id
  | Some agent ->
    List.exists (fun (d : tool_descriptor) -> d.name = tool_name) agent.tools

let call_tool_via_registry rt tool_name input =
  (* Returns the handler_result, forcing the test to actually exercise
     the registered handler rather than just inspecting types. *)
  match Tool_registry.resolve (Runtime.tool_registry rt) tool_name with
  | None -> Alcotest.failf "handler for %s not registered" tool_name
  | Some h ->
    Eio.Switch.run (fun sw ->
      let token = Par.Cancellation.create_token sw in
      h input token)

let suite = [
  Alcotest.test_case "update_agent_tools adds tool + registers handler" `Quick
    (fun () ->
      Eio_main.run (fun _env ->
        let rt = make_rt () in
        (match Runtime.register_agent rt
           ({ (basic_agent ()) with id = "test-agent"; tools = [] }) with
         | Ok () -> ()
         | Error e -> Alcotest.failf "register_agent: %s" (error_to_string e));
        let binding : tool_binding = {
          descriptor = make_descriptor "calc";
          handler = handler_returning (`String "calc-result");
        } in
        (match Runtime.update_agent_tools rt ~agent_id:"test-agent"
                  ~add:[binding] ~remove:[] with
         | Ok () -> ()
         | Error e -> Alcotest.failf "update_agent_tools: %s"
                        (error_to_string e));
        Alcotest.(check bool) "agent has calc tool"
          true (agent_has_tool_named rt "test-agent" "calc");
        let result = call_tool_via_registry rt "calc" `Null in
        (match result with
         | Success json ->
           Alcotest.(check string) "handler returns expected result"
             "\"calc-result\"" (Yojson.Safe.to_string json)
         | _ -> Alcotest.fail "handler should return Success");
        ignore (Runtime.close rt)));

  Alcotest.test_case "update_agent_tools removes tool from agent" `Quick
    (fun () ->
      Eio_main.run (fun _env ->
        let rt = make_rt () in
        let desc_a = make_descriptor "tool_a" in
        let desc_b = make_descriptor "tool_b" in
        (match Runtime.register_agent rt
           ({ (basic_agent ()) with id = "agent-x"; tools = [desc_a; desc_b] }) with
         | Ok () -> ()
         | Error e -> Alcotest.failf "register_agent: %s" (error_to_string e));
        Tool_registry.register (Runtime.tool_registry rt) desc_a (handler_returning `Null) |> ignore;
        Tool_registry.register (Runtime.tool_registry rt) desc_b (handler_returning `Null) |> ignore;
        (match Runtime.update_agent_tools rt ~agent_id:"agent-x"
                  ~add:[] ~remove:["tool_a"] with
         | Ok () -> ()
         | Error e -> Alcotest.failf "update_agent_tools: %s"
                        (error_to_string e));
        Alcotest.(check bool) "tool_a removed"
          false (agent_has_tool_named rt "agent-x" "tool_a");
        Alcotest.(check bool) "tool_b kept"
          true (agent_has_tool_named rt "agent-x" "tool_b");
        ignore (Runtime.close rt)));

  Alcotest.test_case "update_agent_tools atomic replace via add+remove" `Quick
    (fun () ->
      Eio_main.run (fun _env ->
        let rt = make_rt () in
        let old_desc = make_descriptor ~description:"v1" "gadget" in
        let new_desc = make_descriptor ~description:"v2" "gadget" in
        (match Runtime.register_agent rt
           ({ (basic_agent ()) with id = "agent-y"; tools = [old_desc] }) with
         | Ok () -> ()
         | Error e -> Alcotest.failf "register_agent: %s" (error_to_string e));
        Tool_registry.register (Runtime.tool_registry rt) old_desc
          (handler_returning (`String "old")) |> ignore;
        let new_binding : tool_binding = {
          descriptor = new_desc;
          handler = handler_returning (`String "new");
        } in
        (match Runtime.update_agent_tools rt ~agent_id:"agent-y"
                  ~add:[new_binding] ~remove:["gadget"] with
         | Ok () -> ()
         | Error e -> Alcotest.failf "update_agent_tools: %s"
                        (error_to_string e));
        let agent = List.find (fun (a : agent_config) -> a.id = "agent-y")
                        (Runtime.list_agents rt) in
        let gadget_desc = List.find (fun (d : tool_descriptor) -> d.name = "gadget")
                            agent.tools in
        Alcotest.(check string) "descriptor updated to v2" "v2" gadget_desc.description;
        let result = call_tool_via_registry rt "gadget" `Null in
        (match result with
         | Success json ->
           Alcotest.(check string) "handler returns new behavior"
             "\"new\"" (Yojson.Safe.to_string json)
         | _ -> Alcotest.fail "handler should return Success with new behavior");
        ignore (Runtime.close rt)));

  Alcotest.test_case "unregister_tool removes handler from registry" `Quick
    (fun () ->
      Eio_main.run (fun _env ->
        let rt = make_rt () in
        (match Runtime.register_tool rt
           ~name:"temp" ~description:"temp" ~input_schema:valid_schema
           ~handler:(handler_returning `Null) () with
         | Ok _ -> ()
         | Error _ -> Alcotest.fail "register_tool should succeed");
        Alcotest.(check bool) "handler present before unregister"
          true (Tool_registry.resolve (Runtime.tool_registry rt) "temp" |> Option.is_some);
        (match Runtime.unregister_tool rt ~name:"temp" with
         | Ok () -> ()
         | Error e -> Alcotest.failf "unregister_tool: %s"
                        (error_to_string e));
        Alcotest.(check bool) "handler absent after unregister"
          false (Tool_registry.resolve (Runtime.tool_registry rt) "temp" |> Option.is_some);
        ignore (Runtime.close rt)));

  Alcotest.test_case "unregister_tool errors on unknown name" `Quick
    (fun () ->
      Eio_main.run (fun _env ->
        let rt = make_rt () in
        (match Runtime.unregister_tool rt ~name:"never-registered" with
         | Ok () -> Alcotest.fail "should have failed for unknown tool"
         | Error (Invalid_input _) -> ()
         | Error e -> Alcotest.failf "expected Invalid_input, got: %s"
                        (error_to_string e));
        ignore (Runtime.close rt)));

  Alcotest.test_case "replace_tool updates handler AND descriptor in agents" `Quick
    (fun () ->
      Eio_main.run (fun _env ->
        let rt = make_rt () in
        let v1_desc = make_descriptor ~description:"v1 description" "widget" in
        (match Runtime.register_agent rt
           ({ (basic_agent ()) with id = "agent-z"; tools = [v1_desc] }) with
         | Ok () -> ()
         | Error e -> Alcotest.failf "register_agent: %s" (error_to_string e));
        (match Runtime.register_tool rt
           ~name:"widget" ~description:"v1 description" ~input_schema:valid_schema
           ~handler:(handler_returning (`Int 1)) () with
         | Ok _ -> ()
         | Error _ -> Alcotest.fail "register_tool v1 should succeed");
        let v2_desc = make_descriptor ~description:"v2 description" "widget" in
        (match Runtime.replace_tool rt ~name:"widget"
                  ~descriptor:v2_desc
                  ~handler:(handler_returning (`Int 2)) with
         | Ok () -> ()
         | Error e -> Alcotest.failf "replace_tool: %s"
                        (error_to_string e));
        let agent = List.find (fun (a : agent_config) -> a.id = "agent-z")
                        (Runtime.list_agents rt) in
        let widget_desc = List.find (fun (d : tool_descriptor) -> d.name = "widget")
                            agent.tools in
        Alcotest.(check string) "agent descriptor updated" "v2 description" widget_desc.description;
        let result = call_tool_via_registry rt "widget" `Null in
        (match result with
         | Success json ->
           Alcotest.(check string) "handler returns v2 behavior"
             "2" (Yojson.Safe.to_string json)
         | _ -> Alcotest.fail "handler should return Success with v2");
        ignore (Runtime.close rt)));

  Alcotest.test_case "replace_tool rejects mismatched name" `Quick
    (fun () ->
      Eio_main.run (fun _env ->
        let rt = make_rt () in
        let desc = make_descriptor ~description:"renamed" "different-name" in
        (match Runtime.replace_tool rt ~name:"original"
                  ~descriptor:desc
                  ~handler:(handler_returning `Null) with
         | Ok () -> Alcotest.fail "should reject mismatched name"
         | Error (Invalid_input _) -> ()
         | Error e -> Alcotest.failf "expected Invalid_input, got: %s"
                        (error_to_string e));
        ignore (Runtime.close rt)));
]

let () =
  Alcotest.run "dynamic_toolset" [
    ("dynamic_toolset", suite);
  ]
