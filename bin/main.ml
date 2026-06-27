open Par

(* -------------------------------------------------------------------------- *)
(* Shared CLI argument definitions                                            *)
(* -------------------------------------------------------------------------- *)

let persistence_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "persistence" ] ~docv:"BACKEND" ~doc:"Storage backend: sqlite (default: sqlite)")

let db_uri =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "db-uri" ] ~docv:"URI" ~doc:"SQLite database path (default: ~/.config/par/par.db)")

let provider_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "provider" ] ~docv:"PROVIDER" ~doc:"LLM provider: openai|anthropic (default: openai)")

let api_key_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "api-key" ] ~docv:"KEY" ~doc:"API key for LLM provider (overrides config)")

let api_base =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "api-base" ] ~docv:"URL" ~doc:"Custom API base URL (overrides config)")

let model_name =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "model" ] ~docv:"NAME" ~doc:"Model name (overrides config)")

let system_prompt =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "system-prompt" ] ~docv:"PROMPT" ~doc:"Agent system prompt (overrides config)")

let max_iterations =
  let open Cmdliner in
  Arg.(value & opt int 10 &
    info [ "max-iterations" ] ~docv:"N" ~doc:"Max ReAct iterations (default: 10)")

let retention_days =
  let open Cmdliner in
  Arg.(value & opt (some float) None &
    info [ "retention-days" ] ~docv:"DAYS" ~doc:"Event retention in days, 0=never prune (overrides config)")

let temperature_arg =
  let open Cmdliner in
  Arg.(value & opt (some float) None &
    info [ "temperature" ] ~docv:"FLOAT" ~doc:"Temperature (overrides config)")

let max_tokens_arg =
  let open Cmdliner in
  Arg.(value & opt (some int) None &
    info [ "max-tokens" ] ~docv:"N" ~doc:"Max tokens per LLM response")

let top_p_arg =
  let open Cmdliner in
  Arg.(value & opt (some float) None &
    info [ "top-p" ] ~docv:"FLOAT" ~doc:"Top-p sampling parameter (0.0-1.0)")

let no_parallel_tools =
  let open Cmdliner in
  Arg.(value & flag &
    info [ "no-parallel-tools" ] ~doc:"Disable parallel tool execution")

let question_arg =
  let open Cmdliner in
  Arg.(value & pos_all string [] &
    info [] ~docv:"QUESTION..." ~doc:"Question to ask (may contain spaces)")

(* -------------------------------------------------------------------------- *)
(* Shared helpers                                                             *)
(* -------------------------------------------------------------------------- *)

let error_category_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid input: %s" s
  | Types.External_failure s -> Printf.sprintf "External failure: %s" s
  | Types.Rate_limited -> "Rate limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission denied: %s" s
  | Types.Internal s -> Printf.sprintf "Internal error: %s" s
  | Types.Embedding_unsupported -> "Embedding unsupported"

let make_sqlite_persistence ?(retention_days = 7.0) db_path =
  match Sqlite_persistence.create
    ~retention_ttl:(retention_days *. 24. *. 60. *. 60.)
    db_path with
  | Error e ->
    Printf.eprintf "Error opening SQLite database: %s\n" (error_category_to_string e);
    exit 1
  | Ok t ->
    { Types.
      save_events_fn = (fun events -> Sqlite_persistence.save_events t events);
      load_events_fn = (fun task_id -> Sqlite_persistence.load_events t task_id);
      load_events_by_session_fn = (fun session_id ->
        Sqlite_persistence.load_events_by_session t session_id);
      load_sessions_fn = (fun limit -> Sqlite_persistence.load_sessions t limit);
      save_task_state_fn = (fun ts -> Sqlite_persistence.save_task_state t ts);
      load_task_state_fn = (fun task_id -> Sqlite_persistence.load_task_state t task_id);
      save_workflow_state_fn = (fun id status ckpt ->
        Sqlite_persistence.save_workflow_state t id status ckpt);
      load_workflow_state_fn = (fun id ->
        Sqlite_persistence.load_workflow_state t id);
      save_conversation_fn = (fun sid conv -> Sqlite_persistence.save_conversation t sid conv);
      load_conversation_fn = (fun sid -> Sqlite_persistence.load_conversation t sid);
      load_most_recent_conversation_fn = (fun () ->
        Sqlite_persistence.load_most_recent_conversation t);
      close_fn = (fun () -> Sqlite_persistence.close t);
    }

let make_persistence_service _persistence _backend _db_uri_val =
  let path = Par_config.config_dir () ^ "/par.db" in
  make_sqlite_persistence path

let make_llm_service provider_tag api_key_val api_base_val (net : [< `Generic | `Unix > `Generic ] Eio.Net.ty Eio.Resource.t) =
  let open Types in
  let net_gen = (net :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  match provider_tag with
  | `Openai ->
    let cfg = Openai { api_key = api_key_val; base_url = api_base_val; organization = None; embedding_model = None } in
    (match Openai_provider.create cfg with
     | Error e ->
       Printf.eprintf "Error creating OpenAI provider: %s\n" (error_category_to_string e);
       exit 1
      | Ok t ->
        Openai_provider.set_network t net_gen;
         { complete_fn = (fun mc tools conv -> Openai_provider.complete t mc tools conv);
          stream_fn = (fun mc tools conv sc cb -> Openai_provider.stream t mc tools conv sc cb);
          close_fn = (fun () -> Openai_provider.close t);
          complete_structured_fn = Some (fun mc tools conv schema -> Openai_provider.complete_structured t mc tools conv schema);
          list_models_fn = None; })
  | `Anthropic ->
    let cfg = Anthropic { api_key = api_key_val; base_url = api_base_val } in
    (match Anthropic_provider.create cfg with
     | Error e ->
       Printf.eprintf "Error creating Anthropic provider: %s\n" (error_category_to_string e);
       exit 1
      | Ok t ->
        Anthropic_provider.set_network t net_gen;
        { complete_fn = (fun mc tools conv -> Anthropic_provider.complete t mc tools conv);
         stream_fn = (fun mc tools conv sc cb -> Anthropic_provider.stream t mc tools conv sc cb);
          close_fn = (fun () -> Anthropic_provider.close t);
         complete_structured_fn = Some (fun mc tools conv schema -> Anthropic_provider.complete_structured t mc tools conv schema);
         list_models_fn = None; })
  | `Ollama ->
    (* Ollama exposes an OpenAI-compatible /v1 endpoint. Build the OpenAI
       provider with a localhost base_url and a placeholder api_key that
       Ollama ignores. Mirrors make_embedding_service's Ollama branch
       (PAR-z23 / B.1). *)
    let cfg = Openai { api_key = api_key_val; base_url = Some "http://localhost:11434/v1"; organization = None; embedding_model = None } in
    (match Openai_provider.create cfg with
     | Error e ->
       Printf.eprintf "Error creating Ollama LLM provider: %s\n" (error_category_to_string e);
       exit 1
     | Ok t ->
       Openai_provider.set_network t net_gen;
       { complete_fn = (fun mc tools conv -> Openai_provider.complete t mc tools conv);
         stream_fn = (fun mc tools conv sc cb -> Openai_provider.stream t mc tools conv sc cb);
         close_fn = (fun () -> Openai_provider.close t);
         complete_structured_fn = Some (fun mc tools conv schema -> Openai_provider.complete_structured t mc tools conv schema);
          list_models_fn = None; })
  | `Custom _ ->
    (* OpenAI-compatible custom endpoint. The user must supply base_url via
       --api-base; refuse to start otherwise (PAR-z23 / B.1). *)
    (match api_base_val with
     | None ->
       Printf.eprintf "Error: custom LLM provider requires --api-base\n";
       exit 1
     | Some base ->
       let cfg = Openai { api_key = api_key_val; base_url = Some base; organization = None; embedding_model = None } in
       (match Openai_provider.create cfg with
        | Error e ->
          Printf.eprintf "Error creating custom LLM provider: %s\n" (error_category_to_string e);
          exit 1
        | Ok t ->
          Openai_provider.set_network t net_gen;
          { complete_fn = (fun mc tools conv -> Openai_provider.complete t mc tools conv);
            stream_fn = (fun mc tools conv sc cb -> Openai_provider.stream t mc tools conv sc cb);
            close_fn = (fun () -> Openai_provider.close t);
            complete_structured_fn = Some (fun mc tools conv schema -> Openai_provider.complete_structured t mc tools conv schema);
            list_models_fn = None; }))

let make_embedding_service provider_tag api_key_val api_base_val (net : [< `Generic | `Unix > `Generic ] Eio.Net.ty Eio.Resource.t) =
  let open Types in
  let net_gen = (net :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  match provider_tag with
  | `Openai ->
    let cfg = Openai { api_key = api_key_val; base_url = api_base_val; organization = None; embedding_model = None } in
    (match Openai_provider.create cfg with
     | Error e ->
       Printf.eprintf "Error creating OpenAI embedding provider: %s\n" (error_category_to_string e);
       exit 1
     | Ok t ->
       Openai_provider.set_network t net_gen;
       { embed_fn = (fun msgs -> Openai_provider.embed t msgs);
         close_fn = (fun () -> Openai_provider.close t) })
  | `Anthropic ->
    { embed_fn = (fun _msgs -> Result.Error Embedding_unsupported);
      close_fn = ignore }
  | `Ollama ->
    let cfg = Openai { api_key = api_key_val; base_url = Some "http://localhost:11434/v1"; organization = None; embedding_model = None } in
    (match Openai_provider.create cfg with
     | Error e ->
       Printf.eprintf "Error creating Ollama embedding provider: %s\n" (error_category_to_string e);
       exit 1
     | Ok t ->
       Openai_provider.set_network t net_gen;
       { embed_fn = (fun msgs -> Openai_provider.embed t msgs);
         close_fn = (fun () -> Openai_provider.close t) })
  | `Custom _ ->
    Printf.eprintf "Error: custom provider embeddings not supported in CLI\n";
    exit 1

let default_template =
  "你是{{role}}，你的任务是{{task}}。\n当前可用工具：{{available_tools}}。\n当前时间：{{current_time}}。"

let render_system_prompt (cfg : Par_config.config) ~agent_id ~runtime_id ~tool_names =
  let template_str = match cfg.Par_config.system_prompt_template_override with
    | Some s -> s
    | None -> default_template
  in
  let user_vars = List.map (fun (k, v) -> (k, `String v)) cfg.Par_config.template_variables in
  let context : Template.render_context = {
    agent_id;
    runtime_id;
    user_variables = user_vars;
    available_tools = tool_names;
  } in
  match Template.render
    ~template:template_str
    ~variables:user_vars
    ~required:[]
    ~context with
  | Ok prompt -> prompt
  | Error _ -> cfg.Par_config.system_prompt

let make_runtime_config persistence_val parallel_tool_exec retention_days =
  { Types.
    persistence = persistence_val;
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = parallel_tool_exec;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = retention_days *. 24. *. 60. *. 60.; }

(* -------------------------------------------------------------------------- *)
(* Built-in tools                                                              *)
(* -------------------------------------------------------------------------- *)

let print_error (e : Types.error_category) =
  Printf.eprintf "Error: %s\n" (error_category_to_string e)

let print_json json =
  Printf.printf "%s\n" (Yojson.Safe.pretty_to_string ~std:true json)

(* -------------------------------------------------------------------------- *)
(* Config merge: CLI overrides on top of file config                          *)
(* -------------------------------------------------------------------------- *)

let merge_config
    (cfg : Par_config.config)
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt max_iter
    max_tokens_opt top_p_opt no_parallel_tools retention_days_opt =
  { Par_config.
    provider = (match provider_opt with Some p -> p | None -> cfg.provider);
    api_key = (match api_key_opt with Some k -> k | None -> cfg.api_key);
    api_base = (match api_base_opt with Some b -> Some b | None -> cfg.api_base);
    model = (match model_opt with Some m -> m | None -> cfg.model);
    persistence = (match persistence_opt with Some p -> p | None -> cfg.persistence);
    db_uri = (match db_uri_opt with Some u -> Some u | None -> cfg.db_uri);
    temperature = (match temp_opt with Some t -> t | None -> cfg.temperature);
    system_prompt = (match prompt_opt with Some p -> p | None -> cfg.system_prompt);
    max_iterations = (if max_iter <> cfg.max_iterations then max_iter else cfg.max_iterations);
    max_tokens = (match max_tokens_opt with Some n -> Some n | None -> cfg.max_tokens);
    top_p = (match top_p_opt with Some f -> Some f | None -> cfg.top_p);
    parallel_tool_execution = if no_parallel_tools then false else cfg.parallel_tool_execution;
    template_variables = cfg.template_variables;
    system_prompt_template_override = cfg.system_prompt_template_override;
    mcp_servers = cfg.mcp_servers;
    agents = cfg.agents;
    event_retention_days = (match retention_days_opt with Some d -> d | None -> cfg.event_retention_days);
  }

let require_config () =
  match Par_config.load () with
  | Some cfg -> cfg
  | None ->
    Printf.eprintf "未找到配置文件。请先运行 `par config` 进行配置。\n";
    exit 1

let ensure_rng () =
  Mirage_crypto_rng_unix.use_default ()

let setup_runtime cfg ~interactive:_ ~f =
  ensure_rng ();
  let pers = make_persistence_service cfg.Par_config.persistence
               (Par_config.resolve_persistence cfg) cfg.Par_config.db_uri in
  let persistence_config = Par_config.to_persistence_config cfg in
  let provider_tag = Par_config.to_provider_tag cfg in
  let config = make_runtime_config persistence_config cfg.Par_config.parallel_tool_execution cfg.Par_config.event_retention_days in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun switch ->
  let net = Eio.Stdenv.net env in
  let llm = make_llm_service provider_tag cfg.Par_config.api_key cfg.Par_config.api_base net in
  let embeddings = make_embedding_service provider_tag cfg.Par_config.api_key cfg.Par_config.api_base net in
  let mcp_server_configs = List.map (fun (entry : Par_config.mcp_server_entry) ->
    Mcp_types.Stdio_server {
      name = entry.name; command = entry.command; args = entry.args;
      env = entry.env; cwd = None; startup_timeout = entry.startup_timeout }
  ) cfg.Par_config.mcp_servers in
  match Runtime.create ~persistence:pers ~llm ~embeddings ~config
      ~mcp_servers:mcp_server_configs
      ~mcp_process_mgr:(Eio.Stdenv.process_mgr env)
      ~mcp_clock:(Eio.Stdenv.clock env)
      switch with
  | Error e ->
    Printf.eprintf "Error creating runtime: %s\n" (error_category_to_string e);
    exit 1
  | Ok rt ->
    let tools = Builtin_tools.builtin_tools ~switch ~net in
    let tool_names = List.map (fun (tb : Types.tool_binding) -> tb.descriptor.Types.name) tools in
    let descriptors = List.map (fun (tb : Types.tool_binding) -> tb.descriptor) tools in
    List.iter (fun (tb : Types.tool_binding) ->
      (match Runtime.register_tool rt
         ~name:tb.descriptor.Types.name
         ~description:tb.descriptor.Types.description
         ~input_schema:tb.descriptor.Types.input_schema
         ~handler:tb.handler
         ?permission:(match tb.descriptor.Types.permission with Types.Allow -> None | p -> Some p)
         ?timeout:tb.descriptor.Types.timeout
         ?concurrency_limit:tb.descriptor.Types.concurrency_limit
         () with
       | Ok _ -> ()
       | Error e ->
         Printf.eprintf "Failed to register tool %s: %s\n"
           tb.descriptor.Types.name (error_category_to_string e);
         exit 1)
    ) tools;
    (match Runtime.install_bash_tool
        ~process_mgr:(Eio.Stdenv.process_mgr env)
        ~clock:(Eio.Stdenv.clock env)
        rt with
     | Ok _ -> ()
     | Error e ->
       Printf.eprintf "Warning: bash tool not installed: %s\n" (error_category_to_string e));
    let agent_ids =
      if cfg.Par_config.agents = [] then ["default-agent"]
      else List.map (fun (a : Par_config.agent_entry) -> a.id) cfg.Par_config.agents
    in
    let handoff_target_ids = if cfg.Par_config.agents = [] then [] else agent_ids in
    let descriptors = descriptors @ List.map (fun aid ->
      { Types.name = "transfer_to_" ^ aid;
        description = Printf.sprintf "Transfer the conversation to agent %s" aid;
        input_schema = `Assoc [("type", `String "object"); ("properties", `Assoc [])];
        output_schema = None; permission = Types.Allow;
        timeout = None; concurrency_limit = None; on_update = None }
    ) handoff_target_ids in
    List.iter (fun aid ->
      ignore (Runtime.register_tool rt
        ~name:("transfer_to_" ^ aid)
        ~description:(Printf.sprintf "Transfer the conversation to agent %s" aid)
        ~input_schema:(`Assoc [("type", `String "object"); ("properties", `Assoc [])])
        ~handler:(fun _ _ -> Types.Handoff { target_agent_id = aid; carry_context = true; task = None })
        ())
    ) handoff_target_ids;
    List.iter (fun agent_id ->
      let entry = if cfg.Par_config.agents = [] then None
        else List.find_opt (fun (a : Par_config.agent_entry) -> a.id = agent_id) cfg.Par_config.agents in
      let agent_system_prompt = match entry with
        | Some a -> a.Par_config.system_prompt
        | None -> render_system_prompt cfg ~agent_id ~runtime_id:"cli-runtime" ~tool_names in
      let agent_model_cfg = match entry with
        | Some a when a.Par_config.model <> None ->
          Par_config.to_model_config { cfg with Par_config.model = Option.get a.Par_config.model }
        | _ -> Par_config.to_model_config cfg in
      let agent_max_iter = match entry with
        | Some a -> Option.value a.Par_config.max_iterations ~default:cfg.Par_config.max_iterations
        | None -> cfg.Par_config.max_iterations in
      let agent_descriptors = match entry with
        | Some { Par_config.tools = Some names; _ } ->
          List.filter (fun (d : Types.tool_descriptor) -> List.mem d.Types.name names) descriptors
        | _ -> descriptors in
      (match Runtime.make_agent ~id:agent_id ~system_prompt:agent_system_prompt
         ~model:agent_model_cfg ~tools:agent_descriptors ~max_iterations:agent_max_iter () with
       | Error e -> Printf.eprintf "Agent %s validation failed: %s\n" agent_id (error_category_to_string e); exit 1
       | Ok agent ->
         (match Runtime.register_agent rt agent with
          | Error e -> Printf.eprintf "Error registering agent %s: %s\n" agent_id (error_category_to_string e); exit 1
          | Ok () -> ()))
    ) agent_ids;
     let confirm_fn =
       Some (fun cmd ->
         Printf.eprintf "\n⚠ bash: %s\n" cmd;
         flush stderr;
         true)
     in
    Runtime.register_tool_call_hook rt
      (Bash_confirm.make_hook ?confirm_fn config.Types.bash_confirm);
    Runtime.register_tool_call_hook rt
      (fun (ctx : Hook.tool_call_context) ->
        Printf.eprintf "  [%s]\n" ctx.Hook.tool_name;
        flush stderr;
        Hook.Allow);
    let discovered_skills = Par.Skill_loader.discover () in
    let all_skills = Par.Builtin_skills.builtin_skills @ discovered_skills in
    List.iter (fun (desc : Types.skill_descriptor) ->
      match Runtime.register_skill rt desc with
      | Ok _ -> ()
      | Error _ -> ())
      all_skills;
    f rt;
    ignore (Runtime.close rt)

(* -------------------------------------------------------------------------- *)
(* Health / metrics formatters                                                *)
(* -------------------------------------------------------------------------- *)

let make_tool_event_callback () =
  let start_times : (string, float) Hashtbl.t = Hashtbl.create 8 in
  fun (evt : Types.event) ->
    match evt with
    | Types.Tool_invoked { task_id; _ } ->
      Hashtbl.replace start_times
        (Types.Task_id.to_string task_id) (Unix.gettimeofday ())
    | Types.Tool_completed { task_id; tool_name; duration_ms; _ } ->
      Hashtbl.remove start_times (Types.Task_id.to_string task_id);
      let ms = duration_ms in
      Printf.eprintf "→ %s %s (%.1fms)\n"
        tool_name (Cli_style.green "✓") ms;
      flush stderr
    | Types.Tool_failed { task_id; tool_name; _ } ->
      let elapsed = match Hashtbl.find_opt start_times (Types.Task_id.to_string task_id) with
        | Some t -> (Unix.gettimeofday () -. t) *. 1000.0
        | None -> 0.0
      in
      Hashtbl.remove start_times (Types.Task_id.to_string task_id);
      Printf.eprintf "→ %s %s (%.1fms)\n"
        tool_name (Cli_style.red "✗") elapsed;
      flush stderr
    | Types.Agent_handoff { from_agent; to_agent; _ } ->
      Printf.eprintf "↪ %s %s %s\n" from_agent (Cli_style.dim "→") to_agent;
      flush stderr
    | _ -> ()

let stream_print_chunk (chunk : Types.llm_response_chunk) =
  match chunk with
  | Types.Text_delta { text } ->
    Printf.printf "%s%!" text;
    flush stdout
  | _ -> ()

let format_health_human (h : Types.health_status) =
  let runtime_label = Cli_style.(if h.Types.runtime_alive then green "● alive" else red "✕ dead") in
  let persistence_label = Cli_style.(if h.Types.persistence_ok then green "ok" else red "FAILING") in
  let llm_label = match h.Types.last_llm_call_status with
    | `Success ->
      let ago = match h.Types.last_llm_call_at with
        | Some t -> Printf.sprintf " (%.0fs ago)" (Unix.gettimeofday () -. t)
        | None -> ""
      in
      Cli_style.green ("ok" ^ ago)
    | `Error e ->
      let ago = match h.Types.last_llm_call_at with
        | Some t -> Printf.sprintf " (%.0fs ago)" (Unix.gettimeofday () -. t)
        | None -> ""
      in
      Cli_style.red ("error" ^ ago ^ ": " ^ error_category_to_string e)
    | `Never_called -> Cli_style.dim "never called"
  in
  Printf.printf "  %s  %s\n" (Cli_style.bold "Runtime:    ") runtime_label;
  Printf.printf "  %s  %s\n" (Cli_style.bold "Persistence:") persistence_label;
  Printf.printf "  %s  %s\n" (Cli_style.bold "Last LLM:   ") llm_label

let format_metrics (snap : (string * int) list) =
  `Assoc (List.map (fun (k, v) -> (k, `Int v)) snap)

(* -------------------------------------------------------------------------- *)
(* Skill create wizard                                                        *)
(* -------------------------------------------------------------------------- *)

let skill_prompt_line label default =
  Printf.printf "%s" label;
  flush stdout;
  match input_line stdin with
  | line when String.trim line <> "" -> Some (String.trim line)
  | exception End_of_file -> default
  | _ -> default

let skill_id_valid id =
  String.length id > 0
  && (let s = String.lowercase_ascii id in
      try
        String.iter (fun c ->
          if not (c = '-' || c = '_'
                  || (c >= 'a' && c <= 'z')
                  || (c >= '0' && c <= '9')) then raise Exit) s;
        true
      with Exit -> false)

let format_tool_filter_yaml = function
  | Types.All_tools -> "All"
  | Types.Only xs -> "Only [" ^ String.concat ", " xs ^ "]"
  | Types.Except xs -> "Except [" ^ String.concat ", " xs ^ "]"

let format_trigger_yaml = function
  | Types.Auto -> "Auto"
  | Types.Manual -> "Manual"
  | Keyword { keywords; llm_confirm } ->
    let mode = if llm_confirm then "confirm" else "deterministic" in
    Printf.sprintf "Keyword [%s] %s" (String.concat ", " keywords) mode

let render_skill_md ~id ~name ~description
    ~(system_prompt_override : string option) ~(tool_filter : Types.tool_filter)
    ~(trigger : Types.skill_trigger) ~(expected_output : Yojson.Safe.t option) () =
  let buf = Buffer.create 512 in
  Buffer.add_string buf "---\n";
  Buffer.add_string buf (Printf.sprintf "schema_version: 1\n");
  Buffer.add_string buf (Printf.sprintf "id: %s\n" id);
  Buffer.add_string buf (Printf.sprintf "name: %s\n" name);
  Buffer.add_string buf (Printf.sprintf "description: %s\n" description);
  (match system_prompt_override with
   | Some s ->
     let escaped = String.concat "\\n" (String.split_on_char '\n' s) in
     Buffer.add_string buf (Printf.sprintf "system_prompt_override: \"%s\"\n" escaped)
   | None -> Buffer.add_string buf "system_prompt_override: null\n");
  Buffer.add_string buf (Printf.sprintf "tool_filter: %s\n" (format_tool_filter_yaml tool_filter));
  Buffer.add_string buf (Printf.sprintf "trigger: %s\n" (format_trigger_yaml trigger));
  (match expected_output with
   | Some j -> Buffer.add_string buf (Printf.sprintf "expected_output: %s\n" (Yojson.Safe.to_string j))
   | None -> Buffer.add_string buf "expected_output: null\n");
  Buffer.add_string buf "---\n\n";
  Buffer.add_string buf "## Instructions\n\nReplace this with the skill's instructions.\n\n";
  Buffer.add_string buf "## Examples\n\nAdd examples of when the skill should activate.\n";
  Buffer.contents buf

(* Interactive wizard: prompts for all skill.md frontmatter fields.
   Returns Ok path on success (file written, cache invalidated),
   Error message on validation failure or EOF. *)
let run_skill_create_wizard id_opt =
  let id = match id_opt with
    | Some i -> i
    | None ->
      Printf.printf "Skill wizard — creates ~/.par/skills/<id>/skill.md\n";
      Printf.printf "(Ctrl+D to cancel)\n\n";
      (match skill_prompt_line "Skill id (lowercase/hyphen/underscore): " None with
       | Some i -> i
       | None -> "")
  in
  if not (skill_id_valid id) then
    Printf.eprintf "Invalid id: %S (use lowercase, hyphens, underscores only)\n" id
  else begin
    let name = Option.value (skill_prompt_line (Printf.sprintf "Name [%s]: " id) (Some id)) ~default:id in
    let description =
      match skill_prompt_line "Description (≤1024 chars): " None with
      | Some d -> d
      | None -> ""
    in
    if String.length description > 1024 then
      Printf.eprintf "Description too long (%d > 1024 chars); aborting.\n"
        (String.length description)
    else begin
      let spo = skill_prompt_line "System prompt override (blank = none, \\n for newlines): " None in
      let tf_choice = Option.value
        (skill_prompt_line "Tool filter [All|Only|Except] (default: All): " (Some "All"))
        ~default:"All" in
      let tool_filter = match (String.lowercase_ascii (String.sub tf_choice 0 (min 2 (String.length tf_choice)))) with
        | "on" ->
          let xs = Option.value (skill_prompt_line "Only tools (comma-separated): " None) ~default:"" in
          Types.Only (List.filter (fun s -> s <> "")
                  (List.map String.trim (String.split_on_char ',' xs)))
        | "ex" ->
          let xs = Option.value (skill_prompt_line "Except tools (comma-separated): " None) ~default:"" in
          Types.Except (List.filter (fun s -> s <> "")
                    (List.map String.trim (String.split_on_char ',' xs)))
        | _ -> Types.All_tools
      in
      let tr_choice = Option.value
        (skill_prompt_line "Trigger [Auto|Manual|Keyword] (default: Auto): " (Some "Auto"))
        ~default:"Auto" in
      let trigger =
        match String.lowercase_ascii (String.sub tr_choice 0 (min 2 (String.length tr_choice))) with
        | "ma" -> Types.Manual
        | "ke" ->
          let kws = Option.value (skill_prompt_line "Keywords (comma-separated): " None) ~default:"" in
          let keywords = List.filter (fun s -> s <> "")
              (List.map String.trim (String.split_on_char ',' kws)) in
          Types.Keyword { keywords; llm_confirm = true }
        | _ -> Types.Auto
      in
      let expected_output =
        match skill_prompt_line "Expected output JSON schema (blank = none): " None with
        | Some s when s <> "" ->
          (try Some (Yojson.Safe.from_string s) with _ -> None)
        | _ -> None
      in
      let system_prompt_override = spo in
      let rec mkdir_p d =
        if not (Sys.file_exists d) then begin
          let parent = Filename.dirname d in
          if parent <> d then mkdir_p parent;
          (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
        end
      in
      let dir = Filename.concat (Skill_loader.default_user_skills_dir ()) id in
      (match
         (try Ok (mkdir_p dir) with Sys_error e -> Error e)
       with
       | Error e -> Printf.eprintf "Failed to create %s: %s\n" dir e
       | Ok () ->
         let path = Filename.concat dir "skill.md" in
         let content = render_skill_md ~id ~name ~description
           ~system_prompt_override ~tool_filter ~trigger ~expected_output () in
         (match
            (try
               let oc = open_out path in
               output_string oc content;
               close_out oc;
               Ok ()
             with Sys_error e -> Error e)
          with
         | Error e -> Printf.eprintf "Failed to write %s: %s\n" path e
         | Ok () ->
           Skill_loader.force_reload ();
           Printf.printf "Created: %s\n" path;
           Printf.printf "Use /skill use %s to activate it in this session.\n" id))
    end
  end

let print_help () =
  Printf.printf "可用命令:\n";
  Printf.printf "  /help       显示此帮助\n";
  Printf.printf "  /session    显示当前会话信息\n";
  Printf.printf "  /steer MSG  注入干预消息\n";
  Printf.printf "  /follow MSG 注入后续指导\n";
  Printf.printf "  /health     显示运行时健康状态\n";
  Printf.printf "  /metrics    显示运行时指标\n";
  Printf.printf "  /reset      重置对话（清除历史）\n";
  Printf.printf "  /agents     列出已注册的 agent\n";
  Printf.printf "  /switch <id> 切换到指定 agent\n";
  Printf.printf "  /skills     列出已注册的 skill\n";
  Printf.printf "  /skill <id>                          查看指定 skill 详情\n";
  Printf.printf "  /skill use <id>                      手动激活 skill（覆盖其 trigger）\n";
  Printf.printf "  /skill unuse                         清除手动激活的 skill\n";
  Printf.printf "  /skill create <id>                   交互式创建新 skill\n";
  Printf.printf "  /quit       退出\n"

(* -------------------------------------------------------------------------- *)
(* REPL loop                                                                  *)
(* -------------------------------------------------------------------------- *)

let strip_ansi_escapes = Par.Cli_util.strip_ansi_escapes

let repl rt ~agent_ids ~initial_conv =
  Printf.printf "%s\n"
    (Cli_style.dim "输入消息开始对话（输入 /help 查看命令，Ctrl+D 退出）");
  flush stdout;
  let conv : Types.conversation option ref = ref initial_conv in
  let on_tool_event = make_tool_event_callback () in
  let active_agent = ref (List.hd agent_ids) in
  let rec loop () =
    let prompt_label = if List.length agent_ids > 1 then
        Printf.sprintf "par [%s]> " !active_agent
      else "par> " in
    Printf.printf "%s" (Cli_style.bold_cyan prompt_label);
    flush stdout;
    (match Repl_input.read_line "" with
     | None ->
       let _ = Runtime.save_conversation rt in
       Printf.printf "\n再见！\n";
       flush stdout
     | Some line ->
       let line = strip_ansi_escapes line in
       let trimmed = String.trim line in
       if trimmed = "" then loop ()
       else if trimmed.[0] = '/' then begin
            let parts = String.split_on_char ' ' trimmed in
            let cmd = match parts with c :: _ -> c | [] -> "" in
            let rest = match parts with _ :: r -> String.trim (String.concat " " r) | [] -> "" in
             (match cmd with
               | "/help" -> print_help ()
               | "/session" ->
                 Printf.printf "Active agent: %s\n" !active_agent;
                 Printf.printf "Conversation: %s\n"
                   (match !conv with
                    | None -> "none"
                    | Some c -> Printf.sprintf "%d messages" (List.length c.Types.messages))
               | "/quit" | "/exit" -> let _ = Runtime.save_conversation rt in Printf.printf "再见！\n"; exit 0
              | "/reset" -> conv := None;
                Printf.printf "%s\n" (Cli_style.dim "[对话已重置]")
             | "/steer" -> Runtime.steer rt rest;
               Printf.printf "%s\n" (Cli_style.dim "[steer] 已注入")
             | "/followup" -> Runtime.follow_up rt rest;
               Printf.printf "%s\n" (Cli_style.dim "[followup] 已注入")
             | "/health" -> format_health_human (Runtime.health rt)
             | "/metrics" -> print_json (format_metrics (Runtime.metrics_snapshot rt))
             | "/agents" ->
               let agents = Runtime.list_agents rt in
               List.iter (fun (a : Types.agent_config) ->
                 let status = if a.Types.id = !active_agent then "(active)" else "(idle)" in
                 Printf.printf "  %-20s %s\n" a.Types.id status
               ) agents
               | "/switch" ->
                 if rest = "" then Printf.eprintf "Usage: /switch <agent_id>\n"
                 else if not (List.mem rest agent_ids) then
                   Printf.eprintf "Unknown agent: %s. Use /agents to list.\n" rest
                 else begin
                   active_agent := rest;
                   Printf.printf "%s\n" (Cli_style.dim (Printf.sprintf "[switched to %s]" rest))
                 end
              | "/skills" ->
                let skills = Runtime.list_skills rt in
                if skills = [] then
                  Printf.printf "  (no skills registered)\n"
                else
                  List.iter (fun (s : Types.skill_descriptor) ->
                    let dp = if String.length s.Types.description > 55 then
                      String.sub s.Types.description 0 55 ^ "..." else s.Types.description in
                    Printf.printf "  %-20s %s\n" s.Types.id dp) skills
              | "/skill" ->
                (* rest is "use <id>" | "unuse" | "create <id>" | "<id>" (show) | "" (usage) *)
                let tokens = String.split_on_char ' ' rest
                             |> List.filter (fun s -> s <> "") in
                (match tokens with
                 | [] ->
                   Printf.eprintf "Usage: /skill <use <id>|unuse|create <id>|<id>>\n"
                 | "use" :: [] ->
                   Printf.eprintf "Usage: /skill use <id>\n"
                 | "use" :: id :: _ ->
                   let skills = Runtime.list_skills rt in
                   (match Par.Skill_registry.find_descriptor skills id with
                    | Some _ ->
                      Runtime.set_user_activated_skills rt [id];
                      Printf.printf "Skill activated: %s\n" id
                    | None ->
                      Printf.eprintf "Skill not found: %s. Use /skills to list.\n" id)
                 | "unuse" :: _ ->
                   let prev_count = List.length (Runtime.get_user_activated_skills rt) in
                   Runtime.clear_user_activated_skills rt;
                   Printf.printf "Manual skill activation cleared (%d were active).\n"
                     prev_count
                 | "create" :: [] ->
                   Printf.eprintf "Usage: /skill create <id>\n"
                 | "create" :: id :: _ -> run_skill_create_wizard (Some id)
                 | id :: _ ->
                   (* default: show-details behavior (backward compat) *)
                   let skills = Runtime.list_skills rt in
                   (match Par.Skill_registry.find_descriptor skills id with
                    | Some s ->
                      Printf.printf "ID:          %s\n" s.Types.id;
                      Printf.printf "Name:        %s\n" s.Types.name;
                      Printf.printf "Description: %s\n" s.Types.description;
                      Printf.printf "Trigger:     %s\n" (match s.Types.trigger with
                        | Types.Auto -> "auto" | Types.Manual -> "manual"
                        | Types.Keyword _ -> "keyword")
                    | None -> Printf.eprintf "Skill not found: %s. Use /skills to list.\n" id))
             | _ -> Printf.eprintf "未知命令: %s。输入 /help 查看命令列表。\n" cmd);
            flush stdout;
            loop ()
           end else begin
             (try
                (match Runtime.invoke rt ~agent_id:!active_agent ~message:line
                   ?conversation:!conv
                   ~on_tool_event
                   ~on_chunk:(Some stream_print_chunk)
                   ~enable_handoff:true () with
                 | Error (e, recovered_conv) ->
                   conv := Some recovered_conv;
                   print_error e;
                   let _ = Runtime.save_conversation rt in ()
                 | Ok { Types.response = _; conversation = returned_conv } ->
                   conv := Some returned_conv;
                   Printf.printf "\n";
                   flush stdout;
                   let _ = Runtime.save_conversation rt in ())
              with ex ->
                Printf.eprintf "\n[error] %s\n" (Printexc.to_string ex);
                flush stderr);
             loop ()
           end)
   in
   loop ()

(* -------------------------------------------------------------------------- *)
(* 'par' default command — REPL                                               *)
(* -------------------------------------------------------------------------- *)

let cmd_chat
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt max_iter
    max_tokens_opt top_p_opt no_parallel_tools retention_days_opt
    continue_id_opt resume_opt =
  let cfg = require_config () in
  let cfg = merge_config cfg provider_opt api_key_opt api_base_opt model_opt
              persistence_opt db_uri_opt temp_opt prompt_opt max_iter
              max_tokens_opt top_p_opt no_parallel_tools retention_days_opt in
  let agent_ids =
    if cfg.Par_config.agents = [] then ["default-agent"]
    else List.map (fun (a : Par_config.agent_entry) -> a.id) cfg.Par_config.agents
  in
  let session_target : ([`Resume_most_recent | `Continue of string], [ `No_prior_session | `Session_not_found of string | `Load_error of string ]) Result.t =
    match resume_opt, continue_id_opt with
    | true, _ -> Ok `Resume_most_recent
    | false, Some id -> Ok (`Continue id)
    | _ -> Error `No_prior_session  (* no signal — fresh session *)
  in
  setup_runtime cfg ~interactive:true ~f:(fun rt ->
    let initial_conv : Types.conversation option =
      match session_target with
      | Ok `Resume_most_recent -> (
          match Par.Runtime.load_most_recent_conversation rt with
          | Ok (Some (sid, conv)) ->
            (Printf.printf "Resumed most recent session: %s\n" sid;
             Some conv)
          | Ok None ->
            (Printf.eprintf "No prior session found.\n"; None)
          | Error e ->
            (Printf.eprintf "Failed to load most recent session: %s\n"
               (error_category_to_string e);
             None))
      | Ok (`Continue sid) -> (
          match Par.Runtime.load_conversation rt sid with
          | Ok (Some conv) ->
            (Printf.printf "Resumed session: %s\n" sid;
             Some conv)
          | Ok None ->
            (Printf.eprintf "Session not found: %s\n" sid; None)
          | Error e ->
            (Printf.eprintf "Failed to load session %s: %s\n" sid
               (error_category_to_string e);
             None))
      | Error _ -> None
    in
    repl rt ~agent_ids ~initial_conv)

let term_chat =
  let open Cmdliner.Arg in
  let continue_id_opt =
    value & opt (some string) None
    & info ["c"; "continue"]
        ~doc:"Resume the conversation with the given session id"
  in
  let resume_opt =
    value & flag
    & info ["r"; "resume"]
        ~doc:"Resume the most recent session"
  in
  let open Cmdliner.Term in
  const cmd_chat
  $ provider_arg $ api_key_arg $ api_base $ model_name
  $ persistence_arg $ db_uri $ temperature_arg $ system_prompt $ max_iterations
  $ max_tokens_arg $ top_p_arg $ no_parallel_tools $ retention_days
  $ continue_id_opt $ resume_opt

(* -------------------------------------------------------------------------- *)
(* 'par config' command — interactive wizard                                  *)
(* -------------------------------------------------------------------------- *)

let cmd_config () =
  Par_config.run_wizard ()

let term_config =
  let open Cmdliner.Term in
  const (fun () -> cmd_config ()) $ const ()

let info_config = Cmdliner.Cmd.info "config"
  ~doc:"Configure provider and model settings"

(* -------------------------------------------------------------------------- *)
(* 'par ask' command — single-shot Q&A                                        *)
(* -------------------------------------------------------------------------- *)

let cmd_ask
    question_tokens
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt max_iter
    max_tokens_opt top_p_opt no_parallel_tools retention_days_opt =
  let question = String.concat " " question_tokens in
  let cfg = require_config () in
  let cfg = merge_config cfg provider_opt api_key_opt api_base_opt model_opt
              persistence_opt db_uri_opt temp_opt prompt_opt max_iter
              max_tokens_opt top_p_opt no_parallel_tools retention_days_opt in
  let default_agent_id =
    if cfg.Par_config.agents = [] then "default-agent"
    else (List.hd cfg.Par_config.agents).Par_config.id
  in
  setup_runtime cfg ~interactive:false ~f:(fun rt ->
    match Runtime.invoke rt ~agent_id:default_agent_id ~message:question
        ~on_tool_event:(make_tool_event_callback ())
        ~on_chunk:(Some stream_print_chunk)
        ~enable_handoff:true () with
    | Error (e, _) ->
      Printf.eprintf "Error: %s\n" (error_category_to_string e);
      exit 1
    | Ok { Types.response = resp; conversation = _ } ->
      Printf.printf "\n";
      (match resp.Types.text with
       | Some _ -> flush stdout
       | None -> print_json (Types.llm_response_to_yojson resp)))

let term_ask =
  let open Cmdliner.Term in
  const cmd_ask
  $ question_arg
  $ provider_arg $ api_key_arg $ api_base $ model_name
  $ persistence_arg $ db_uri $ temperature_arg $ system_prompt $ max_iterations
  $ max_tokens_arg $ top_p_arg $ no_parallel_tools $ retention_days

let info_ask = Cmdliner.Cmd.info "ask"
  ~doc:"Ask a single question and print the answer"

(* -------------------------------------------------------------------------- *)
(* 'par update' command — self-update                                         *)
(* -------------------------------------------------------------------------- *)

let run_uname flag =
  let ic = Unix.open_process_in ("uname " ^ flag) in
  let result =
    try input_line ic
    with exn ->
      let _ = Unix.close_process_in ic in
      raise exn in
  let _ = Unix.close_process_in ic in
  String.trim result

let detect_platform () =
  match run_uname "-s" with
  | "Linux" ->
    (match run_uname "-m" with
     | "x86_64" -> Ok "linux-x64"
     | "aarch64" -> Ok "linux-arm64"
     | m -> Error (Printf.sprintf "Unsupported Linux architecture: %s" m))
  | "Darwin" ->
    (match run_uname "-m" with
     | "x86_64" -> Ok "macos-x64"
     | "arm64" -> Ok "macos-arm64"
     | m -> Error (Printf.sprintf "Unsupported macOS architecture: %s" m))
  | s -> Error
    (Printf.sprintf
       "Unsupported OS: %s. Use scripts/build-from-source.sh to update." s)

let strip_v_prefix s =
  let len = String.length s in
  if len > 0 && s.[0] = 'v' then String.sub s 1 (len - 1) else s

let version_compare a b =
  let parse v =
    let v = strip_v_prefix v in
    List.map
      (fun p -> try int_of_string p with _ -> 0)
      (String.split_on_char '.' v) in
  let rec cmp = function
    | [], [] -> 0
    | [], _ -> -1
    | _, [] -> 1
    | x :: xs, y :: ys ->
      if x < y then -1 else if x > y then 1 else cmp (xs, ys) in
  cmp (parse a, parse b)

let upgrade_tls_config_lazy : Tls.Config.client Lazy.t =
  lazy
    (let authenticator =
       match Ca_certs.authenticator () with
       | Ok auth -> auth
       | Error (`Msg msg) ->
         Printf.eprintf
           "Warning: failed to load system CA certs: %s, using no-auth\n" msg;
         fun ?ip:_ ~host:_ _certs -> Ok None in
     match Tls.Config.client ~authenticator () with
     | Ok cfg -> cfg
     | Result.Error (`Msg msg) -> failwith ("TLS configuration error: " ^ msg))

let tls_host_of_string host =
  match Domain_name.of_string host with
  | Error _ -> None
  | Ok dn -> (match Domain_name.host dn with Ok h -> Some h | Error _ -> None)

let upgrade_https_fn uri flow =
  let cfg = Lazy.force upgrade_tls_config_lazy in
  let host = Uri.host uri in
  (match host with
   | Some h ->
     (match tls_host_of_string h with
      | Some dh -> Tls_eio.client_of_flow cfg ~host:dh flow
      | None -> failwith ("Cannot parse hostname for TLS SNI: " ^ h))
   | None -> failwith "No host in URL for TLS connection")

let make_upgrade_client net =
  Cohttp_eio.Client.make ~https:(Some upgrade_https_fn) net

let upgrade_headers =
  Http.Header.of_list
    [ ("user-agent", "P-A-R-CLI/" ^ Par.Version.version)
    ; ("accept", "*/*") ]

let resolve_redirects client ~sw ?(max_hops = 5) uri =
  let rec follow uri hops =
    if hops <= 0 then Error "too many redirects"
    else
      let resp, body =
        Cohttp_eio.Client.get client ~sw ~headers:upgrade_headers uri in
      let status = resp.Http.Response.status |> Cohttp.Code.code_of_status in
      if status = 200 then Ok (resp, body, uri)
      else if Cohttp.Code.is_redirection status then
        match Http.Header.get resp.Http.Response.headers "location" with
        | None -> Error (Printf.sprintf "HTTP %d with no Location header" status)
        | Some loc ->
          let next =
            if String.length loc > 0 && String.sub loc 0 1 = "/" then
              let scheme = match Uri.scheme uri with Some s -> s | None -> "https" in
              let host = match Uri.host uri with Some h -> h | None -> "" in
              Uri.of_string (scheme ^ "://" ^ host ^ loc)
            else
              Uri.of_string loc
          in
          follow next (hops - 1)
      else Error (Printf.sprintf "HTTP %d for %s" status (Uri.to_string uri))
  in
  follow uri max_hops

let http_get_string client ~sw uri =
  match resolve_redirects client ~sw uri with
  | Error e -> Error e
  | Ok (_resp, body, _final_uri) ->
    let s =
      Eio.Buf_read.parse_exn ~max_size:(20 * 1024 * 1024)
        Eio.Buf_read.take_all body in
    Ok s

let http_download_to_file client ~sw uri dest_path =
  match resolve_redirects client ~sw uri with
  | Error e -> Error e
  | Ok (_resp, body, _final_uri) ->
    let data =
      Eio.Buf_read.parse_exn ~max_size:(200 * 1024 * 1024)
        Eio.Buf_read.take_all body in
    let oc = open_out_bin dest_path in
    output_string oc data;
    close_out oc;
    Ok ()

let parse_checksum_for content platform =
  let prefix = "par-" ^ platform in
  let rec loop = function
    | [] -> None
    | line :: rest ->
      let trimmed = String.trim line in
      if String.length trimmed = 0 then loop rest
      else
        let parts = String.split_on_char ' ' trimmed in
        let hash = List.hd parts in
        let fname = String.concat " " (List.tl parts) |> String.trim in
        if fname = prefix then Some (String.trim hash) else loop rest in
  loop (String.split_on_char '\n' content)

let sha512_hex_of_file path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let buf = Bytes.create len in
  really_input ic buf 0 len;
  close_in ic;
  Digestif.SHA512.to_hex (Digestif.SHA512.digest_bytes buf)

let self_path () =
  if Sys.os_type = "Unix" then begin
    try
      let p = Unix.readlink "/proc/self/exe" in
      if String.length p > 0 then Ok p
      else begin
        let argv0 = Sys.argv.(0) in
        if Filename.is_relative argv0 then begin
          let abs = Filename.concat (Sys.getcwd ()) argv0 in
          Ok abs
        end else
          Ok argv0
      end
    with _ ->
      let argv0 = Sys.argv.(0) in
      if Filename.is_relative argv0 then
        Ok (Filename.concat (Sys.getcwd ()) argv0)
      else
        Ok argv0
  end else begin
    let argv0 = Sys.argv.(0) in
    if Filename.is_relative argv0 then
      Ok (Filename.concat (Sys.getcwd ()) argv0)
    else
      Ok argv0
  end

let cmd_update () =
  let current = Par.Version.version in
  Printf.printf "Current version: %s\n" current;
  Printf.printf "Checking for updates...\n";
  flush stdout;
  (match detect_platform () with
   | Error msg ->
     Printf.eprintf "Error: %s\n" msg;
     exit 1
   | Ok platform ->
     ensure_rng ();
     Eio_main.run @@ fun env ->
     Eio.Switch.run @@ fun sw ->
     let net = Eio.Stdenv.net env in
     let client = make_upgrade_client net in
     let chk_uri =
       Uri.of_string
         "https://github.com/jcz2020/par/releases/latest/download/sha512-checksums.txt" in
     (match http_get_string client ~sw chk_uri with
      | Error e ->
        Printf.eprintf "Failed to fetch checksums: %s\n" e;
        exit 1
      | Ok chk_content ->
        let asset_prefix = "par-v" in
        let platform_suffix = "-" ^ platform in
        let latest =
          let rec find lines =
            match lines with
            | [] -> None
            | line :: rest ->
              let trimmed = String.trim line in
              if String.length trimmed = 0 then find rest
              else
                let parts =
                  String.split_on_char ' ' trimmed
                  |> List.filter (fun s -> String.length s > 0)
                in
                (match parts with
                 | _hash :: fname :: _ ->
                   let fname = String.trim fname in
                   if String.length fname > 0 then begin
                     let matches =
                       String.length fname > String.length asset_prefix &&
                       String.sub fname 0 (String.length asset_prefix) = asset_prefix &&
                       String.length fname > String.length platform_suffix &&
                       String.sub fname
                         (String.length fname - String.length platform_suffix)
                         (String.length platform_suffix) = platform_suffix
                     in
                     if matches then begin
                       let v_start = String.length asset_prefix in
                       let v_end =
                         String.length fname - String.length platform_suffix
                       in
                       Some (String.sub fname v_start (v_end - v_start))
                     end else find rest
                   end else find rest
                 | _ -> find rest)
          in
          find (String.split_on_char '\n' chk_content)
        in
        (match latest with
         | None ->
           Printf.eprintf
             "Could not determine latest version from checksums file\n";
           exit 1
         | Some latest ->
           Printf.printf "Latest version: %s\n" latest;
           flush stdout;
           match version_compare current latest with
           | n when n >= 0 ->
             Printf.printf "Already on the latest version (%s).\n" current;
             exit 0
           | _ ->
             let asset_name = "par-" ^ platform in
             let ver_tag = "v" ^ latest in
             let bin_uri = Uri.of_string
               (Printf.sprintf
                  "https://github.com/jcz2020/par/releases/download/%s/%s"
                  ver_tag asset_name) in
             Printf.printf "Downloading %s for %s...\n" latest platform;
             flush stdout;
             let tmpdir =
               Filename.get_temp_dir_name () ^
               "/par-upgrade-" ^ string_of_int (Unix.getpid ()) in
             (try Unix.mkdir tmpdir 0o700
              with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
             let bin_path = tmpdir ^ "/" ^ asset_name in
              (match http_download_to_file client ~sw bin_uri bin_path with
               | Error _ ->
                 Printf.eprintf "No prebuilt binary for %s. Reinstalling from source...\n" platform;
                 flush stderr;
                 exit (Sys.command "curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash")
              | Ok () ->
                (match parse_checksum_for chk_content platform with
                 | None ->
                   Printf.eprintf
                     "No checksum entry for %s in checksums file\n"
                     asset_name;
                   exit 1
                 | Some expected ->
                   let actual = sha512_hex_of_file bin_path in
                   if actual = expected then begin
                     Printf.printf "Checksum verified.\n";
                     flush stdout;
                     (match self_path () with
                      | Error msg ->
                        Printf.eprintf
                          "Cannot determine self path: %s\n" msg;
                        exit 1
                      | Ok self ->
                        (try
                           Unix.rename bin_path self;
                           Unix.chmod self 0o755;
                            Printf.printf
                              "Update complete: %s -> %s\nNew binary: %s\n\
                               Run `par --version` to verify.\n"
                              current latest self;
                           flush stdout
                         with e ->
                           Printf.eprintf
                             "Failed to replace binary: %s\n"
                             (Printexc.to_string e);
                           exit 1))
                   end else begin
                     Printf.eprintf
                       "Checksum mismatch!\n  expected: %s\n  actual:   %s\n"
                       expected actual;
                      exit 1
                    end)))))

let term_update =
  let open Cmdliner.Term in
  const cmd_update $ const ()

let info_update = Cmdliner.Cmd.info "update"
  ~doc:"Check for updates and update par to the latest version"

(* -------------------------------------------------------------------------- *)
(* par history <session_id>                                                   *)
(* -------------------------------------------------------------------------- *)

let format_event_for_history (evt : Types.event) =
  let status ok = if ok then Cli_style.green "✓" else Cli_style.red "✗" in
  match evt with
  | Types.Llm_request_sent { model; _ } ->
    Printf.sprintf "Llm_request_sent: model=%s" model
  | Types.Llm_response_received { usage; _ } ->
    Printf.sprintf "Llm_response_received: %d tokens" usage.Types.total_tokens
  | Types.Tool_invoked { tool_name; _ } ->
    Printf.sprintf "Tool_invoked: %s" tool_name
  | Types.Tool_completed { tool_name; duration_ms; _ } ->
    Printf.sprintf "Tool_completed: %s %s (%.1fms)" tool_name (status true) duration_ms
  | Types.Tool_failed { tool_name; _ } ->
    Printf.sprintf "Tool_failed: %s %s" tool_name (status false)
  | Types.Bash_invoked { tool_name; argv; risk; _ } ->
    Printf.sprintf "Bash_invoked: %s argv=[%s] risk=%s" tool_name (String.concat "; " argv) risk
  | Types.Bash_completed { tool_name; exit_code; duration; _ } ->
    Printf.sprintf "Bash_completed: %s %s exit=%d (%.1fms)" tool_name (status (exit_code = 0)) exit_code duration
  | Types.Agent_handoff { from_agent; to_agent; _ } ->
    Printf.sprintf "Agent_handoff: %s %s %s" from_agent (Cli_style.dim "→") to_agent
  | Types.Task_created { task_type; priority; _ } ->
    Printf.sprintf "Task_created: type=%s priority=%d" task_type priority
  | Types.Task_started _ -> "Task_started"
  | Types.Task_completed { duration_ms; _ } ->
    Printf.sprintf "Task_completed (%.1fms)" duration_ms
  | Types.Task_failed { error; _ } ->
    Printf.sprintf "Task_failed: %s" (error_category_to_string error)
  | Types.Task_cancelled { reason; _ } ->
    Printf.sprintf "Task_cancelled: %s" reason
  | Types.Task_suspended _ -> "Task_suspended"
  | Types.Task_resumed _ -> "Task_resumed"
  | Types.Tool_progress { tool_name; message; _ } ->
    Printf.sprintf "Tool_progress: %s - %s" tool_name message
  | Types.Workflow_started { workflow_run_id } ->
    Printf.sprintf "Workflow_started: %s" (Types.Workflow_run_id.to_string workflow_run_id)
  | Types.Workflow_step_completed { step_id } ->
    Printf.sprintf "Workflow_step_completed: %s" step_id
  | Types.Workflow_completed { workflow_run_id } ->
    Printf.sprintf "Workflow_completed: %s" (Types.Workflow_run_id.to_string workflow_run_id)
  | Types.Workflow_failed { workflow_run_id; error } ->
    Printf.sprintf "Workflow_failed: %s - %s" (Types.Workflow_run_id.to_string workflow_run_id) (error_category_to_string error)
  | Types.Approval_requested { prompt; _ } ->
    Printf.sprintf "Approval_requested: %s" prompt
  | Types.Approval_granted { approver } ->
    Printf.sprintf "Approval_granted: %s" approver
  | Types.Approval_timeout -> "Approval_timeout"
  | Types.Shutdown_initiated -> "Shutdown_initiated"
  | Types.Shutdown_completed { exit_code } ->
    Printf.sprintf "Shutdown_completed: exit_code=%d" exit_code
  | Types.Mcp_server_started { server_name; _ } ->
    Printf.sprintf "Mcp_server_started: %s" server_name
  | Types.Mcp_server_failed { server_id; error } ->
    Printf.sprintf "Mcp_server_failed: %s - %s" server_id (error_category_to_string error)
  | Types.Mcp_server_stopped { server_id } ->
    Printf.sprintf "Mcp_server_stopped: %s" server_id
  | Types.Mcp_tool_invoked { server_id; tool_name } ->
    Printf.sprintf "Mcp_tool_invoked: %s/%s" server_id tool_name
  | Types.Mcp_tool_completed { server_id; tool_name; duration_ms } ->
    Printf.sprintf "Mcp_tool_completed: %s/%s %s (%.1fms)" server_id tool_name (status true) duration_ms
  | Types.Mcp_resource_read { server_id; uri } ->
    Printf.sprintf "Mcp_resource_read: %s uri=%s" server_id uri
  | Types.Mcp_prompt_rendered { server_id; prompt_name } ->
    Printf.sprintf "Mcp_prompt_rendered: %s prompt=%s" server_id prompt_name
  | Types.Structured_output_completed { attempts; schema_valid; _ } ->
    Printf.sprintf "Structured_output_completed: attempts=%d valid=%s" attempts (status schema_valid)
  | Types.Embedding_request_sent { model; input_count } ->
    Printf.sprintf "Embedding_request_sent: model=%s count=%d" model input_count
  | Types.Embedding_response_received { model; output_count; _ } ->
    Printf.sprintf "Embedding_response_received: model=%s count=%d" model output_count
  | Types.Retrieval_completed { query_count; retrieved_count; top_k } ->
    Printf.sprintf "RetrievalCompleted: queries=%d retrieved=%d k=%d" query_count retrieved_count top_k
  | Types.Provider_fallback_attempted { from_provider; to_provider } ->
    Printf.sprintf "ProviderFallback: %s -> %s" from_provider to_provider
  | Types.Llm_response_truncated { model; finish_reason; _ } ->
    Printf.sprintf "LlmTruncated: model=%s reason=%s" model
      (match finish_reason with Stop -> "stop" | Tool_calls -> "tool_calls"
       | Max_tokens -> "max_tokens" | Content_filter -> "content_filter")

let session_id_arg =
  let open Cmdliner in
  Arg.(required & pos 0 (some string) None &
    info [] ~docv:"SESSION_ID" ~doc:"Session ID to show history for")

let history_json =
  let open Cmdliner in
  Arg.(value & flag &
    info [ "json" ] ~doc:"Output raw JSON")

let history_verbose =
  let open Cmdliner in
  Arg.(value & flag &
    info [ "verbose" ] ~doc:"Show full event payloads")

let cmd_history session_id_val json verbose =
  let db_path = Par_config.config_dir () ^ "/par.db" in
  match Sqlite_persistence.create db_path with
  | Error e ->
    Printf.eprintf "Error opening database: %s\n" (error_category_to_string e);
    exit 1
  | Ok t ->
    (match Sqlite_persistence.load_events_by_session t session_id_val with
     | Error e ->
       Printf.eprintf "Error loading events: %s\n" (error_category_to_string e);
       Sqlite_persistence.close t; exit 1
     | Ok [] ->
       Printf.printf "No events found for session: %s\n" session_id_val
     | Ok evs ->
       Printf.printf "Session: %s (%d events)\n\n" session_id_val (List.length evs);
       List.iteri (fun i evt ->
         if json then
           let j = Yojson.Safe.pretty_to_string (Types.event_to_yojson evt) in
           Printf.printf "[%3d] %s\n" (i + 1) j
         else
           let line = format_event_for_history evt in
           if verbose then begin
             let payload = Yojson.Safe.pretty_to_string (Types.event_to_yojson evt) in
             Printf.printf "[%3d] %s\n%s\n" (i + 1) line payload
           end else
             Printf.printf "[%3d] %s\n" (i + 1) line
       ) evs);
    Sqlite_persistence.close t

let term_history =
  let open Cmdliner.Term in
  const cmd_history $ session_id_arg $ history_json $ history_verbose

let info_history = Cmdliner.Cmd.info "history"
  ~doc:"Show event history for a session"

let sessions_limit =
  let open Cmdliner in
  Arg.(value & opt int 10 &
    info [ "limit" ] ~docv:"N" ~doc:"Maximum number of sessions to show (default: 10)")

let format_timestamp ts =
  let tm = Unix.localtime ts in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min

let cmd_sessions limit =
  let db_path = Par_config.config_dir () ^ "/par.db" in
  match Sqlite_persistence.create db_path with
  | Error e ->
    Printf.eprintf "Error opening database: %s\n" (error_category_to_string e);
    exit 1
  | Ok t ->
    (match Sqlite_persistence.load_sessions t limit with
     | Error e ->
       Printf.eprintf "Error loading sessions: %s\n" (error_category_to_string e);
       Sqlite_persistence.close t; exit 1
     | Ok [] ->
       Printf.printf "No sessions found.\n"
     | Ok ss ->
       Printf.printf "%-38s %5s %20s %20s\n" "SESSION_ID" "EVTS" "FIRST_EVENT" "LAST_EVENT";
       Printf.printf "%s\n" (String.make 90 '-');
       List.iter (fun (s : Types.session_summary) ->
         Printf.printf "%-38s %5d %20s %20s\n"
           s.Types.session_id s.Types.event_count
           (format_timestamp s.Types.first_event_at)
           (format_timestamp s.Types.last_event_at)
       ) ss);
    Sqlite_persistence.close t

let term_sessions =
  let open Cmdliner.Term in
  const cmd_sessions $ sessions_limit

let info_sessions = Cmdliner.Cmd.info "sessions"
  ~doc:"List recent sessions"

(* -------------------------------------------------------------------------- *)
(* par stats                                                                  *)
(* -------------------------------------------------------------------------- *)

let cmd_stats () =
  let db_path = Par_config.config_dir () ^ "/par.db" in
  match Sqlite_persistence.create db_path with
  | Error e ->
    Printf.eprintf "Error opening database: %s\n" (error_category_to_string e);
    exit 1
  | Ok t ->
    (match Sqlite_persistence.load_sessions t 20 with
     | Error e ->
       Printf.eprintf "Error loading sessions: %s\n" (error_category_to_string e);
       Sqlite_persistence.close t; exit 1
     | Ok [] ->
       Printf.printf "No sessions found.\n"
      | Ok ss ->
        Printf.printf "%-38s %5s %20s %20s\n" "SESSION_ID" "EVTS" "FIRST_EVENT" "LAST_EVENT";
        Printf.printf "%s\n" (String.make 90 '-');
        List.iter (fun (s : Types.session_summary) ->
          Printf.printf "%-38s %5d %20s %20s\n"
            s.Types.session_id s.Types.event_count
            (format_timestamp s.Types.first_event_at)
            (format_timestamp s.Types.last_event_at)
        ) ss);
    (match Sqlite_persistence.load_recent_events t 10000 with
     | Error _ -> ()
     | Ok events ->
       let total = List.length events in
       let llm_calls = List.length (List.filter (function Types.Llm_request_sent _ -> true | _ -> false) events) in
       let tool_invoked = List.filter (function
         | Types.Tool_invoked _ -> true
         | Types.Bash_invoked _ -> true
         | Types.Mcp_tool_invoked _ -> true
         | _ -> false) events in
       let tool_counts = Hashtbl.create 16 in
       List.iter (fun evt ->
         let name = match evt with
           | Types.Tool_invoked { tool_name; _ } -> tool_name
           | Types.Bash_invoked { tool_name; _ } -> tool_name
           | Types.Mcp_tool_invoked { tool_name; _ } -> tool_name
           | _ -> "unknown"
         in
         let prev = try Hashtbl.find tool_counts name with Not_found -> 0 in
         Hashtbl.replace tool_counts name (prev + 1)
       ) tool_invoked;
       Printf.printf "\nMETRICS\n";
       Printf.printf "  Total events:     %d\n" total;
       Printf.printf "  LLM calls:        %d\n" llm_calls;
       Printf.printf "  Tool calls:       %d\n" (List.length tool_invoked);
       if Hashtbl.length tool_counts > 0 then begin
         Printf.printf "  Top tools:\n";
         let sorted = Hashtbl.fold (fun k v acc -> (k, v) :: acc) tool_counts [] in
         let sorted = List.sort (fun (_, a) (_, b) -> compare b a) sorted in
         List.iteri (fun i (name, count) ->
           if i < 5 then Printf.printf "    %-20s %d\n" name count
         ) sorted
       end);
    Sqlite_persistence.close t

let term_stats =
  let open Cmdliner.Term in
  const cmd_stats $ const ()

let info_stats = Cmdliner.Cmd.info "stats"
  ~doc:"Show usage statistics and recent sessions"

(* -------------------------------------------------------------------------- *)
(* par skill subcommand group                                                  *)
(* -------------------------------------------------------------------------- *)

let discover_skills_for_cli () =
  Par.Skill_loader.discover () @ Par.Builtin_skills.builtin_skills
  |> List.sort (fun (a : Types.skill_descriptor) (b : Types.skill_descriptor) ->
       String.compare a.Types.id b.Types.id)

let cmd_skill_list () =
  let skills = discover_skills_for_cli () in
  if skills = [] then Printf.printf "(no skills discovered)\n"
  else
    List.iter (fun (s : Types.skill_descriptor) ->
      let dp = if String.length s.Types.description > 55 then
        String.sub s.Types.description 0 55 ^ "..." else s.Types.description in
      Printf.printf "  %-20s %s\n" s.Types.id dp) skills

let cmd_skill_show id =
  let skills = discover_skills_for_cli () in
  match Par.Skill_registry.find_descriptor skills id with
  | Some s ->
    Printf.printf "ID:          %s\n" s.Types.id;
    Printf.printf "Name:        %s\n" s.Types.name;
    Printf.printf "Description: %s\n" s.Types.description;
    Printf.printf "Trigger:     %s\n" (match s.Types.trigger with
      | Types.Auto -> "auto" | Types.Manual -> "manual"
      | Types.Keyword { keywords; _ } ->
        Printf.sprintf "keyword [%s]" (String.concat ", " keywords));
    Printf.printf "Tool filter: %s\n"
      (match s.Types.tool_filter with
       | Types.All_tools -> "All"
       | Types.Only xs -> "Only [" ^ String.concat ", " xs ^ "]"
       | Types.Except xs -> "Except [" ^ String.concat ", " xs ^ "]");
    (match s.Types.system_prompt_override with
     | Some p -> Printf.printf "Override:    %s\n"
                   (if String.length p > 60 then String.sub p 0 60 ^ "..." else p)
     | None -> ())
  | None ->
    Printf.eprintf "Skill not found: %s\n" id;
    exit 1

let cmd_skill_use id =
  let skills = discover_skills_for_cli () in
  match Par.Skill_registry.find_descriptor skills id with
  | Some _ ->
    (* Standalone activation is session-scoped: a CLI process exits before
       any invoke can consume it. Validate + inform; the REPL /skill use
       is the path that actually applies the activation. *)
    Printf.printf "Skill '%s' is available.\n" id;
    Printf.printf "Note: manual activation applies to a running session.\n";
    Printf.printf "Run `par` then `/skill use %s` to activate it in the REPL.\n" id
  | None ->
    Printf.eprintf "Skill not found: %s\n" id;
    exit 1

let cmd_skill_create id_opt =
  run_skill_create_wizard id_opt

let cmd_skill_reload () =
  Par.Skill_loader.force_reload ();
  Printf.printf "Skill filesystem cache invalidated. Next discovery will rescan.\n"

let term_skill_list =
  let open Cmdliner.Term in const cmd_skill_list $ const ()

let term_skill_show =
  let open Cmdliner.Term in
  const cmd_skill_show $
    (let open Cmdliner in
     Arg.(required & pos 0 (some string) None &
       info [] ~docv:"ID" ~doc:"Skill id to show"))

let term_skill_use =
  let open Cmdliner.Term in
  const cmd_skill_use $
    (let open Cmdliner in
     Arg.(required & pos 0 (some string) None &
       info [] ~docv:"ID" ~doc:"Skill id to activate"))

let term_skill_create =
  let open Cmdliner.Term in
  const cmd_skill_create $
    (let open Cmdliner in
     Arg.(value & pos 0 (some string) None &
       info [] ~docv:"ID" ~doc:"Optional skill id (will be prompted if omitted)"))

let term_skill_reload =
  let open Cmdliner.Term in const cmd_skill_reload $ const ()

let info_skill_list = Cmdliner.Cmd.info "list"
  ~doc:"List all discovered skills"
let info_skill_show = Cmdliner.Cmd.info "show"
  ~doc:"Show details of a specific skill"
let info_skill_use = Cmdliner.Cmd.info "use"
  ~doc:"Validate a skill is available for /skill use in the REPL"
let info_skill_create = Cmdliner.Cmd.info "create"
  ~doc:"Interactive wizard: create a new skill in ~/.par/skills/<id>/skill.md"
let info_skill_reload = Cmdliner.Cmd.info "reload"
  ~doc:"Force filesystem skill rescan (invalidates mtime cache)"

let cmd_skill =
  let open Cmdliner.Cmd in
  group
    (info "skill" ~doc:"Manage skills: list, show, create, reload")
    [
      v info_skill_list term_skill_list;
      v info_skill_show term_skill_show;
      v info_skill_use term_skill_use;
      v info_skill_create term_skill_create;
      v info_skill_reload term_skill_reload;
    ]

let print_custom_help () =
  let open Cli_style in
  let section s = Printf.printf "\n%s\n" (heading s) in
  let opt flag desc = Printf.printf "%s\n" (option_line flag desc) in
  Printf.printf "%s  %s\n\n" (bold "par") (dim "v" ^ Par.Version.version);
  Printf.printf "%s\n" (dim "Programmable Agent Runtime for OCaml 5.4+");
  section "COMMANDS";
  opt "par"                      "Interactive REPL (default)";
  opt "par ask QUESTION"         "Single-shot Q&A, print answer and exit";
  opt "par config"               "Configure provider, API key, and model";
  opt "par update"               "Check for updates and self-update";
  opt "par sessions"             "List recent sessions";
  opt "par history SESSION_ID"   "Show event history for a session";
  opt "par stats"                "Show usage statistics and recent sessions";
  opt "par skill"                "Manage skills (list/show/create/use/reload)";
  section "OPTIONS";
  opt "--provider PROVIDER"      "LLM provider: openai|anthropic (default: openai)";
  opt "--api-key KEY"            "API key (overrides config file)";
  opt "--api-base URL"           "Custom API base URL (overrides config)";
  opt "--model NAME"             "Model name (overrides config)";
  opt "--system-prompt PROMPT"   "System prompt (overrides config)";
  opt "--temperature FLOAT"      "Temperature 0.0–1.0";
  opt "--max-tokens N"           "Max tokens per LLM response";
  opt "--max-iterations N"       "Max ReAct iterations (default: 10)";
  opt "--top-p FLOAT"            "Top-p sampling 0.0–1.0";
  opt "--persistence BACKEND"    "sqlite (default: sqlite)";
  opt "--db-uri URI"             "SQLite database path (overrides default location)";
  opt "--no-parallel-tools"      "Disable parallel tool execution";
  opt "--retention-days DAYS"    "Event retention days, 0=never prune (default: 7)";
  opt "-c, --continue SESSION"  "Resume the conversation with the given session id";
  opt "-r, --resume"             "Resume the most recent session";
  section "EXAMPLES";
  Printf.printf "  %s\n" (dim "par                                    # start REPL");
  Printf.printf "  %s\n" (dim "par ask \"what is OCaml?\"            # single shot");
  Printf.printf "  %s\n" (dim "par config                            # setup wizard");
  Printf.printf "  %s\n" (dim "par update                            # self-update");
  Printf.printf "  %s\n" (dim "par -r                                # resume most recent session");
  Printf.printf "  %s\n" (dim "par -c <session-id>                   # resume specific session");
  Printf.printf "\n%s\n" (dim "Read the docs: https://github.com/jcz2020/par")

(* -------------------------------------------------------------------------- *)
(* Root command                                                               *)
(* -------------------------------------------------------------------------- *)

let cmd_models provider_id_opt =
  let cfg = require_config () in
  let cfg = merge_config cfg None None None None
              None None None None cfg.Par_config.max_iterations
              None None false (Some 7.0) in
  setup_runtime cfg ~interactive:false ~f:(fun rt ->
    let result =
      match provider_id_opt with
      | Some pid -> Par.Runtime.list_models rt ~id:pid ()
      | None -> Par.Runtime.list_models rt ()
    in
    match result with
    | Ok models -> List.iter (fun m -> Printf.printf "%s\n" m) models
    | Error e -> Printf.eprintf "Error listing models: %s\n" (error_category_to_string e))

let provider_id_arg =
  let open Cmdliner.Arg in
  value & opt (some string) None & info ["provider"] ~docv:"ID"
    ~doc:"List models from a specific provider id"

let term_models =
  let open Cmdliner.Term in
  const cmd_models $ provider_id_arg

let info_models = Cmdliner.Cmd.info "models"
  ~doc:"List available LLM models"

let cmd =
  let open Cmdliner.Cmd in
  group ~default:term_chat
    (info "par" ~version:Par.Version.version
       ~doc:"P-A-R: Programmable Agent Runtime — run 'par' to start REPL, 'par config' to configure, 'par ask \"question\"' for one-shot")
    [
      v info_config term_config;
      v info_ask term_ask;
      v info_update term_update;
      v info_sessions term_sessions;
      v info_history term_history;
      v info_stats term_stats;
      cmd_skill;
      v info_models term_models;
    ]

let () =
  if not (Unix.isatty Unix.stdout) then Unix.putenv "TERM" "dumb";
  (if Array.length Sys.argv >= 2 then
    match Sys.argv.(1) with
    | "-v" | "-V" ->
      print_endline Par.Version.version; exit 0
    | "-h" | "--help" | "--help=plain" | "--help=auto" ->
      print_custom_help (); exit 0
    | _ -> ());
  exit (Cmdliner.Cmd.eval cmd)
