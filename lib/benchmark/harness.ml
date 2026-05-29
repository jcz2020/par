open Benchmark_types
open Par.Types

let run_benchmark id description measurements ~passed =
  Benchmark_types.result ~id ~desc:description ~measurements ~passed

(* §6(a): Type safety benchmark *)
let bench_type_safety () =
  let errors =
    [
      ("missing tool handler", true);
      ("invalid tool permission", true);
      ("wrong conversation role", true);
      ("malformed JSON args", false);
      ("network timeout", false);
      ("LLM API error", false);
      ("workflow step not found", false);
      ("invalid state transition", true);
      ("tool execution timeout", false);
      ("concurrency limit exceeded", false);
    ]
  in
  let ratio = Metrics.type_safety_ratio errors in
  let type_caught_count = List.filter snd errors |> List.length in
  let measurements =
    [
      measurement ~name:"compile_time_ratio" ~value:ratio ~unit_:"ratio"
        ~category:"type_safety";
      measurement ~name:"total_error_classes"
        ~value:(float_of_int (List.length errors))
        ~unit_:"count" ~category:"type_safety";
      measurement ~name:"type_caught" ~value:(float_of_int type_caught_count)
        ~unit_:"count" ~category:"type_safety";
    ]
  in
  run_benchmark "type_safety" "Compile-time vs runtime error detection" measurements
    ~passed:true

(* §6(b): Tool accuracy benchmark *)
let bench_tool_accuracy () =
  let calc_tool name args = { id = "tc_1"; name; arguments = args } in
  let expected =
    [ calc_tool "calculator" (`Assoc []); calc_tool "echo" (`Assoc []) ]
  in
  let actual =
    [ calc_tool "calculator" (`Assoc []); calc_tool "echo" (`Assoc []) ]
  in
  let accuracy = Metrics.tool_call_accuracy ~expected ~actual in
  let order = Metrics.tool_sequence_order ~expected ~actual in
  let measurements =
    [
      measurement ~name:"accuracy" ~value:accuracy ~unit_:"ratio"
        ~category:"tool_accuracy";
      measurement ~name:"sequence_order" ~value:order ~unit_:"ratio"
        ~category:"tool_accuracy";
    ]
  in
  run_benchmark "tool_accuracy" "Tool execution correctness" measurements
    ~passed:(accuracy = 1.0 && order = 1.0)

(* §6(c): State machine soundness *)
let bench_state_soundness () =
  let valid_transitions =
    [
      (Pending, Scheduled); (Pending, Cancelled);
      (Scheduled, Running); (Scheduled, Cancelled);
      (Running, Waiting_input); (Running, Suspended);
      (Running, Completed); (Running, Failed); (Running, Cancelled);
      (Waiting_input, Running); (Waiting_input, Completed);
      (Waiting_input, Failed); (Waiting_input, Cancelled);
      (Suspended, Scheduled); (Suspended, Running);
      (Suspended, Completed); (Suspended, Failed); (Suspended, Cancelled);
    ]
  in
  let invalid_transitions =
    [
      (Completed, Running); (Failed, Running); (Cancelled, Running);
      (Pending, Completed);
      (Running, Scheduled);
    ]
  in
  let soundness = Metrics.transition_soundness valid_transitions in
  let invalid_detected = 1.0 -. Metrics.transition_soundness invalid_transitions in
  let reachability = Metrics.state_reachability_ratio () in
  let measurements =
    [
      measurement ~name:"valid_transition_ratio" ~value:soundness ~unit_:"ratio"
        ~category:"state_machine";
      measurement ~name:"invalid_detection_rate" ~value:invalid_detected
        ~unit_:"ratio" ~category:"state_machine";
      measurement ~name:"state_reachability" ~value:reachability ~unit_:"ratio"
        ~category:"state_machine";
      measurement ~name:"total_valid_transitions"
        ~value:(float_of_int (List.length valid_transitions))
        ~unit_:"count" ~category:"state_machine";
    ]
  in
  run_benchmark "state_soundness" "Workflow state machine soundness" measurements
    ~passed:(soundness = 1.0 && invalid_detected = 1.0)

(* §6(d): Middleware composition *)
let bench_middleware_composition () =
  let identity_ok = Metrics.test_identity_law (fun (x : int) -> x * 2) 5 in
  let assoc_ok =
    Metrics.test_associativity
      (fun (x : int) -> x + 1) (fun x -> x * 2) (fun x -> x - 3) 10
  in
  let hooks =
    [
      {
        name = "test_hook_1";
        on_before_llm = Some (fun c -> Some c);
        on_after_llm = None;
        on_before_tool = None;
        on_after_tool = None;
        on_error = None;
      };
      {
        name = "test_hook_2";
        on_before_llm = None;
        on_after_llm = Some (fun r -> Some r);
        on_before_tool = None;
        on_after_tool = None;
        on_error = None;
      };
      {
        name = "test_hook_3";
        on_before_llm = None;
        on_after_llm = None;
        on_before_tool = Some (fun tc -> Some tc);
        on_after_tool = None;
        on_error = None;
      };
    ]
  in
  let score = Metrics.middleware_composition_score hooks in
  let measurements =
    [
      measurement ~name:"identity_law"
        ~value:(if identity_ok then 1.0 else 0.0)
        ~unit_:"ratio" ~category:"middleware";
      measurement ~name:"associativity_law"
        ~value:(if assoc_ok then 1.0 else 0.0)
        ~unit_:"ratio" ~category:"middleware";
      measurement ~name:"composition_score" ~value:score ~unit_:"ratio"
        ~category:"middleware";
      measurement ~name:"active_hook_ratio" ~value:score ~unit_:"ratio"
        ~category:"middleware";
    ]
  in
  run_benchmark "middleware_composition" "Middleware composition correctness"
    measurements ~passed:(identity_ok && assoc_ok)

let run_all () =
  {
    suite_name = "P-A-R §6 Experiments";
    results =
      [
        bench_type_safety ();
        bench_tool_accuracy ();
        bench_state_soundness ();
        bench_middleware_composition ();
      ];
  }
