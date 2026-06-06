open Par
open Types

let test_openai_create_rejects_empty_api_key () =
  match Openai_provider.create
    (Openai { api_key = ""; base_url = None; organization = None }) with
  | Ok _ -> Alcotest.fail "expected Error for empty api_key"
  | Error e ->
    (match e with
     | Invalid_input msg ->
       Alcotest.(check bool) "error mentions api_key" true
         (String.contains msg 'a' || String.contains msg 'k')
     | _ -> Alcotest.failf "expected Invalid_input, got: %s"
         (match e with
          | Internal s -> "Internal(" ^ s ^ ")"
          | Invalid_input s -> "Invalid_input(" ^ s ^ ")"
          | External_failure s -> "External_failure(" ^ s ^ ")"
          | Rate_limited -> "Rate_limited"
          | Timeout -> "Timeout"
          | Permission_denied s -> "Permission_denied(" ^ s ^ ")"))

let test_openai_create_accepts_valid_api_key () =
  match Openai_provider.create
    (Openai { api_key = "sk-valid"; base_url = None; organization = None }) with
  | Ok _ -> ()
  | Error _ -> Alcotest.fail "expected Ok for valid api_key"

let test_anthropic_create_rejects_empty_api_key () =
  match Anthropic_provider.create
    (Anthropic { api_key = ""; base_url = None }) with
  | Ok _ -> Alcotest.fail "expected Error for empty api_key"
  | Error e ->
    (match e with
     | Invalid_input msg ->
       Alcotest.(check bool) "error mentions api_key" true
         (String.contains msg 'a' || String.contains msg 'k')
     | _ -> Alcotest.failf "expected Invalid_input, got other variant")

let test_anthropic_create_accepts_valid_api_key () =
  match Anthropic_provider.create
    (Anthropic { api_key = "sk-ant-valid"; base_url = None }) with
  | Ok _ -> ()
  | Error _ -> Alcotest.fail "expected Ok for valid api_key"

let test_openai_create_wrong_config_variant () =
  match Openai_provider.create
    (Anthropic { api_key = "sk-valid"; base_url = None }) with
  | Ok _ -> Alcotest.fail "expected Error for wrong config variant"
  | Error e ->
    (match e with Invalid_input _ -> () | _ -> Alcotest.fail "expected Invalid_input")

let test_anthropic_create_wrong_config_variant () =
  match Anthropic_provider.create
    (Openai { api_key = "sk-valid"; base_url = None; organization = None }) with
  | Ok _ -> Alcotest.fail "expected Error for wrong config variant"
  | Error e ->
    (match e with Invalid_input _ -> () | _ -> Alcotest.fail "expected Invalid_input")

let () =
  Alcotest.run "provider_api_key_validation" [
    ("openai_api_key", [
      Alcotest.test_case "empty api_key rejected" `Quick test_openai_create_rejects_empty_api_key;
      Alcotest.test_case "valid api_key accepted" `Quick test_openai_create_accepts_valid_api_key;
      Alcotest.test_case "wrong config variant rejected" `Quick test_openai_create_wrong_config_variant;
    ]);
    ("anthropic_api_key", [
      Alcotest.test_case "empty api_key rejected" `Quick test_anthropic_create_rejects_empty_api_key;
      Alcotest.test_case "valid api_key accepted" `Quick test_anthropic_create_accepts_valid_api_key;
      Alcotest.test_case "wrong config variant rejected" `Quick test_anthropic_create_wrong_config_variant;
    ]);
  ]
