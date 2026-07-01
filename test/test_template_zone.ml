(* test/test_template_zone.ml — v0.6.4
   Tests Template.classify_template_zone + zone propagation through
   effective_system_prompt. current_time is volatile (per-second drift);
   agent_id/runtime_id/available_tools are stable. Max-propagation rule:
   any volatile builtin → whole template volatile. *)

open Par
open Par.Types

(* ─── Fixtures ─────────────────────────────────────────────────── *)

let valid_model : Types.model_config = {
  Types.provider = `Openai;
  model_name = "gpt-4";
  api_base = None;
  temperature = 0.7;
  max_tokens = None;
  top_p = None;
  stop_sequences = None;
}

let mk_agent ?(system_prompt = stable_prompt "fallback") ?template () =
  let agent_base = {
    Types.id = "zone-test";
    system_prompt;
    system_prompt_template = template;
    model = valid_model;
    tools = [];
    max_iterations = 5;
    middleware = [];
    retry_policy = None;
    context_strategy = None;
    resource_quota = None;
    max_execution_time = None;
    tool_timeout = None;
    early_stopping_method = Force;
    on_max_tokens = Some Return_partial;
    max_continuation_chunks = Some 3;
    context_compression_threshold = None;
    compression_cooldown_messages = None;
    context_window_override = None;
    cache_strategy = No_caching;
  } in
  agent_base

let zone_tag_testable =
  let pp fmt z = Format.pp_print_string fmt
    (match z with Zone_stable -> "Zone_stable" | Zone_volatile -> "Zone_volatile") in
  Alcotest.testable pp (=)

(* ─── Tests: classify_template_zone direct ─────────────────────── *)

let test_no_vars_is_stable () =
  let z = Template.classify_template_zone ~template:"static prompt" in
  Alcotest.(check zone_tag_testable) "no vars → stable" Zone_stable z

let test_current_time_is_volatile () =
  let z = Template.classify_template_zone
    ~template:"Time is {{current_time}}" in
  Alcotest.(check zone_tag_testable) "current_time → volatile"
    Zone_volatile z

let test_agent_id_is_stable () =
  let z = Template.classify_template_zone
    ~template:"You are {{agent_id}}" in
  Alcotest.(check zone_tag_testable) "agent_id → stable" Zone_stable z

let test_runtime_id_is_stable () =
  let z = Template.classify_template_zone
    ~template:"Run {{runtime_id}}" in
  Alcotest.(check zone_tag_testable) "runtime_id → stable" Zone_stable z

let test_available_tools_is_stable () =
  let z = Template.classify_template_zone
    ~template:"Tools: {{available_tools}}" in
  Alcotest.(check zone_tag_testable) "available_tools → stable" Zone_stable z

let test_mixed_max_propagates_volatile () =
  let z = Template.classify_template_zone
    ~template:"Agent {{agent_id}} at {{current_time}} with {{runtime_id}}" in
  Alcotest.(check zone_tag_testable) "mixed → volatile (max)" Zone_volatile z

let test_multiple_volatile_stays_volatile () =
  let z = Template.classify_template_zone
    ~template:"{{current_time}}{{current_time}}" in
  Alcotest.(check zone_tag_testable) "multiple volatile → volatile"
    Zone_volatile z

let test_unknown_var_defaults_stable () =
  let z = Template.classify_template_zone
    ~template:"Hello {{unknown_var}}" in
  Alcotest.(check zone_tag_testable) "unknown var → stable default"
    Zone_stable z

(* ─── Tests: zone_of_builtin direct ────────────────────────────── *)

let test_zone_of_builtin_table () =
  Alcotest.(check zone_tag_testable) "current_time builtin"
    Zone_volatile (Template.zone_of_builtin "current_time");
  Alcotest.(check zone_tag_testable) "agent_id builtin"
    Zone_stable (Template.zone_of_builtin "agent_id");
  Alcotest.(check zone_tag_testable) "runtime_id builtin"
    Zone_stable (Template.zone_of_builtin "runtime_id");
  Alcotest.(check zone_tag_testable) "available_tools builtin"
    Zone_stable (Template.zone_of_builtin "available_tools");
  Alcotest.(check zone_tag_testable) "user_variables builtin"
    Zone_stable (Template.zone_of_builtin "user_variables");
  Alcotest.(check zone_tag_testable) "unknown default stable"
    Zone_stable (Template.zone_of_builtin "nonexistent")

(* ─── Tests: effective_system_prompt zone propagation ──────────── *)

let test_effective_prompt_no_template_preserves_zone () =
  let agent_stable = mk_agent ~system_prompt:(stable_prompt "manual stable") () in
  (match Template.effective_system_prompt agent_stable ~runtime_id:"r" with
   | Ok sp ->
     Alcotest.(check zone_tag_testable) "manual stable preserved"
       Zone_stable (zone_of sp);
     Alcotest.(check string) "text preserved" "manual stable" (prompt_text sp)
   | Error _ -> Alcotest.failf "expected Ok, got error");
  let agent_volatile = mk_agent ~system_prompt:(volatile_prompt "manual volatile") () in
  (match Template.effective_system_prompt agent_volatile ~runtime_id:"r" with
   | Ok sp ->
     Alcotest.(check zone_tag_testable) "manual volatile preserved"
       Zone_volatile (zone_of sp)
   | Error _ -> Alcotest.failf "expected Ok, got error")

let test_effective_prompt_template_with_current_time_is_volatile () =
  let agent = mk_agent ~template:{
    template = "Now: {{current_time}}";
    variables = [];
    required = [];
  } () in
  match Template.effective_system_prompt agent ~runtime_id:"r" with
  | Ok sp ->
    Alcotest.(check zone_tag_testable) "template w/ current_time → volatile"
      Zone_volatile (zone_of sp);
    Alcotest.(check bool) "text starts with Now:" true
      (String.length (prompt_text sp) >= 4 &&
       String.sub (prompt_text sp) 0 4 = "Now:")
  | Error _ -> Alcotest.failf "expected Ok, got error"

let test_effective_prompt_template_stable_only_is_stable () =
  let agent = mk_agent ~template:{
    template = "Agent {{agent_id}} runtime {{runtime_id}}";
    variables = [];
    required = [];
  } () in
  match Template.effective_system_prompt agent ~runtime_id:"r" with
  | Ok sp ->
    Alcotest.(check zone_tag_testable) "template stable-only → stable"
      Zone_stable (zone_of sp)
  | Error _ -> Alcotest.failf "expected Ok, got error"

(* ─── Runner ───────────────────────────────────────────────────── *)

let () =
  Alcotest.run "template-zone" [
    "classify-direct", [
      Alcotest.test_case "no vars → stable" `Quick test_no_vars_is_stable;
      Alcotest.test_case "current_time → volatile" `Quick test_current_time_is_volatile;
      Alcotest.test_case "agent_id → stable" `Quick test_agent_id_is_stable;
      Alcotest.test_case "runtime_id → stable" `Quick test_runtime_id_is_stable;
      Alcotest.test_case "available_tools → stable" `Quick test_available_tools_is_stable;
      Alcotest.test_case "mixed max → volatile" `Quick test_mixed_max_propagates_volatile;
      Alcotest.test_case "multiple volatile → volatile" `Quick test_multiple_volatile_stays_volatile;
      Alcotest.test_case "unknown var → stable default" `Quick test_unknown_var_defaults_stable;
    ];
    "zone-of-builtin", [
      Alcotest.test_case "builtin zone table" `Quick test_zone_of_builtin_table;
    ];
    "effective-prompt-propagation", [
      Alcotest.test_case "no template preserves zone" `Quick test_effective_prompt_no_template_preserves_zone;
      Alcotest.test_case "template w/ current_time volatile" `Quick test_effective_prompt_template_with_current_time_is_volatile;
      Alcotest.test_case "template stable-only" `Quick test_effective_prompt_template_stable_only_is_stable;
    ];
  ]
