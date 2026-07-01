(* parse_usage is private — test indirectly via parse_stream_delta. *)

open Par
open Types

let make_chunk ?usage () =
  let base =
    {|{"choices":[{"delta":{"content":"hi"},"finish_reason":null}]}|} in
  let json = Yojson.Safe.from_string base in
  match usage with
  | None -> json
  | Some u ->
    let u_json = Yojson.Safe.from_string u in
    `Assoc (List.map (function
      | "choices", _ as c -> c
      | k, v -> (k, v)
    ) (match json with `Assoc l -> l | _ -> []) @ [ "usage", u_json ])

let get_usage chunk =
  let (_, _, _, usage_opt) = Openai_provider.parse_stream_delta chunk in
  usage_opt

let check_field label expected actual =
  Alcotest.(check int) label expected actual

(* 1. prompt_tokens_details.cached_tokens=42 → cached_tokens=42 *)
let test_cached_tokens_present () =
  let chunk = make_chunk ~usage:
    {|{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150,
       "prompt_tokens_details":{"cached_tokens":42}}|} () in
  match get_usage chunk with
  | None -> Alcotest.fail "expected usage_stats, got None"
  | Some u ->
    check_field "prompt_tokens" 100 u.prompt_tokens;
    check_field "completion_tokens" 50 u.completion_tokens;
    check_field "total_tokens" 150 u.total_tokens;
    check_field "cached_tokens" 42 u.cached_tokens

(* 2. No prompt_tokens_details → cached_tokens=0 (default) *)
let test_no_prompt_tokens_details () =
  let chunk = make_chunk ~usage:
    {|{"prompt_tokens":80,"completion_tokens":20,"total_tokens":100}|} () in
  match get_usage chunk with
  | None -> Alcotest.fail "expected usage_stats, got None"
  | Some u ->
    check_field "cached_tokens default" 0 u.cached_tokens

(* 3. prompt_tokens_details present but no cached_tokens field → 0 *)
let test_empty_prompt_tokens_details () =
  let chunk = make_chunk ~usage:
    {|{"prompt_tokens":80,"completion_tokens":20,"total_tokens":100,
       "prompt_tokens_details":{}}|} () in
  match get_usage chunk with
  | None -> Alcotest.fail "expected usage_stats, got None"
  | Some u ->
    check_field "cached_tokens missing field" 0 u.cached_tokens

(* 4. OpenAI never sets cache_creation/cache_read → always 0 *)
let test_anthropic_fields_always_zero () =
  let chunk = make_chunk ~usage:
    {|{"prompt_tokens":200,"completion_tokens":100,"total_tokens":300,
       "prompt_tokens_details":{"cached_tokens":15}}|} () in
  match get_usage chunk with
  | None -> Alcotest.fail "expected usage_stats, got None"
  | Some u ->
    check_field "cache_creation_input_tokens" 0 u.cache_creation_input_tokens;
    check_field "cache_read_input_tokens" 0 u.cache_read_input_tokens

(* 5. Full roundtrip: all 6 fields correctly parsed *)
let test_full_usage_roundtrip () =
  let chunk = make_chunk ~usage:
    {|{"prompt_tokens":500,"completion_tokens":250,"total_tokens":750,
       "prompt_tokens_details":{"cached_tokens":100}}|} () in
  match get_usage chunk with
  | None -> Alcotest.fail "expected usage_stats, got None"
  | Some u ->
    check_field "prompt_tokens" 500 u.prompt_tokens;
    check_field "completion_tokens" 250 u.completion_tokens;
    check_field "total_tokens" 750 u.total_tokens;
    check_field "cached_tokens" 100 u.cached_tokens;
    check_field "cache_creation_input_tokens" 0 u.cache_creation_input_tokens;
    check_field "cache_read_input_tokens" 0 u.cache_read_input_tokens

let () =
  Alcotest.run "OpenAI cached_tokens"
    [ ( "cached_tokens", [
        Alcotest.test_case "present=42"        `Quick test_cached_tokens_present;
        Alcotest.test_case "no details=0"      `Quick test_no_prompt_tokens_details;
        Alcotest.test_case "empty details=0"   `Quick test_empty_prompt_tokens_details;
        Alcotest.test_case "anthropic fields=0" `Quick test_anthropic_fields_always_zero;
        Alcotest.test_case "full roundtrip"     `Quick test_full_usage_roundtrip;
      ] ) ]
