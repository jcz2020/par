open Par_core

let () =
  let config = {
    Types.persistence = `Sqlite "par.db";
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
  } in
  Eio_main.run (fun env ->
    Eio.Switch.with (fun switch ->
      match Runtime.create ~config switch with
      | Error err ->
        Printf.eprintf "Failed to create runtime: %s\n"
          (Printexc.to_string (Failure "error"))
      | Ok rt ->
        let handler input _token =
          Types.Success (`String (Printf.sprintf "Echo: %s" (Yojson.Safe.to_string input)))
        in
        let tool = Runtime.register_tool rt
          ~name:"echo"
          ~description:"Echoes back the input"
          ~input_schema:`Assoc [ ("type", `String "object"); ("properties", `Assoc []) ]
          ~handler
          () in
        let agent = {
          Types.id = "echo-agent";
          system_prompt = "You are an echo assistant.";
          model = {
            provider = `Openai;
            model_name = "gpt-4";
            api_base = None;
            temperature = 0.7;
            max_tokens = None;
            top_p = None;
            stop_sequences = None;
          };
          tools = [ tool ];
          max_iterations = 5;
          middleware = [];
          retry_policy = None;
          context_strategy = None;
          resource_quota = None;
        } in
        ignore (Runtime.register_agent rt agent);
        Printf.printf "Agent registered: %s\n" agent.id;
        ignore (Runtime.close rt)
    )
  )
