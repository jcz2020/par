open Par
open Types

(* test/test_cli_dispatch.ml — PAR-z23 / B.1.

   Coverage: the provider-construction mechanism that bin/main.ml's
   `make_llm_service` uses for its `Ollama and `Custom _ branches. The
   fix routes both providers through Openai_provider.create with a
   localhost / user-supplied base_url (Ollama exposes an OpenAI-compatible
   /v1 endpoint; Custom endpoints are by definition OpenAI-compatible).

   make_llm_service itself lives in bin/main.ml, which is the executable
   entry point — not exported as a library. So we cannot call it directly
   from this test. Instead we pin the underlying contract: that
   Openai_provider.create accepts the exact provider_config shape that the
   new branches construct, and returns Ok. If a future change to
   Openai_provider.create rejected the localhost base_url or required a
   different config shape, these tests would catch it before `par ask`
   could regress to a Match_failure at runtime. *)

let error_category_name = function
  | Invalid_input s -> "Invalid_input(" ^ s ^ ")"
  | Internal s -> "Internal(" ^ s ^ ")"
  | External_failure s -> "External_failure(" ^ s ^ ")"
  | Permission_denied s -> "Permission_denied(" ^ s ^ ")"
  | Rate_limited -> "Rate_limited"
  | Timeout -> "Timeout"
  | Embedding_unsupported -> "Embedding_unsupported"

(* Mirrors bin/main.ml make_llm_service `Ollama branch (api_key_val
   passed through verbatim; Ollama ignores it). *)
let ollama_cfg api_key_val : llm_provider_config =
  Openai {
    api_key = api_key_val;
    base_url = Some "http://localhost:11434/v1";
    organization = None;
    embedding_model = None;
  }

(* Mirrors bin/main.ml make_llm_service `Custom _ branch: caller picks
   the base_url; api_key flows through from config. *)
let custom_cfg ~api_key ~base_url : llm_provider_config =
  Openai {
    api_key;
    base_url = Some base_url;
    organization = None;
    embedding_model = None;
  }

let test_ollama_dispatch_builds_provider () =
  match Openai_provider.create (ollama_cfg "ollama-placeholder") with
  | Ok _ -> ()
  | Error e ->
    Alcotest.failf "Ollama dispatch should build an Openai_provider, got %s"
      (error_category_name e)

let test_ollama_dispatch_accepts_empty_api_key_placeholder () =
  (* make_llm_service passes api_key_val through; Ollama ignores it. But
     Openai_provider.create rejects empty api_key, so the CLI layer must
     feed it a non-empty placeholder. Document that contract here. *)
  (match Openai_provider.create (ollama_cfg "") with
   | Ok _ -> Alcotest.fail "empty api_key should be rejected by Openai_provider.create"
   | Error _ -> ());
  match Openai_provider.create (ollama_cfg "ollama") with
  | Ok _ -> ()
  | Error e ->
    Alcotest.failf "non-empty placeholder api_key should build provider, got %s"
      (error_category_name e)

let test_custom_dispatch_builds_provider_with_user_base_url () =
  match Openai_provider.create
    (custom_cfg ~api_key:"sk-custom" ~base_url:"http://my-endpoint.local/v1")
  with
  | Ok _ -> ()
  | Error e ->
    Alcotest.failf "Custom dispatch should build Openai_provider with user base_url, got %s"
      (error_category_name e)

let test_custom_dispatch_rejects_empty_api_key () =
  (* If the user runs `par --provider custom ...` without --api-key, the
     dispatch layer exits with a clear error rather than building a
     provider that 401s at request time. Pin that here. *)
  match Openai_provider.create
    (custom_cfg ~api_key:"" ~base_url:"http://my-endpoint.local/v1")
  with
  | Ok _ -> Alcotest.fail "empty api_key must be rejected"
  | Error _ -> ()

let () =
  Alcotest.run "cli_dispatch (PAR-z23 B.1)" [
    "ollama_dispatch", [
      Alcotest.test_case "builds Openai_provider with localhost /v1 base_url" `Quick
        test_ollama_dispatch_builds_provider;
      Alcotest.test_case "non-empty placeholder api_key required" `Quick
        test_ollama_dispatch_accepts_empty_api_key_placeholder;
    ];
    "custom_dispatch", [
      Alcotest.test_case "builds Openai_provider with user-supplied base_url" `Quick
        test_custom_dispatch_builds_provider_with_user_base_url;
      Alcotest.test_case "rejects empty api_key" `Quick
        test_custom_dispatch_rejects_empty_api_key;
    ];
  ]
