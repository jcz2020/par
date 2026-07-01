(* test/test_stable_volatile_prompts.ml — v0.6.5
   Tests stable_prompt/volatile_prompt constructors, zone_of accessor,
   prompt_text extractor, and the B.4 make_agent cache_strategy zone check
   (volatile + With_cache_of → hard-fail Error). *)

open Par
open Par.Types

let valid_model : Types.model_config = {
  Types.provider = `Openai;
  model_name = "gpt-4";
  api_base = None;
  temperature = 0.7;
  max_tokens = None;
  top_p = None;
  stop_sequences = None;
}

let zone_tag_testable =
  let pp fmt z = Format.pp_print_string fmt
    (match z with Zone_stable -> "Zone_stable" | Zone_volatile -> "Zone_volatile") in
  Alcotest.testable pp (=)

let cache_strategy_testable =
  let pp fmt cs = Format.pp_print_string fmt
    (match cs with
     | No_caching -> "No_caching"
     | With_cache_of `Five_min -> "With_cache_of(`Five_min)"
     | With_cache_of `One_hour -> "With_cache_of(`One_hour)") in
  Alcotest.testable pp (=)

(* ─── Constructors ─────────────────────────────────────────────── *)

let test_stable_prompt_constructor () =
  let sp = stable_prompt "hello" in
  Alcotest.(check string) "sp_raw" "hello" sp.sp_raw;
  Alcotest.(check zone_tag_testable) "sp_zone" Zone_stable sp.sp_zone

let test_volatile_prompt_constructor () =
  let sp = volatile_prompt "dynamic" in
  Alcotest.(check string) "sp_raw" "dynamic" sp.sp_raw;
  Alcotest.(check zone_tag_testable) "sp_zone" Zone_volatile sp.sp_zone

let test_stable_prompt_empty () =
  let sp = stable_prompt "" in
  Alcotest.(check string) "empty raw" "" sp.sp_raw;
  Alcotest.(check zone_tag_testable) "empty stable zone" Zone_stable sp.sp_zone

let test_volatile_prompt_empty () =
  let sp = volatile_prompt "" in
  Alcotest.(check string) "empty raw" "" sp.sp_raw;
  Alcotest.(check zone_tag_testable) "empty volatile zone" Zone_volatile sp.sp_zone

(* ─── Accessors ───────────────────────────────────────────────── *)

let test_prompt_text_extracts_raw () =
  Alcotest.(check string) "stable text" "hello" (prompt_text (stable_prompt "hello"));
  Alcotest.(check string) "volatile text" "world" (prompt_text (volatile_prompt "world"))

let test_zone_of_returns_correct_tag () =
  Alcotest.(check zone_tag_testable) "stable" Zone_stable (zone_of (stable_prompt "x"));
  Alcotest.(check zone_tag_testable) "volatile" Zone_volatile (zone_of (volatile_prompt "x"))

(* ─── make_agent without cache_strategy: zone preserved ───────── *)

let test_make_agent_stable_prompt_zone_preserved () =
  match Runtime.make_agent
    ~id:"a" ~system_prompt:(stable_prompt "hello") ~model:valid_model () with
  | Ok agent ->
    Alcotest.(check zone_tag_testable) "stable preserved"
      Zone_stable (zone_of agent.system_prompt)
  | Error e -> Alcotest.failf "expected Ok, got: %s"
      (match e with Invalid_input m -> m | _ -> "other")

let test_make_agent_volatile_prompt_zone_preserved () =
  match Runtime.make_agent
    ~id:"a" ~system_prompt:(volatile_prompt "hello") ~model:valid_model () with
  | Ok agent ->
    Alcotest.(check zone_tag_testable) "volatile preserved"
      Zone_volatile (zone_of agent.system_prompt)
  | Error e -> Alcotest.failf "expected Ok, got: %s"
      (match e with Invalid_input m -> m | _ -> "other")

(* ─── B.4 construction-time check: cache_strategy vs zone ─────── *)

let test_make_agent_stable_keeps_cache_strategy () =
  match Runtime.make_agent
    ~id:"a"
    ~system_prompt:(stable_prompt "hello")
    ~cache_strategy:(With_cache_of `Five_min)
    ~model:valid_model () with
  | Ok agent ->
    Alcotest.(check cache_strategy_testable) "stable + With_cache_of → kept"
      (With_cache_of `Five_min) agent.cache_strategy
  | Error e -> Alcotest.failf "expected Ok, got: %s"
      (match e with Invalid_input m -> m | _ -> "other")

let test_make_agent_volatile_hard_fails_cache_strategy () =
  match Runtime.make_agent
    ~id:"a"
    ~system_prompt:(volatile_prompt "dynamic")
    ~cache_strategy:(With_cache_of `Five_min)
    ~model:valid_model () with
  | Ok _ -> Alcotest.fail "expected Error (hard-fail), got Ok"
  | Error (Invalid_input _) -> ()
  | Error _ -> Alcotest.fail "wrong error type"

let test_make_agent_volatile_hard_fails_one_hour () =
  match Runtime.make_agent
    ~id:"a"
    ~system_prompt:(volatile_prompt "dynamic")
    ~cache_strategy:(With_cache_of `One_hour)
    ~model:valid_model () with
  | Ok _ -> Alcotest.fail "expected Error (hard-fail), got Ok"
  | Error (Invalid_input _) -> ()
  | Error _ -> Alcotest.fail "wrong error type"

let test_make_agent_stable_keeps_one_hour () =
  match Runtime.make_agent
    ~id:"a"
    ~system_prompt:(stable_prompt "static")
    ~cache_strategy:(With_cache_of `One_hour)
    ~model:valid_model () with
  | Ok agent ->
    Alcotest.(check cache_strategy_testable) "stable + One_hour → kept"
      (With_cache_of `One_hour) agent.cache_strategy
  | Error e -> Alcotest.failf "expected Ok, got: %s"
      (match e with Invalid_input m -> m | _ -> "other")

let test_make_agent_no_caching_unchanged_regardless_of_zone () =
  match Runtime.make_agent
    ~id:"a"
    ~system_prompt:(volatile_prompt "dynamic")
    ~cache_strategy:No_caching
    ~model:valid_model () with
  | Ok agent ->
    Alcotest.(check cache_strategy_testable) "volatile + No_caching → No_caching"
      No_caching agent.cache_strategy
  | Error e -> Alcotest.failf "expected Ok, got: %s"
      (match e with Invalid_input m -> m | _ -> "other")

(* ─── Default cache_strategy ──────────────────────────────────── *)

let test_make_agent_default_cache_strategy_is_no_caching () =
  match Runtime.make_agent
    ~id:"a" ~system_prompt:(stable_prompt "hello") ~model:valid_model () with
  | Ok agent ->
    Alcotest.(check cache_strategy_testable) "default = No_caching"
      No_caching agent.cache_strategy
  | Error e -> Alcotest.failf "expected Ok, got: %s"
      (match e with Invalid_input m -> m | _ -> "other")

(* ─── Runner ───────────────────────────────────────────────────── *)

let () =
  Alcotest.run "stable-volatile-prompts" [
    "constructors", [
      Alcotest.test_case "stable_prompt constructor" `Quick test_stable_prompt_constructor;
      Alcotest.test_case "volatile_prompt constructor" `Quick test_volatile_prompt_constructor;
      Alcotest.test_case "stable_prompt empty" `Quick test_stable_prompt_empty;
      Alcotest.test_case "volatile_prompt empty" `Quick test_volatile_prompt_empty;
    ];
    "accessors", [
      Alcotest.test_case "prompt_text extracts raw" `Quick test_prompt_text_extracts_raw;
      Alcotest.test_case "zone_of returns correct tag" `Quick test_zone_of_returns_correct_tag;
    ];
    "make-agent-zone-preserved", [
      Alcotest.test_case "stable zone preserved" `Quick test_make_agent_stable_prompt_zone_preserved;
      Alcotest.test_case "volatile zone preserved" `Quick test_make_agent_volatile_prompt_zone_preserved;
    ];
    "b4-cache-strategy-check", [
      Alcotest.test_case "stable + With_cache_of → kept" `Quick test_make_agent_stable_keeps_cache_strategy;
      Alcotest.test_case "volatile + With_cache_of → hard-fail" `Quick test_make_agent_volatile_hard_fails_cache_strategy;
      Alcotest.test_case "volatile + One_hour → hard-fail" `Quick test_make_agent_volatile_hard_fails_one_hour;
      Alcotest.test_case "stable + One_hour → kept" `Quick test_make_agent_stable_keeps_one_hour;
      Alcotest.test_case "No_caching unchanged regardless of zone" `Quick test_make_agent_no_caching_unchanged_regardless_of_zone;
    ];
    "defaults", [
      Alcotest.test_case "default cache_strategy is No_caching" `Quick test_make_agent_default_cache_strategy_is_no_caching;
    ];
  ]
