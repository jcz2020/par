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
     let path = Par_config.config_dir () ^ "/par.db" in
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

let make_runtime_config persistence_val parallel_tool_exec =
  { Types.
    persistence = persistence_val;
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = parallel_tool_exec; }

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
    max_tokens_opt top_p_opt no_parallel_tools =
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
  let config = make_runtime_config persistence_config cfg.Par_config.parallel_tool_execution in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun switch ->
  let net = Eio.Stdenv.net env in
  let llm = make_llm_service provider_tag cfg.Par_config.api_key cfg.Par_config.api_base net in
  let mcp_server_configs = List.map (fun (entry : Par_config.mcp_server_entry) ->
    { Mcp_types.name = entry.name; command = entry.command; args = entry.args;
      env = entry.env; cwd = None; startup_timeout = entry.startup_timeout }
  ) cfg.Par_config.mcp_servers in
  match Runtime.create ~persistence:pers ~llm ~config
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
    let system_prompt = render_system_prompt cfg
        ~agent_id:"default-agent"
        ~runtime_id:"cli-runtime"
        ~tool_names in
    let model_cfg = Par_config.to_model_config cfg in
    let agent_result = Runtime.make_agent
      ~id:"default-agent"
      ~system_prompt
      ~model:model_cfg
      ~tools:descriptors
      ~max_iterations:cfg.Par_config.max_iterations () in
    (match agent_result with
     | Error e ->
       Printf.eprintf "Agent validation failed: %s\n" (error_category_to_string e);
       exit 1
     | Ok agent ->
       (match Runtime.register_agent rt agent with
        | Error e ->
          Printf.eprintf "Error registering agent: %s\n" (error_category_to_string e);
          exit 1
        | Ok () ->
           Runtime.register_tool_call_hook rt
             (fun (ctx : Hook.tool_call_context) ->
               Printf.eprintf "  [%s]\n" ctx.Hook.tool_name;
               flush stderr;
               Hook.Allow);
           f rt;
           ignore (Runtime.close rt)))

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
    | _ -> ()

let stream_print_chunk (chunk : Types.llm_response_chunk) =
  match chunk with
  | Types.Text_delta { text } ->
    Printf.printf "%s%!" text;
    flush stdout
  | _ -> ()

let format_health (h : Types.health_status) =
  `Assoc [
    ("runtime_alive", `Bool h.Types.runtime_alive);
    ("last_llm_call_at", (match h.Types.last_llm_call_at with
                          | Some t -> `Float t | None -> `Null));
    ("last_llm_call_status", (match h.Types.last_llm_call_status with
      | `Success -> `String "success"
      | `Error e -> `String (Printf.sprintf "error: %s" (error_category_to_string e))
      | `Never_called -> `String "never_called"));
    ("persistence_ok", `Bool h.Types.persistence_ok);
  ]

let format_metrics (snap : (string * int) list) =
  `Assoc (List.map (fun (k, v) -> (k, `Int v)) snap)

let print_help () =
  Printf.printf "可用命令:\n";
  Printf.printf "  /help       显示此帮助\n";
  Printf.printf "  /steer MSG  注入干预消息\n";
  Printf.printf "  /follow MSG 注入后续指导\n";
  Printf.printf "  /health     显示运行时健康状态\n";
  Printf.printf "  /metrics    显示运行时指标\n";
  Printf.printf "  /reset      重置对话（清除历史）\n";
  Printf.printf "  /quit       退出\n"

(* -------------------------------------------------------------------------- *)
(* REPL loop                                                                  *)
(* -------------------------------------------------------------------------- *)

let repl rt agent_id_val =
  Printf.printf "%s\n"
    (Cli_style.dim "输入消息开始对话（输入 /help 查看命令，Ctrl+D 退出）");
  let conv : Types.conversation option ref = ref None in
  let on_tool_event = make_tool_event_callback () in
  let rec loop () =
    Printf.printf "%s" (Cli_style.bold_cyan "par> ");
    flush stdout;
    (try
       match input_line stdin with
       | line when String.trim line = "" -> loop ()
       | line ->
         let trimmed = String.trim line in
         if String.length trimmed > 0 && trimmed.[0] = '/' then begin
           let parts = String.split_on_char ' ' trimmed in
           let cmd = match parts with c :: _ -> c | [] -> "" in
           let rest = match parts with _ :: r -> String.trim (String.concat " " r) | [] -> "" in
           (match cmd with
             | "/help" -> print_help ()
             | "/quit" | "/exit" -> Printf.printf "再见！\n"; exit 0
             | "/reset" -> conv := None;
               Printf.printf "%s\n" (Cli_style.dim "[对话已重置]")
            | "/steer" -> Runtime.steer rt rest;
              Printf.printf "%s\n" (Cli_style.dim "[steer] 已注入")
            | "/followup" -> Runtime.follow_up rt rest;
              Printf.printf "%s\n" (Cli_style.dim "[followup] 已注入")
            | "/health" -> print_json (format_health (Runtime.health rt))
            | "/metrics" -> print_json (format_metrics (Runtime.metrics_snapshot rt))
            | _ -> Printf.eprintf "未知命令: %s。输入 /help 查看命令列表。\n" cmd);
           flush stdout;
           loop ()
          end else begin
            (match Runtime.invoke rt ~agent_id:agent_id_val ~message:line
               ?conversation:!conv
               ~on_tool_event
               ~on_chunk:(Some stream_print_chunk) () with
             | Error (e, recovered_conv) ->
               conv := Some recovered_conv;
               print_error e
              | Ok { Types.response = _; conversation = returned_conv } ->
                conv := Some returned_conv;
                Printf.printf "\n";
                flush stdout);
            loop ()
          end
     with End_of_file -> Printf.printf "\n再见！\n")
  in
  loop ()

(* -------------------------------------------------------------------------- *)
(* 'par' default command — REPL                                               *)
(* -------------------------------------------------------------------------- *)

let cmd_chat
    provider_opt api_key_opt api_base_opt model_opt
    persistence_opt db_uri_opt temp_opt prompt_opt max_iter
    max_tokens_opt top_p_opt no_parallel_tools =
  let cfg = require_config () in
  let cfg = merge_config cfg provider_opt api_key_opt api_base_opt model_opt
              persistence_opt db_uri_opt temp_opt prompt_opt max_iter
              max_tokens_opt top_p_opt no_parallel_tools in
  setup_runtime cfg ~f:(fun rt -> repl rt "default-agent")

let term_chat =
  let open Cmdliner.Term in
  const cmd_chat
  $ provider_arg $ api_key_arg $ api_base $ model_name
  $ persistence_arg $ db_uri $ temperature_arg $ system_prompt $ max_iterations
  $ max_tokens_arg $ top_p_arg $ no_parallel_tools

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
    persistence_opt db_uri_opt temp_opt prompt_opt max_iter
    max_tokens_opt top_p_opt no_parallel_tools =
  let cfg = require_config () in
  let cfg = merge_config cfg provider_opt api_key_opt api_base_opt model_opt
              persistence_opt db_uri_opt temp_opt prompt_opt max_iter
              max_tokens_opt top_p_opt no_parallel_tools in
  setup_runtime cfg ~f:(fun rt ->
    match Runtime.invoke rt ~agent_id:"default-agent" ~message:question
        ~on_tool_event:(make_tool_event_callback ())
        ~on_chunk:(Some stream_print_chunk) () with
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
  $ max_tokens_arg $ top_p_arg $ no_parallel_tools

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
    ; ("accept", "application/vnd.github+json") ]

let http_get_string client ~sw uri =
  let resp, body =
    Cohttp_eio.Client.get client ~sw ~headers:upgrade_headers uri in
  let status = resp.Http.Response.status |> Cohttp.Code.code_of_status in
  if status <> 200 then
    Error (Printf.sprintf "HTTP %d for %s" status (Uri.to_string uri))
  else
    let s =
      Eio.Buf_read.parse_exn ~max_size:(20 * 1024 * 1024)
        Eio.Buf_read.take_all body in
    Ok s

let http_download_to_file client ~sw uri dest_path =
  let resp, body =
    Cohttp_eio.Client.get client ~sw ~headers:upgrade_headers uri in
  let status = resp.Http.Response.status |> Cohttp.Code.code_of_status in
  if status <> 200 then
    Error (Printf.sprintf "HTTP %d for %s" status (Uri.to_string uri))
  else
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
     let api_uri =
       Uri.of_string
         "https://api.github.com/repos/jcz2020/par/releases/latest" in
     (match http_get_string client ~sw api_uri with
      | Error e ->
        Printf.eprintf "Failed to fetch release info: %s\n" e;
        exit 1
      | Ok body ->
        let json = Yojson.Safe.from_string body in
        let tag =
          (try Yojson.Safe.Util.(json |> member "tag_name" |> to_string)
           with _ ->
             Printf.eprintf
               "Failed to parse release info: missing tag_name\n";
             exit 1) in
        let latest = strip_v_prefix tag in
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
          let chk_uri = Uri.of_string
            (Printf.sprintf
               "https://github.com/jcz2020/par/releases/download/%s/sha512-checksums.txt"
               ver_tag) in
          Printf.printf "Downloading %s for %s...\n" latest platform;
          flush stdout;
          let tmpdir =
            Filename.get_temp_dir_name () ^
            "/par-upgrade-" ^ string_of_int (Unix.getpid ()) in
          (try Unix.mkdir tmpdir 0o700
           with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          let bin_path = tmpdir ^ "/" ^ asset_name in
          let chk_path = tmpdir ^ "/sha512-checksums.txt" in
          (match http_download_to_file client ~sw bin_uri bin_path with
           | Error e ->
             Printf.eprintf "Download failed: %s\n" e;
             exit 1
           | Ok () ->
             (match http_download_to_file client ~sw chk_uri chk_path with
              | Error e ->
                Printf.eprintf "Checksums download failed: %s\n" e;
                exit 1
              | Ok () ->
                let ic = open_in chk_path in
                let n = in_channel_length ic in
                let buf = Bytes.create n in
                really_input ic buf 0 n;
                close_in ic;
                let chk_content = Bytes.unsafe_to_string buf in
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
(* Custom help renderer                                                       *)
(* -------------------------------------------------------------------------- *)

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
  opt "--persistence BACKEND"    "sqlite|postgres (default: sqlite)";
  opt "--db-uri URI"             "PostgreSQL connection URI";
  opt "--no-parallel-tools"      "Disable parallel tool execution";
  section "EXAMPLES";
  Printf.printf "  %s\n" (dim "par                                    # start REPL");
  Printf.printf "  %s\n" (dim "par ask \"what is OCaml?\"            # single shot");
  Printf.printf "  %s\n" (dim "par config                            # setup wizard");
  Printf.printf "  %s\n" (dim "par update                            # self-update");
  Printf.printf "\n%s\n" (dim "Read the docs: https://github.com/jcz2020/par")

(* -------------------------------------------------------------------------- *)
(* Root command                                                               *)
(* -------------------------------------------------------------------------- *)

let cmd =
  let open Cmdliner.Cmd in
  group ~default:term_chat
    (info "par" ~version:Par.Version.version
       ~doc:"P-A-R: Programmable Agent Runtime — run 'par' to start REPL, 'par config' to configure, 'par ask \"question\"' for one-shot")
    [
      v info_config term_config;
      v info_ask term_ask;
      v info_update term_update;
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
