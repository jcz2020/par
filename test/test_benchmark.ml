[@@@warning "-32"]
(* test_benchmark.ml — Tests for benchmark harness (paper §6) *)

open Par.Types

let tc name : tool_call = { id = "tc_1"; name; arguments = `Assoc [] }

let check_float ~expect ~label actual =
  Alcotest.check Alcotest.bool label true (abs_float (expect -. actual) < 1e-9)

let status_name s = Par.Types.status_to_string s

let string_contains s sub =
  let rec search i =
    i <= String.length s - String.length sub
    && (String.sub s i (String.length sub) = sub || search (i + 1))
  in
  String.length s >= String.length sub && search 0

(* --- 1. type_safety_ratio tests --- *)

let test_type_safety_100 () =
  let errors =
    [ ("e1", true); ("e2", true); ("e3", true); ("e4", true); ("e5", true) ]
  in
  check_float ~expect:1.0 ~label:"type_safety 100%" (Metrics.type_safety_ratio errors)

let test_type_safety_0 () =
  let errors =
    [ ("e1", false); ("e2", false); ("e3", false); ("e4", false); ("e5", false) ]
  in
  check_float ~expect:0.0 ~label:"type_safety 0%" (Metrics.type_safety_ratio errors)

let test_type_safety_mixed () =
  let errors =
    [ ("e1", true); ("e2", true); ("e3", false); ("e4", true); ("e5", false) ]
  in
  check_float ~expect:0.6 ~label:"type_safety mixed" (Metrics.type_safety_ratio errors)

let test_type_safety_empty () =
  check_float ~expect:1.0 ~label:"type_safety empty" (Metrics.type_safety_ratio [])

(* --- 2. tool_call_accuracy tests --- *)

let test_tool_accuracy_perfect () =
  let expected = [ tc "calculator"; tc "echo" ] in
  let actual = [ tc "calculator"; tc "echo" ] in
  check_float ~expect:1.0 ~label:"tool accuracy perfect"
    (Metrics.tool_call_accuracy ~expected ~actual)

let test_tool_accuracy_wrong_order () =
  let expected = [ tc "calculator"; tc "echo" ] in
  let actual = [ tc "echo"; tc "calculator" ] in
  let acc = Metrics.tool_call_accuracy ~expected ~actual in
  Alcotest.(check bool) "accuracy < 1.0" true (acc < 1.0)

let test_tool_accuracy_missing_call () =
  let expected = [ tc "calculator"; tc "echo"; tc "web_search" ] in
  let actual = [ tc "calculator" ] in
  let acc = Metrics.tool_call_accuracy ~expected ~actual in
  Alcotest.(check bool) "accuracy < 1.0" true (acc < 1.0)

(* --- 3. tool_sequence_order tests --- *)

let test_sequence_order_correct () =
  let expected = [ tc "calculator"; tc "echo" ] in
  let actual = [ tc "calculator"; tc "echo" ] in
  check_float ~expect:1.0 ~label:"sequence order correct"
    (Metrics.tool_sequence_order ~expected ~actual)

let test_sequence_order_wrong () =
  let expected = [ tc "calculator"; tc "echo" ] in
  let actual = [ tc "echo"; tc "calculator" ] in
  check_float ~expect:0.0 ~label:"sequence order wrong"
    (Metrics.tool_sequence_order ~expected ~actual)

(* --- 4. transition_soundness tests --- *)

let test_transition_soundness_all_valid () =
  let transitions =
    [
      (Pending, Scheduled); (Scheduled, Running);
      (Running, Completed); (Running, Failed);
    ]
  in
  check_float ~expect:1.0 ~label:"transition soundness all valid" (Metrics.transition_soundness transitions)

let test_transition_soundness_with_invalid () =
  let transitions =
    [
      (Pending, Scheduled);
      (Completed, Running);
      (Running, Failed);
      (Pending, Completed);
    ]
  in
  check_float ~expect:0.5 ~label:"transition soundness with invalid" (Metrics.transition_soundness transitions)

let test_terminal_states_no_transition () =
  let terminals = [ Completed; Failed; Cancelled ] in
  let non_terminals = [ Pending; Scheduled; Running; Waiting_input; Suspended ] in
  List.iter (fun t ->
    List.iter (fun nt ->
      Alcotest.(check bool)
        (Printf.sprintf "valid_transition(%s, %s) = false"
           (status_name t) (status_name nt))
        false (Metrics.valid_transition (t, nt))
    ) non_terminals
  ) terminals

(* --- 5. middleware law tests --- *)

let test_identity_law () =
  let result = Metrics.test_identity_law (fun (x : int) -> x + 1) 5 in
  Alcotest.(check bool) "identity law holds" true result

let test_associativity_law () =
  let f (x : int) = x + 1 in
  let g (x : int) = x * 2 in
  let h (x : int) = x - 3 in
  let result = Metrics.test_associativity f g h 10 in
  Alcotest.(check bool) "associativity law holds" true result

(* --- 6. harness scenario tests --- *)

let test_bench_type_safety () =
  let r = Harness.bench_type_safety () in
  Alcotest.(check bool) "has measurements" true (r.measurements <> []);
  Alcotest.(check string) "benchmark_id" "type_safety" r.benchmark_id

let test_run_all () =
  let s = Harness.run_all () in
  Alcotest.(check bool) "4 results" true (List.length s.results = 4)

(* --- 7. report output tests --- *)

let test_report_latex () =
  let s = Harness.run_all () in
  let latex = Report.to_latex s in
  Alcotest.(check bool) "contains \\begin{tabular}" true
    (string_contains latex "\\begin{tabular}")

let test_report_markdown () =
  let s = Harness.run_all () in
  let md = Report.to_markdown s in
  let has_pipe = String.contains md '|' in
  let has_header_sep = string_contains md "|---|" in
  Alcotest.(check bool) "pipe-delimited table with header sep" true
    (has_pipe && has_header_sep)

let () =
  let open Alcotest in
  run "Benchmark" [
    "metrics_type_safety", [
      test_case "100% caught" `Quick test_type_safety_100;
      test_case "0% caught" `Quick test_type_safety_0;
      test_case "mixed 3/5" `Quick test_type_safety_mixed;
      test_case "empty list" `Quick test_type_safety_empty;
    ];
    "metrics_tool_accuracy", [
      test_case "perfect match" `Quick test_tool_accuracy_perfect;
      test_case "wrong order" `Quick test_tool_accuracy_wrong_order;
      test_case "missing call" `Quick test_tool_accuracy_missing_call;
    ];
    "metrics_state_soundness", [
      test_case "all valid" `Quick test_transition_soundness_all_valid;
      test_case "with invalid" `Quick test_transition_soundness_with_invalid;
      test_case "terminal states" `Quick test_terminal_states_no_transition;
    ];
    "metrics_middleware", [
      test_case "identity law" `Quick test_identity_law;
      test_case "associativity law" `Quick test_associativity_law;
    ];
    "harness_scenarios", [
      test_case "bench_type_safety" `Quick test_bench_type_safety;
      test_case "run_all suite" `Quick test_run_all;
    ];
    "report_output", [
      test_case "to_latex well-formed" `Quick test_report_latex;
      test_case "to_markdown well-formed" `Quick test_report_markdown;
    ];
  ]
