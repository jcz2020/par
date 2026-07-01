(* test/test_budget_manager.ml — v0.6.4
   Tests Cache_breakpoint.plan_breakpoints: priority sorting, over-budget drop,
   unsupported-provider drop, max_override behavior. ~11 quick tests. *)

open Par
open Types

(* ─── Helpers ────────────────────────────────────────────────────── *)

let make_test_llm ?(max_bp = 4) ?(ttls = [ `Five_min; `One_hour ]) () : llm_service =
  {
    complete_fn = (fun _mc _tools _conv -> Error (Internal "dummy"));
    stream_fn =
      (fun _mc _tools _conv _sc _cb ->
        Error (Internal "dummy"));
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None;
    cache_control_fn =
      Some (fun () -> { supported_ttls = ttls; max_breakpoints = max_bp });
  }

let make_no_cache_llm () : llm_service =
  {
    complete_fn = (fun _mc _tools _conv -> Error (Internal "dummy"));
    stream_fn =
      (fun _mc _tools _conv _sc _cb ->
        Error (Internal "dummy"));
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None;
    cache_control_fn = None;
  }

let mk_bp ?(priority = 50) ?(tokens = 1000) (loc : breakpoint_location)
    (ttl : cache_ttl) : Cache_breakpoint.breakpoint =
  { location = loc; ttl; estimated_tokens = tokens; priority }

(* ─── Basic tests ──────────────────────────────────────────────── *)

(* Empty candidate list → no used, no dropped *)
let test_empty_candidates () =
  let svc = make_test_llm ~max_bp:4 () in
  let result = Cache_breakpoint.plan_breakpoints svc [] in
  Alcotest.(check int) "used count" 0 (List.length result.used);
  Alcotest.(check int) "dropped count" 0 (List.length result.dropped)

(* 1 candidate, max_breakpoints=4 → all used, none dropped *)
let test_one_candidate_under_cap () =
  let svc = make_test_llm ~max_bp:4 () in
  let bp = mk_bp `System `Five_min in
  let result = Cache_breakpoint.plan_breakpoints svc [ bp ] in
  Alcotest.(check int) "used count" 1 (List.length result.used);
  Alcotest.(check int) "dropped count" 0 (List.length result.dropped)

(* 4 candidates, max_breakpoints=4 → all used, none dropped *)
let test_exact_capacity () =
  let svc = make_test_llm ~max_bp:4 () in
  let bps =
    [
      mk_bp ~priority:10 `System `Five_min;
      mk_bp ~priority:20 (`Tool 0) `One_hour;
      mk_bp ~priority:30 (`Message (1, 2)) `Five_min;
      mk_bp ~priority:40 `System `One_hour;
    ]
  in
  let result = Cache_breakpoint.plan_breakpoints svc bps in
  Alcotest.(check int) "used count" 4 (List.length result.used);
  Alcotest.(check int) "dropped count" 0 (List.length result.dropped)

(* ─── Over-budget tests ───────────────────────────────────────── *)

(* 5 candidates, max_breakpoints=4 → 4 used (highest priority), 1 dropped Over_budget *)
let test_over_budget_one () =
  let svc = make_test_llm ~max_bp:4 () in
  let bps =
    [
      mk_bp ~priority:10 `System `Five_min;
      mk_bp ~priority:20 (`Tool 0) `Five_min;
      mk_bp ~priority:30 (`Tool 1) `Five_min;
      mk_bp ~priority:40 (`Tool 2) `Five_min;
      mk_bp ~priority:50 (`Tool 3) `Five_min;
    ]
  in
  let result = Cache_breakpoint.plan_breakpoints svc bps in
  Alcotest.(check int) "used count" 4 (List.length result.used);
  Alcotest.(check int) "dropped count" 1 (List.length result.dropped);
  (* dropped item should be priority 10 (lowest) *)
  let dropped_bp, reason = List.hd result.dropped in
  Alcotest.(check int) "dropped priority" 10 dropped_bp.priority;
  (match reason with
  | Over_budget -> ()
  | _ -> Alcotest.fail "expected Over_budget reason")

(* 100 candidates, max_breakpoints=4 → 4 used, 96 dropped Over_budget *)
let test_over_budget_many () =
  let svc = make_test_llm ~max_bp:4 () in
  let bps =
    List.init 100 (fun i ->
        mk_bp ~priority:(i + 1) (`Tool i) `Five_min)
  in
  let result = Cache_breakpoint.plan_breakpoints svc bps in
  Alcotest.(check int) "used count" 4 (List.length result.used);
  Alcotest.(check int) "dropped count" 96 (List.length result.dropped);
  (* verify all dropped are Over_budget *)
  let all_over_budget =
    List.for_all
      (fun (_, r) -> match r with Over_budget -> true | _ -> false)
      result.dropped
  in
  Alcotest.(check bool) "all dropped Over_budget" true all_over_budget

(* ─── Unsupported-provider tests ─────────────────────────────── *)

(* max_breakpoints=0 → 0 used, all dropped Unsupported_by_provider *)
let test_zero_max_breakpoints () =
  let svc = make_test_llm ~max_bp:0 () in
  let bps =
    [
      mk_bp ~priority:10 `System `Five_min;
      mk_bp ~priority:20 (`Tool 0) `Five_min;
      mk_bp ~priority:30 (`Tool 1) `Five_min;
    ]
  in
  let result = Cache_breakpoint.plan_breakpoints svc bps in
  Alcotest.(check int) "used count" 0 (List.length result.used);
  Alcotest.(check int) "dropped count" 3 (List.length result.dropped);
  let all_unsupported =
    List.for_all
      (fun (_, r) -> match r with Unsupported_by_provider -> true | _ -> false)
      result.dropped
  in
  Alcotest.(check bool) "all dropped Unsupported_by_provider" true all_unsupported

(* None cache_control_fn → equivalent to max_breakpoints=0 *)
let test_none_cache_control_fn () =
  let svc = make_no_cache_llm () in
  let bps =
    [
      mk_bp ~priority:10 `System `Five_min;
      mk_bp ~priority:20 (`Tool 0) `Five_min;
    ]
  in
  let result = Cache_breakpoint.plan_breakpoints svc bps in
  Alcotest.(check int) "used count" 0 (List.length result.used);
  Alcotest.(check int) "dropped count" 2 (List.length result.dropped);
  let all_unsupported =
    List.for_all
      (fun (_, r) -> match r with Unsupported_by_provider -> true | _ -> false)
      result.dropped
  in
  Alcotest.(check bool) "all dropped Unsupported_by_provider" true all_unsupported

(* ─── max_override tests ─────────────────────────────────────── *)

(* 3 candidates, max_breakpoints=2, max_override=Some 5 → all 3 used *)
let test_max_override_wins () =
  let svc = make_test_llm ~max_bp:2 () in
  let bps =
    [
      mk_bp ~priority:10 `System `Five_min;
      mk_bp ~priority:20 (`Tool 0) `Five_min;
      mk_bp ~priority:30 (`Tool 1) `Five_min;
    ]
  in
  let result =
    Cache_breakpoint.plan_breakpoints ~max_override:5 svc bps
  in
  Alcotest.(check int) "used count" 3 (List.length result.used);
  Alcotest.(check int) "dropped count" 0 (List.length result.dropped)

(* ─── Priority sort tests ────────────────────────────────────── *)

(* 3 candidates priorities [10, 50, 100], max_breakpoints=2 → used has [100, 50], dropped has [10] *)
let test_priority_sort_descending () =
  let svc = make_test_llm ~max_bp:2 () in
  let bps =
    [
      mk_bp ~priority:10 `System `Five_min;
      mk_bp ~priority:50 (`Tool 0) `Five_min;
      mk_bp ~priority:100 (`Tool 1) `Five_min;
    ]
  in
  let result = Cache_breakpoint.plan_breakpoints svc bps in
  Alcotest.(check int) "used count" 2 (List.length result.used);
  (* used should be sorted by priority DESC: [100; 50] *)
  let used_priorities = List.map (fun bp -> bp.Cache_breakpoint.priority) result.used in
  Alcotest.(check (list int)) "used priorities DESC" [ 100; 50 ] used_priorities;
  let dropped_bp, _reason = List.hd result.dropped in
  Alcotest.(check int) "dropped priority" 10 dropped_bp.priority

(* ─── Field preservation tests ───────────────────────────────── *)

(* Verify returned used breakpoints preserve original location, ttl, estimated_tokens *)
let test_field_preservation () =
  let svc = make_test_llm ~max_bp:4 () in
  let bps =
    [
      mk_bp ~priority:100 ~tokens:2000 (`Tool 3) `One_hour;
      mk_bp ~priority:50 ~tokens:500 (`Message (1, 2)) `Five_min;
    ]
  in
  let result = Cache_breakpoint.plan_breakpoints svc bps in
  match result.used with
  | [ bp1; bp2 ] ->
    Alcotest.(check int) "bp1 priority" 100 bp1.priority;
    Alcotest.(check int) "bp1 tokens" 2000 bp1.estimated_tokens;
    (match bp1.location with
    | `Tool 3 -> ()
    | _ -> Alcotest.fail "bp1 location should be `Tool 3");
    (match bp1.ttl with
    | `One_hour -> ()
    | _ -> Alcotest.fail "bp1 ttl should be `One_hour");
    Alcotest.(check int) "bp2 priority" 50 bp2.priority;
    Alcotest.(check int) "bp2 tokens" 500 bp2.estimated_tokens
  | _ -> Alcotest.fail "expected 2 used breakpoints"

(* ─── Mixed location round-trip ───────────────────────────────── *)

(* Mixed [`System; `Tool 0; `Message (1,2)] locations round-trip correctly *)
let test_mixed_locations () =
  let svc = make_test_llm ~max_bp:3 () in
  let bps =
    [
      mk_bp ~priority:10 `System `Five_min;
      mk_bp ~priority:20 (`Tool 0) `One_hour;
      mk_bp ~priority:30 (`Message (1, 2)) `Five_min;
    ]
  in
  let result = Cache_breakpoint.plan_breakpoints svc bps in
  Alcotest.(check int) "used count" 3 (List.length result.used);
  (* used sorted by priority DESC: [30; 20; 10] *)
  let locations = List.map (fun bp -> bp.Cache_breakpoint.location) result.used in
  let has_system = List.exists (function `System -> true | _ -> false) locations in
  let has_tool = List.exists (function `Tool _ -> true | _ -> false) locations in
  let has_message =
    List.exists (function `Message _ -> true | _ -> false) locations
  in
  Alcotest.(check bool) "has System" true has_system;
  Alcotest.(check bool) "has Tool" true has_tool;
  Alcotest.(check bool) "has Message" true has_message

(* ─── Runner ─────────────────────────────────────────────────── *)

let () =
  Alcotest.run "budget-manager"
    [
      ( "basic",
        [
          Alcotest.test_case "empty candidates" `Quick test_empty_candidates;
          Alcotest.test_case "one under cap" `Quick test_one_candidate_under_cap;
          Alcotest.test_case "exact capacity" `Quick test_exact_capacity;
        ] );
      ( "over-budget",
        [
          Alcotest.test_case "over budget one" `Quick test_over_budget_one;
          Alcotest.test_case "over budget many" `Quick test_over_budget_many;
        ] );
      ( "unsupported-provider",
        [
          Alcotest.test_case "zero max breakpoints" `Quick test_zero_max_breakpoints;
          Alcotest.test_case "none cache control fn" `Quick test_none_cache_control_fn;
        ] );
      ( "max-override",
        [
          Alcotest.test_case "override wins" `Quick test_max_override_wins;
        ] );
      ( "priority-sort",
        [
          Alcotest.test_case "descending priority" `Quick test_priority_sort_descending;
        ] );
      ( "field-preservation",
        [
          Alcotest.test_case "preserves fields" `Quick test_field_preservation;
          Alcotest.test_case "mixed locations" `Quick test_mixed_locations;
        ] );
    ]
