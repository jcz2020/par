open Par

(* -------------------------------------------------------------------------- *)
(* Shared CLI argument definitions                                            *)
(* -------------------------------------------------------------------------- *)

let persistence_arg =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "persistence" ] ~docv:"BACKEND" ~doc:"Storage backend: sqlite|postgres (default: sqlite)")

let db_uri =
  let open Cmdliner in
  Arg.(value & opt (some string) None &
    info [ "db-uri" ] ~docv:"URI" ~doc:"PostgreSQL connection URI")

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

let temperature_arg =
  let open Cmdliner in
  Arg.(value & opt (some float) None &
    info [ "temperature" ] ~docv:"FLOAT" ~doc:"Temperature (overrides config)")

let question_arg =
  let open Cmdliner in
  Arg.(required & pos 0 (some string) None &
    info [] ~docv:"QUESTION" ~doc:"Question to ask")

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

let make_sqlite_persistence db_path =
  match Sqlite_persistence.create db_path with
  | Error e ->
    Printf.eprintf "Error opening SQLite database: %s\n" (error_category_to_string e);
    exit 1
  | Ok t ->
    { Types.
      save_events_fn = (fun events -> Sqlite_persistence.save_events t events);
      load_events_fn = (fun task_id -> Sqlite_persistence.load_events t task_id);
      save_task_state_fn = (fun ts -> Sqlite_persistence.save_task_state t ts);
      load_task_state_fn = (fun task_id -> Sqlite_persistence.load_task_state t task_id);
      save_workflow_state_fn = (fun id status ckpt ->
        Sqlite_persistence.save_workflow_state t id status ckpt);
      load_workflow_state_fn = (fun id ->
        Sqlite_persistence.load_workflow_state t id);
      close_fn = (fun () -> Sqlite_persistence.close t);
    }

let make_postgres_persistence _conninfo =
  Result.Error (Types.Internal
    "PostgreSQL backend requires 'opam install postgresql' then rebuild")

let make_persistence_service persistence _backend db_uri_val =
  match String.lowercase_ascii persistence with
  | "postgres" ->
    let conninfo = match db_uri_val with Some u -> u | None -> "postgresql://localhost/par" in
    (match make_postgres_persistence conninfo with
     | Ok t -> t
     | Error e ->
       Printf.eprintf "Error: %s\n" (error_category_to_string e);
       exit 1)
  | _ ->
    let path = "par.db" in
    make_sqlite_persistence path

let make_llm_service provider_tag api_key_val api_base_val (net : [< `Generic | `Unix > `Generic ] Eio.Net.ty Eio.Resource.t) =
  let open Types in
  let net_gen = (net :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  match provider_tag with
  | `Openai ->
    let cfg = Openai { api_key = api_key_val; base_url = api_base_val; organization = None } in
    (match Openai_provider.create cfg with
     | Error e ->
       Printf.eprintf "Error creating OpenAI provider: %s\n" (error_category_to_string e);
       exit 1
      | Ok t ->
        Openai_provider.set_network t net_gen;
        { complete_fn = (fun mc tools conv -> Openai_provider.complete t mc tools conv);
          stream_fn = (fun mc tools conv sc cb -> Openai_provider.stream t mc tools conv sc cb);
          close_fn = (fun () -> Openai_provider.close t) })
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
         close_fn = (fun () -> Anthropic_provider.close t) })

let make_runtime_config persistence_val =
  { Types.
    persistence = persistence_val;
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 } }

(* -------------------------------------------------------------------------- *)
(* Built-in tools                                                              *)
(* -------------------------------------------------------------------------- *)

let make_agent_config id prompt provider_tag model temp max_iter tools =
  { Types.
    id; system_prompt = prompt;
    system_prompt_template = None;
    model = {
      provider = (match provider_tag with `Openai -> `Openai | `Anthropic -> `Anthropic);
      model_name = model; api_base = None; temperature = temp;
      max_tokens = None; top_p = None; stop_sequences = None;
    };
    tools; max_iterations = max_iter; middleware = [];
    retry_policy = None; context_strategy = None; resource_quota = None }

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
    persistence_opt db_uri_opt temp_opt prompt_opt =
  { Par_config.
    provider = (match provider_opt with Some p -> p | None -> cfg.provider);
    api_key = (match api_key_opt with Some k -> k | None -> cfg.api_key);
    api_base = (match api_base_opt with Some b -> Some b | None -> cfg.api_base);
    model = (match model_opt with Some m -> m | None -> cfg.model);
    persistence = (match persistence_opt with Some p -> p | None -> cfg.persistence);
    db_uri = (match db_uri_opt with Some u -> Some u | None -> cfg.db_uri);
    temperature = (match temp_opt with Some t -> t | None -> cfg.temperature);
    system_prompt = (match prompt_opt with Some p -> p | None -> cfg.system_prompt);
  }

let require_config () =
  match Par_config.load () with
  | Some cfg -> cfg
  | None ->
    Printf.eprintf "未找到配置文件。请先运行 `par config` 进行配置。\n";
    exit 1

let ensure_rng () =
  Mirage_crypto_rng_unix.use_default ()

let setup_runtime cfg ~f =
  ensure_rng ();
  let pers = make_persistence_service cfg.Par_config.persistence
               (Par_config.resolve_persistence cfg) cfg.Par_config.db_uri in
  let persistence_config = Par_config.to_persistence_config cfg in
  let provider_tag = Par_config.to_provider_tag cfg in
  let config = make_runtime_config persistence_config in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun switch ->
  let net = Eio.Stdenv.net env in
  let llm = make_llm_service provider_tag cfg.Par_config.api_key cfg.Par_config.api_base net in
  match Runtime.create ~persistence:pers ~llm ~config switch with
  | Error e ->
    Printf.eprintf "Error creating runtime: %s\n" (error_category_to_string e);
    exit 1
  | Ok rt ->
    let tools = Builtin_tools.builtin_tools ~switch ~net in
    List.iter (fun (tb : Types.tool_binding) ->
      ignore (Tool_registry.register (Runtime.tool_registry rt) tb.descriptor tb.handler : (unit, [ `Duplicate_tool of string ]) result)
    ) tools;
    let descriptors = List.map (fun (tb : Types.tool_binding) -> tb.descriptor) tools in
    let agent = make_agent_config "default-agent" cfg.Par_config.system_prompt
                   provider_tag cfg.Par_config.model cfg.Par_config.temperature 10 descriptors in
    (match Runtime.register_agent rt agent with
     | Error e ->
       Printf.eprintf "Error registering agent: %s\n" (error_category_to_string e);
       exit 1
     | Ok () ->
       f rt;
       ignore (Runtime.close rt))

(* -------------------------------------------------------------------------- *)
(* REPL loop                                                                  *)
(* -------------------------------------------------------------------------- *)

let repl rt agent_id_val =
  Printf.printf "输入消息开始对话（Ctrl+D 退出）\n";
  let rec loop () =
    Printf.printf "> ";
    flush stdout;
    (try
       match input_line stdin with
       | line when String.trim line = "" -> loop ()
       | line ->
         (match Runtime.invoke rt ~agent_id:agent_id_val ~message:line () with
          | Error e -> print_error e
          | Ok resp ->
            (match resp.Types.text with
             | Some txt -> Printf.printf "%s\n" txt
             | None -> print_json (Types.llm_response_to_yojson resp));
            flush stdout);
         loop ()
     with End_of_file -> Printf.printf "\n再见！\n")
  in
  loop ()

(* -------------------------------------------------------------------------- *)
(* 'par' default command — REPL                                               *)
(* -------------------------------------------------------------------------- *)

let cmd_chat
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt _max_iter =
  let cfg = require_config () in
  let cfg = merge_config cfg provider_opt api_key_opt api_base_opt model_opt
              persistence_opt db_uri_opt temp_opt prompt_opt in
  setup_runtime cfg ~f:(fun rt -> repl rt "default-agent")

let term_chat =
  let open Cmdliner.Term in
  const cmd_chat
  $ provider_arg $ api_key_arg $ api_base $ model_name
  $ persistence_arg $ db_uri $ temperature_arg $ system_prompt $ max_iterations

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
    question
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt _max_iter =
  let cfg = require_config () in
  let cfg = merge_config cfg provider_opt api_key_opt api_base_opt model_opt
              persistence_opt db_uri_opt temp_opt prompt_opt in
  setup_runtime cfg ~f:(fun rt ->
    match Runtime.invoke rt ~agent_id:"default-agent" ~message:question () with
    | Error e ->
      Printf.eprintf "Error: %s\n" (error_category_to_string e);
      exit 1
    | Ok resp ->
      (match resp.Types.text with
       | Some txt -> Printf.printf "%s\n" txt
       | None -> print_json (Types.llm_response_to_yojson resp));
      flush stdout)

let term_ask =
  let open Cmdliner.Term in
  const cmd_ask
  $ question_arg
  $ provider_arg $ api_key_arg $ api_base $ model_name
  $ persistence_arg $ db_uri $ temperature_arg $ system_prompt $ max_iterations

let info_ask = Cmdliner.Cmd.info "ask"
  ~doc:"Ask a single question and print the answer"

(* -------------------------------------------------------------------------- *)
(* Root command                                                               *)
(* -------------------------------------------------------------------------- *)

let cmd =
  let open Cmdliner.Cmd in
  group ~default:term_chat
    (info "par" ~version:"0.1.0"
       ~doc:"P-A-R: Programmable Agent Runtime"
       ~man:[
         `S "DESCRIPTION";
         `P "P-A-R is a Programmable Agent Runtime for building AI agent systems.";
         `P "Run 'par' to start a REPL, 'par config' to configure, or 'par ask \"question\"' for one-shot.";
       ])
    [
      v info_config term_config;
      v info_ask term_ask;
    ]

let () =
  exit (Cmdliner.Cmd.eval cmd)
