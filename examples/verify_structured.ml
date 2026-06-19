open Par
open Types

let api_key =
  try Sys.getenv "OPENAI_API_KEY"
  with Not_found -> Printf.eprintf "Set OPENAI_API_KEY\n"; exit 1

let err_str (e : Types.error_category) = match e with
  | (Timeout : Types.error_category) -> "Timeout"
  | Invalid_input s -> "Invalid_input: " ^ s
  | External_failure s -> "External_failure: " ^ s
  | Types.Rate_limited -> "Rate_limited"
  | Permission_denied s -> "Permission_denied: " ^ s
  | Internal s -> "Internal: " ^ s
let base_url =
  try Some (Sys.getenv "OPENAI_BASE_URL")
  with Not_found -> Some "https://api.minimaxi.com/v1"

let model_name = "MiniMax-M2.7"

let test_schema : Yojson.Safe.t =
  `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("name", `Assoc [("type", `String "string")]);
      ("capital", `Assoc [("type", `String "string")]);
      ("population", `Assoc [("type", `String "integer")]);
    ]);
    ("required", `List [`String "name"; `String "capital"]);
  ]

let test_prompt = "Tell me about France."

let dummy_model : model_config =
  { provider = `Openai; model_name; api_base = base_url;
    temperature = 0.0; max_tokens = Some 500; top_p = None; stop_sequences = None }

let make_conv ~system ~user : conversation =
  let sys = { role = System; content = Some system; tool_calls = None; tool_call_id = None; name = None } in
  let usr = { role = User; content = Some user; tool_calls = None; tool_call_id = None; name = None } in
  { messages = [sys; usr]; metadata = [] }

let sep title = Printf.printf "\n%s\n%s\n%s\n" (String.make 60 '=') title (String.make 60 '=')

let () =
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run (fun env ->
    let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
    let cfg = Openai { api_key; base_url; organization = None } in

    sep "PATH 1: Native complete_structured (response_format)";
    (match Openai_provider.create cfg with
     | Error e -> Printf.eprintf "  Provider FAILED: %s\n" (err_str e)
     | Ok t ->
       Openai_provider.set_network t net;
       let conv = make_conv ~system:"You are a geography assistant." ~user:test_prompt in
       Printf.printf "  Calling complete_structured...\n"; flush stdout;
       (match Openai_provider.complete_structured t dummy_model [] conv test_schema with
        | Ok resp ->
          Printf.printf "  SUCCESS\n  text: %s\n" (Option.value resp.text ~default:"<none>");
          (match resp.text with
           | Some text ->
             (match Json_extract.extract_json_from_text text with
              | Ok json -> Printf.printf "  Parsed: %s\n" (Yojson.Safe.pretty_to_string json)
              | Error e -> Printf.printf "  Parse FAILED: %s\n" e)
           | None -> ())
        | Error e -> Printf.eprintf "  FAILED: %s\n" (err_str e)));

    sep "PATH 2: Fallback (prompt directive)";
    (match Openai_provider.create cfg with
     | Error e -> Printf.eprintf "  Provider FAILED: %s\n" (err_str e)
     | Ok t ->
       Openai_provider.set_network t net;
       let dir = Printf.sprintf "Respond ONLY with JSON matching: %s" (Yojson.Safe.to_string test_schema) in
       let conv = make_conv ~system:("Geography assistant. " ^ dir) ~user:test_prompt in
       Printf.printf "  Calling complete (fallback)...\n"; flush stdout;
       (match Openai_provider.complete t dummy_model [] conv with
        | Ok resp ->
          Printf.printf "  SUCCESS\n  raw: %s\n" (Option.value resp.text ~default:"<none>");
          (match resp.text with
           | Some text ->
             (match Json_extract.extract_json_from_text text with
              | Ok json -> Printf.printf "  Extracted: %s\n" (Yojson.Safe.pretty_to_string json)
              | Error e -> Printf.printf "  Extract FAILED: %s\n" e)
           | None -> ())
        | Error e -> Printf.eprintf "  FAILED: %s\n" (err_str e)));

    sep "PATH 3: Engine.run_structured (full repair loop)";
    let llm_counter = ref 0 in
    let llm : Types.llm_service = {
      complete_fn = (fun model tools conv ->
        incr llm_counter;
        (match Openai_provider.create cfg with
         | Error e -> Error e
         | Ok t -> Openai_provider.set_network t net; Openai_provider.complete t model tools conv));
      stream_fn = (fun _ _ _ _ _ -> Error (Types.Internal "no streaming"));
      close_fn = (fun () -> ());
      complete_structured_fn = None;
    } in
    let token = Eio.Switch.run (fun sw -> Cancellation.create_token sw) in
    let agent = {
      id = "test"; system_prompt = "Geography assistant."; system_prompt_template = None;
      model = dummy_model; tools = []; max_iterations = 5; middleware = [];
      retry_policy = None; context_strategy = None; resource_quota = None;
    } in
    Printf.printf "  Calling run_structured (fallback path, max 3 attempts)...\n"; flush stdout;
    (match Engine.run_structured ~max_repair_attempts:3 ~response_schema:test_schema
        llm token agent test_prompt with
     | Ok result ->
       Printf.printf "  SUCCESS (attempts=%d, LLM_calls=%d)\n" result.attempts !llm_counter;
       Printf.printf "  value: %s\n" (Yojson.Safe.pretty_to_string result.value)
     | Error (e, _) ->
       Printf.eprintf "  FAILED (LLM_calls=%d): %s\n" !llm_counter (err_str e));

    sep "DONE"; flush stdout)
