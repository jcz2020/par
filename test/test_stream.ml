open Par
open Types

let () = Mirage_crypto_rng_unix.use_default ()

let show_error = function
  | Invalid_input s -> "Invalid input: " ^ s
  | External_failure s -> "External: " ^ s
  | Rate_limited -> "Rate limited"
  | Timeout -> "Timeout"
  | Permission_denied s -> "Permission: " ^ s
  | Internal s -> "Internal: " ^ s
  | Embedding_unsupported -> "Embedding_unsupported"

let test_openai_stream () =
  let api_key = try Sys.getenv "ZAI_API_KEY" with Not_found -> "" in
  if api_key = "" then (Printf.printf "SKIP: ZAI_API_KEY not set\n"; exit 0);
  Eio_main.run @@ fun env ->
  let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  let t = match Openai_provider.create (Openai {
      api_key; base_url = Some "https://open.bigmodel.cn/api/paas/v4"; organization = None; embedding_model = None; prompt_cache_key = None
    }) with
    | Ok t -> Openai_provider.set_network t net; t
    | Error e -> Alcotest.fail ("create: " ^ show_error e)
  in
  let llm : llm_service = {
    complete_fn = (fun mc tools conv -> Openai_provider.complete t mc tools conv);
    stream_fn = (fun mc tools conv sc cb -> Openai_provider.stream t mc tools conv sc cb);
    close_fn = (fun _ -> ());
    complete_structured_fn = None;
    list_models_fn = None;
  supports_native_tools_fn = None;
  context_window_fn = None; cache_control_fn = None;
  } in
  let model = {
    provider = `Openai; model_name = "glm-4-flash"; api_base = None;
    temperature = 0.7; max_tokens = Some 100; top_p = None; stop_sequences = None
  } in
  let conv : conversation = {
    messages = [{ role = User; content_blocks = [Text_block { text = "Say hello."; cache_control = None }]; tool_calls = None; tool_call_id = None; name = None }];
    metadata = []
  } in
  let chunks = ref 0 in
  let texts = Buffer.create 128 in
  let callback = function
    | Text_delta { text } -> Buffer.add_string texts text; incr chunks
    | Done _ -> incr chunks
    | _ -> incr chunks
  in
  match llm.stream_fn model [] conv { chunk_timeout = 30.0; total_timeout = None; buffer_size = 4096 } callback with
  | Ok stats ->
    Alcotest.(check bool "chunks > 0" true (!chunks > 0));
    Alcotest.(check bool "has text" true (String.length (Buffer.contents texts) > 0));
    Printf.printf "Stream: %d chunks, finish=%s, text=%s\n"
      stats.chunks_received
      (match stats.finish_reason with Stop -> "stop" | _ -> "other")
      (Buffer.contents texts)
  | Error e ->
    Alcotest.fail ("stream: " ^ show_error e)

let () =
  Alcotest.run "SSE Stream" [
    "openai_stream", [Alcotest.test_case "glm-4-flash stream" `Quick test_openai_stream]
  ]
