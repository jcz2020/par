open Par
open Types

let api_key =
  try Sys.getenv "OPENAI_API_KEY"
  with Not_found -> Printf.eprintf "Set OPENAI_API_KEY\n"; exit 1

let base_url =
  try Some (Sys.getenv "OPENAI_BASE_URL")
  with Not_found -> Some "https://api.minimaxi.com/v1"

let model_name = "MiniMax-M3"

let err_str (e : error_category) = match e with
  | (Timeout : error_category) -> "Timeout"
  | Invalid_input s -> "Invalid_input: " ^ s
  | External_failure s -> "External_failure: " ^ s
  | Rate_limited -> "Rate_limited"
  | Permission_denied s -> "Permission_denied: " ^ s
  | Internal s -> "Internal: " ^ s

let dummy_model : model_config =
  { provider = `Openai; model_name; api_base = base_url;
    temperature = 0.0; max_tokens = Some 500; top_p = None; stop_sequences = None }

let make_llm net cfg : llm_service = {
  complete_fn = (fun model tools conv ->
    (match Openai_provider.create cfg with
     | Error e -> Error e
     | Ok t -> Openai_provider.set_network t net; Openai_provider.complete t model tools conv));
  stream_fn = (fun _ _ _ _ _ -> Error (Internal "no streaming"));
  close_fn = (fun () -> ());
  complete_structured_fn = None;
}

let check_schema schema value =
  match Validation.validate_tool_input_result schema value with
  | Ok () -> true | Error _ -> false

let run_test net cfg ~label ~prompt ~schema =
  let llm = make_llm net cfg in
  let token = Eio.Switch.run (fun sw -> Cancellation.create_token sw) in
  let agent = {
    id = "test"; system_prompt = "You are a helpful assistant.";
    system_prompt_template = None; model = dummy_model; tools = [];
    max_iterations = 5; middleware = []; retry_policy = None;
    context_strategy = None; resource_quota = None;
  } in
  match Engine.run_structured ~max_repair_attempts:3 ~response_schema:schema
      llm token agent prompt with
  | Ok result ->
    let sv = check_schema schema result.value in
    Printf.printf "  %-16s OK  attempts=%d valid=%b value=%s\n"
      label result.attempts sv (Yojson.Safe.to_string result.value);
    flush stdout; (true, result.attempts, sv)
  | Error (e, _) ->
    Printf.printf "  %-16s FAIL err=%s\n" label (err_str e);
    flush stdout; (false, 0, false)

let () =
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run (fun env ->
    let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
    let cfg = Openai { api_key; base_url; organization = None } in
    Printf.printf "=== v0.4.8 Structured Output Validation (20 rounds x 6 tests = 120 total) ===\n\n";
    flush stdout;

    let s_country = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [("type", `String "string")]);
        ("capital", `Assoc [("type", `String "string")]);
      ]);
      ("required", `List [`String "name"; `String "capital"]);
    ] in
    let s_media = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [("type", `String "string")]);
        ("year", `Assoc [("type", `String "integer")]);
        ("rating", `Assoc [("type", `String "number")]);
      ]);
      ("required", `List [`String "title"; `String "year"]);
    ] in
    let s_array = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("items", `Assoc [("type", `String "array")]);
        ("count", `Assoc [("type", `String "integer")]);
      ]);
      ("required", `List [`String "items"; `String "count"]);
    ] in
    let s_enum = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("word", `Assoc [("type", `String "string")]);
        ("category", `Assoc [("type", `String "string"); ("enum", `List [`String "noun"; `String "verb"; `String "adjective"])]);
      ]);
      ("required", `List [`String "word"; `String "category"]);
    ] in

    let tests = [
      ("country-fr", "Tell me about France in JSON.", s_country);
      ("country-jp", "Tell me about Japan in JSON.", s_country);
      ("movie", "Recommend a sci-fi movie in JSON.", s_media);
      ("book", "Recommend a programming book in JSON.", s_media);
      ("todo", "Give me a 3-item todo list in JSON.", s_array);
      ("word", "Classify the word 'running' in JSON.", s_enum);
    ] in

    let ok = ref 0 and fail = ref 0 and sv = ref 0 and att = ref 0 in
    let stats = Hashtbl.create 16 in
    for r = 1 to 20 do
      Printf.printf "--- Round %d/20 ---\n" r; flush stdout;
      List.iter (fun (label, prompt, schema) ->
        let (o, a, s) = run_test net cfg ~label ~prompt ~schema in
        if o then (incr ok; if s then incr sv; att := !att + a) else incr fail;
        let (n, ss, aa) = try Hashtbl.find stats label with Not_found -> (0,0,0) in
        Hashtbl.replace stats label (n + (if o then 1 else 0), ss + (if s then 1 else 0), aa + a)
      ) tests;
      Printf.printf "\n"; flush stdout
    done;

    let tot = !ok + !fail in
    Printf.printf "=== SUMMARY ===\n";
    Printf.printf "Total: %d  Success: %d (%.1f%%)  Fail: %d\n" tot !ok (100.0 *. float !ok /. float tot) !fail;
    Printf.printf "Schema valid: %d/%d (%.1f%%)\n" !sv !ok (if !ok > 0 then 100.0 *. float !sv /. float !ok else 0.0);
    Printf.printf "Avg attempts (on success): %.1f\n" (if !ok > 0 then float !att /. float !ok else 0.0);
    Printf.printf "\nPer-test:\n";
    Hashtbl.iter (fun label (o, s, a) ->
      Printf.printf "  %-14s %2d/20 ok  %2d valid  avg_att=%.1f\n"
        label o s (if o > 0 then float a /. float o else 0.0)
    ) stats;
    flush stdout)
