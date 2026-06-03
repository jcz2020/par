open Par

type span = {
  name : string; kind : string; start_time : string; end_time : string;
  attributes : (string * Yojson.Safe.t) list; status : string;
}

let spans : span list ref = ref []

let iso t =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02.3fZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min (float tm.tm_sec)

let trace () =
  let id = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
  let js = `Assoc [("traceId", `String id); ("spans", `List (List.map (fun s ->
    `Assoc [("name", `String s.name); ("kind", `String s.kind);
            ("startTime", `String s.start_time); ("endTime", `String s.end_time);
            ("attributes", `Assoc s.attributes); ("status", `Assoc [("code", `String s.status)])]
  ) !spans))] in
  Printf.printf "%s\n" (Yojson.Safe.pretty_to_string js)

let create_tracing_middleware () =
  let lsp = ref [] and tsp = ref [] in
  let bl _ =
    let t = Unix.gettimeofday () |> iso in
    lsp := { name = "llm.call"; kind = "CLIENT"; start_time = t; end_time = ""; attributes = []; status = "OK" } :: !lsp;
    None
  in
  let al (r : Types.llm_response) =
    let t = Unix.gettimeofday () |> iso in
    match !lsp with
    | [] -> None
    | s :: r' ->
      let a = [("llm.model", `String r.Types.model);
              ("llm.finish_reason", `String (match r.Types.finish_reason with Types.Stop -> "stop" | Types.Tool_calls -> "tool_calls" | Types.Max_tokens -> "max_tokens" | Types.Content_filter -> "content_filter"));
              ("llm.usage.prompt_tokens", `Int r.Types.usage.Types.prompt_tokens);
              ("llm.usage.completion_tokens", `Int r.Types.usage.Types.completion_tokens);
              ("llm.usage.total_tokens", `Int r.Types.usage.Types.total_tokens)] in
      spans := { s with end_time = t; attributes = a } :: !spans;
      lsp := r';
      None
  in
  let bt (c : Types.tool_call) =
    let t = Unix.gettimeofday () |> iso in
    tsp := { name = "tool.invoke"; kind = "CLIENT"; start_time = t; end_time = ""; attributes = [("tool.name", `String c.Types.name)]; status = "OK" } :: !tsp;
    None
  in
  let at ((c, r) : Types.tool_call * Types.handler_result) =
    let t = Unix.gettimeofday () |> iso in
    match !tsp with
    | [] -> None
    | s :: r' ->
      let a = match r with
        | Types.Success j -> [("tool.name", `String c.Types.name); ("tool.result", `String "success"); ("tool.output", j)]
        | Types.Error e ->
          let ek = match e.category with
            | Types.Timeout -> "timeout"
            | Types.Invalid_input _ -> "invalid_input"
            | Types.External_failure _ -> "external_failure"
            | Types.Rate_limited -> "rate_limited"
            | Types.Permission_denied _ -> "permission_denied"
            | Types.Internal _ -> "internal" in
          [("tool.name", `String c.Types.name); ("tool.result", `String "error"); ("error.kind", `String ek)] in
      spans := { s with end_time = t; attributes = a } :: !spans;
      tsp := r';
      None
  in
  { Types.name = "otel_tracing"; on_before_llm = Some bl; on_after_llm = Some al;
    on_before_tool = Some bt; on_after_tool = Some at; on_error = None }

let mock_llm rs =
  let i = ref 0 in
  { Types.complete_fn = (fun _ _tools _ -> incr i; Ok (List.nth rs (!i - 1)));
    stream_fn = (fun _ _tools _ _ _ -> Ok { final_usage = { prompt_tokens = 10; completion_tokens = 5; total_tokens = 15 }; finish_reason = Types.Stop; chunks_received = 0 });
    close_fn = ignore }

let () =
  let rs = [
    { Types.text = None; tool_calls = Some [{ Types.id = "c1"; name = "echo"; arguments = `Null }]; finish_reason = Types.Tool_calls; usage = { prompt_tokens = 42; completion_tokens = 8; total_tokens = 50 }; model = "gpt-4" };
    { text = Some "Hello, world!"; tool_calls = None; finish_reason = Types.Stop; usage = { prompt_tokens = 50; completion_tokens = 128; total_tokens = 178 }; model = "gpt-4" } ] in
  let echo_desc = { Types.name = "echo"; description = "Echo back input"; input_schema = `Null;
                permission = Types.Allow; timeout = None; concurrency_limit = None; on_update = None } in
  let echo_handler = (fun j _ -> Types.Success (`String ("Echo: " ^ Yojson.Safe.to_string j))) in
  let agent = { Types.id = "demo"; system_prompt = "You are a helpful assistant.";
                system_prompt_template = None;
                model = { provider = `Openai; model_name = "gpt-4"; api_base = None; temperature = 0.7; max_tokens = None; top_p = None; stop_sequences = None };
                tools = [ echo_desc ]; max_iterations = 5; middleware = [ create_tracing_middleware () ];
                retry_policy = None; context_strategy = None; resource_quota = None } in
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let tok = { Types.switch = sw; cancelled = false } in
    let reg = Tool_registry.create () in
    ignore (Tool_registry.register reg echo_desc echo_handler : (unit, [ `Duplicate_tool of string ]) result);
    match Engine.run_agent tok agent "Hello" (mock_llm rs) reg with
    | Ok r -> Printf.printf "Agent: %s\n" (match r.Types.text with Some t -> t | None -> "no text")
    | Error e -> Printf.eprintf "Error: %s\n" (match e with
      | Types.Internal s -> s
      | Types.Invalid_input s -> s
      | Types.External_failure s -> s
      | Types.Timeout -> "timeout"
      | Types.Rate_limited -> "rate_limited"
      | Types.Permission_denied s -> s
    )));
  trace ()