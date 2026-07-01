(* test/test_cache_events.ml — v0.6.4
   Tests 5 new cache event variants: Cache_write, Cache_read,
   Cache_strategy_skipped, Cache_breakpoint_dropped, Cache_invalidated_by_skill.
   Each event round-trips through yojson. ~10 quick tests. *)

open Par
open Types

(* ─── Round-trip helper ─────────────────────────────────────── *)

let check_event_roundtrip (label : string) (ev : event) =
  let json = event_to_yojson ev in
  match event_of_yojson json with
  | Ok ev' ->
    let json' = event_to_yojson ev' in
    Alcotest.check Alcotest.bool label true (Yojson.Safe.equal json json')
  | Error msg ->
    Alcotest.check Alcotest.bool label false true;
    Printf.eprintf "Round-trip failed for %s: %s\n" label msg

(* ─── Cache_write tests ───────────────────────────────────── *)

let test_cache_write_five_min () =
  check_event_roundtrip "Cache_write Five_min"
    (Cache_write { tokens_written = 100; ttl = `Five_min })

let test_cache_write_one_hour () =
  check_event_roundtrip "Cache_write One_hour"
    (Cache_write { tokens_written = 2500; ttl = `One_hour })

(* ─── Cache_read tests ─────────────────────────────────────── *)

let test_cache_read () =
  check_event_roundtrip "Cache_read"
    (Cache_read { tokens_read = 500; total_prompt_tokens = 1000 })

(* ─── Cache_strategy_skipped tests ─────────────────────────── *)

let test_skip_volatile_system () =
  check_event_roundtrip "skip Volatile_system"
    (Cache_strategy_skipped { reason = `Volatile_system })

let test_skip_volatile_builtins () =
  check_event_roundtrip "skip Volatile_builtins"
    (Cache_strategy_skipped
       { reason = `Volatile_builtins [ "current_time"; "runtime_id" ] })

let test_skip_unsupported_provider () =
  check_event_roundtrip "skip Unsupported_provider"
    (Cache_strategy_skipped { reason = `Unsupported_provider })

let test_skip_no_strategy () =
  check_event_roundtrip "skip No_strategy"
    (Cache_strategy_skipped { reason = `No_strategy })

(* ─── Cache_breakpoint_dropped tests ───────────────────────── *)

let test_breakpoint_dropped_system_over_budget () =
  check_event_roundtrip "dropped System Over_budget"
    (Cache_breakpoint_dropped { location = `System; reason = Over_budget })

let test_breakpoint_dropped_tool_unsupported () =
  check_event_roundtrip "dropped Tool 3 Unsupported_by_provider"
    (Cache_breakpoint_dropped
       { location = `Tool 3; reason = Unsupported_by_provider })

let test_breakpoint_dropped_message_over_budget () =
  check_event_roundtrip "dropped Message(2,1) Over_budget"
    (Cache_breakpoint_dropped
       { location = `Message (2, 1); reason = Over_budget })

(* ─── Cache_invalidated_by_skill test ──────────────────────── *)

let test_invalidated_by_skill () =
  check_event_roundtrip "Cache_invalidated_by_skill"
    (Cache_invalidated_by_skill
       {
         skill_id = "code-review";
         before_tool_count = 10;
         after_tool_count = 8;
         estimated_wasted_tokens = 500;
       })

(* ─── Runner ─────────────────────────────────────────────── *)

let () =
  Alcotest.run "cache-events"
    [
      ( "cache-write",
        [
          Alcotest.test_case "Five_min roundtrip" `Quick
            test_cache_write_five_min;
          Alcotest.test_case "One_hour roundtrip" `Quick
            test_cache_write_one_hour;
        ] );
      ( "cache-read",
        [
          Alcotest.test_case "roundtrip" `Quick test_cache_read;
        ] );
      ( "cache-strategy-skipped",
        [
          Alcotest.test_case "Volatile_system" `Quick test_skip_volatile_system;
          Alcotest.test_case "Volatile_builtins" `Quick
            test_skip_volatile_builtins;
          Alcotest.test_case "Unsupported_provider" `Quick
            test_skip_unsupported_provider;
          Alcotest.test_case "No_strategy" `Quick test_skip_no_strategy;
        ] );
      ( "cache-breakpoint-dropped",
        [
          Alcotest.test_case "System Over_budget" `Quick
            test_breakpoint_dropped_system_over_budget;
          Alcotest.test_case "Tool Unsupported" `Quick
            test_breakpoint_dropped_tool_unsupported;
          Alcotest.test_case "Message Over_budget" `Quick
            test_breakpoint_dropped_message_over_budget;
        ] );
      ( "cache-invalidated-by-skill",
        [
          Alcotest.test_case "roundtrip" `Quick test_invalidated_by_skill;
        ] );
    ]
