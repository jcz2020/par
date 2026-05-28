open Par
open Types

let dummy_task ?(retry_count = 0) ?(status = Pending) () : task_state =
  {
    id = Task_id.create ();
    input = Tool_input { tool_name = "test"; arguments = `Null };
    status;
    parent_id = None;
    workflow_run_id = None;
    priority = 0;
    schedule = None;
    timeout = 30.0;
    retry_policy = None;
    retry_count;
    dependencies = [];
    depend_mode = `All_success;
    created_at = 0.0;
    updated_at = 0.0;
    output = None;
    error = None;
  }

let check_ok label = function
  | Result.Ok () -> ()
  | Result.Error e ->
      Alcotest.fail
        (Printf.sprintf "%s: expected Ok, got Error(%s)"
           label (State_machine.transition_error_to_string e))

let check_error label expected = function
  | Result.Error e when expected e -> ()
  | Result.Error e ->
      Alcotest.fail
        (Printf.sprintf "%s: wrong error variant: %s"
           label (State_machine.transition_error_to_string e))
  | Result.Ok () ->
      Alcotest.fail (label ^ ": expected Error, got Ok")

let assert_float_eq ~tol label a b =
  if Float.abs (a -. b) > tol then
    Alcotest.fail
      (Printf.sprintf "%s: expected %.6f, got %.6f (tol %.6f)" label a b tol)

let validate_suite =
  ("Transition validation", [
    Alcotest.test_case "Pending -> Scheduled is valid" `Quick (fun () ->
      check_ok "Pending->Scheduled"
        (State_machine.validate Pending Scheduled));

    Alcotest.test_case "Scheduled -> Running is valid" `Quick (fun () ->
      check_ok "Scheduled->Running"
        (State_machine.validate Scheduled Running));

    Alcotest.test_case "Running -> Completed is valid" `Quick (fun () ->
      check_ok "Running->Completed"
        (State_machine.validate Running Completed));

    Alcotest.test_case "Running -> Failed is valid" `Quick (fun () ->
      check_ok "Running->Failed"
        (State_machine.validate Running Failed));

    Alcotest.test_case "Running -> Cancelled is valid" `Quick (fun () ->
      check_ok "Running->Cancelled"
        (State_machine.validate Running Cancelled));

    Alcotest.test_case "Running -> Waiting_input is valid" `Quick (fun () ->
      check_ok "Running->Waiting_input"
        (State_machine.validate Running Waiting_input));

    Alcotest.test_case "Running -> Suspended is valid" `Quick (fun () ->
      check_ok "Running->Suspended"
        (State_machine.validate Running Suspended));

    Alcotest.test_case "Pending -> Completed is invalid (skip Running)" `Quick (fun () ->
      check_error "Pending->Completed"
        (function State_machine.Invalid _ -> true | _ -> false)
        (State_machine.validate Pending Completed));

    Alcotest.test_case "Cancelled -> Running is invalid (terminal)" `Quick (fun () ->
      check_error "Cancelled->Running"
        (function State_machine.Terminal_source _ -> true | _ -> false)
        (State_machine.validate Cancelled Running));

    Alcotest.test_case "Failed -> Running is invalid (terminal)" `Quick (fun () ->
      check_error "Failed->Running"
        (function State_machine.Terminal_source _ -> true | _ -> false)
        (State_machine.validate Failed Running));

    Alcotest.test_case "Completed -> Scheduled is invalid (terminal)" `Quick (fun () ->
      check_error "Completed->Scheduled"
        (function State_machine.Terminal_source _ -> true | _ -> false)
        (State_machine.validate Completed Scheduled));

    Alcotest.test_case "Pending -> Pending is invalid (self)" `Quick (fun () ->
      check_error "Pending->Pending"
        (function State_machine.Self_transition _ -> true | _ -> false)
        (State_machine.validate Pending Pending));

    Alcotest.test_case "Running -> Running is invalid (self)" `Quick (fun () ->
      check_error "Running->Running"
        (function State_machine.Self_transition _ -> true | _ -> false)
        (State_machine.validate Running Running));
  ])

let transition_suite =
  ("Transition function", [
    Alcotest.test_case "valid transition updates status" `Quick (fun () ->
      let task = dummy_task () in
      match State_machine.transition (fun _ -> ()) task Scheduled with
      | Result.Ok updated ->
          Alcotest.check Alcotest.string "status" "Scheduled"
            (status_to_string updated.status);
          Alcotest.check Alcotest.int "retry_count" 0 updated.retry_count
      | Result.Error msg ->
          Alcotest.fail ("transition failed: " ^ msg));

    Alcotest.test_case "invalid transition returns error" `Quick (fun () ->
      let task = dummy_task () in
      match State_machine.transition (fun _ -> ()) task Completed with
      | Result.Error _ -> ()
      | Result.Ok _ -> Alcotest.fail "should have returned error");

    Alcotest.test_case "transition calls persist function" `Quick (fun () ->
      let persisted = ref None in
      let task = dummy_task () in
      (match State_machine.transition (fun t -> persisted := Some t) task Scheduled with
      | Result.Ok _ ->
          (match !persisted with
           | Some t ->
               Alcotest.check Alcotest.string "status" "Scheduled"
                 (status_to_string t.status)
           | None -> Alcotest.fail "persist_fn was not called")
      | Result.Error msg -> Alcotest.fail ("transition failed: " ^ msg)));

    Alcotest.test_case "transition from Running preserves task id" `Quick (fun () ->
      let task = dummy_task ~status:Running () in
      match State_machine.transition (fun _ -> ()) task Completed with
      | Result.Ok updated ->
          Alcotest.check Alcotest.bool "same id" true (Task_id.equal task.id updated.id)
      | Result.Error msg -> Alcotest.fail ("transition failed: " ^ msg));
  ])

let retry_suite =
  ("Retry logic", [
    Alcotest.test_case "apply_retry increments count and sets Scheduled" `Quick (fun () ->
      let policy = {
        max_attempts = 3;
        initial_delay = 1.0;
        backoff = Fixed 2.0;
        retry_on = [Any_retryable];
        jitter = None;
      } in
      let task = dummy_task ~retry_count:0 ~status:Failed () in
      match State_machine.apply_retry task policy with
      | Result.Ok updated ->
          Alcotest.check Alcotest.int "retry_count" 1 updated.retry_count;
          Alcotest.check Alcotest.string "status" "Scheduled"
            (status_to_string updated.status)
      | Result.Error _ -> Alcotest.fail "should succeed with retry_count=0");

    Alcotest.test_case "apply_retry increments from 1 to 2" `Quick (fun () ->
      let policy = {
        max_attempts = 3;
        initial_delay = 1.0;
        backoff = Fixed 2.0;
        retry_on = [Any_retryable];
        jitter = None;
      } in
      let task = dummy_task ~retry_count:1 () in
      match State_machine.apply_retry task policy with
      | Result.Ok updated ->
          Alcotest.check Alcotest.int "retry_count" 2 updated.retry_count
      | Result.Error _ -> Alcotest.fail "should succeed with retry_count=1");

    Alcotest.test_case "apply_retry fails when max_attempts reached" `Quick (fun () ->
      let policy = {
        max_attempts = 3;
        initial_delay = 1.0;
        backoff = Fixed 2.0;
        retry_on = [Any_retryable];
        jitter = None;
      } in
      let task = dummy_task ~retry_count:3 () in
      match State_machine.apply_retry task policy with
      | Result.Error `Max_retries_exceeded -> ()
      | Result.Ok _ -> Alcotest.fail "should have failed with Max_retries_exceeded"
      | Result.Error _ -> ());

    Alcotest.test_case "apply_retry fails at exact boundary (count == max)" `Quick (fun () ->
      let policy = {
        max_attempts = 2;
        initial_delay = 1.0;
        backoff = Fixed 1.0;
        retry_on = [Any_retryable];
        jitter = None;
      } in
      let task = dummy_task ~retry_count:2 () in
      match State_machine.apply_retry task policy with
      | Result.Error `Max_retries_exceeded -> ()
      | Result.Ok _ -> Alcotest.fail "should fail at boundary");
  ])

let backoff_suite =
  ("Backoff strategies", [
    Alcotest.test_case "exponential backoff at attempt 0" `Quick (fun () ->
      let policy = {
        max_attempts = 5;
        initial_delay = 1.0;
        backoff = Exponential { base = 1.0; max_delay = 60.0 };
        retry_on = [Any_retryable];
        jitter = None;
      } in
      let task = dummy_task ~retry_count:0 () in
      match State_machine.apply_retry task policy with
      | Result.Ok updated ->
          (match updated.schedule with
           | Some (`Delay d) -> assert_float_eq ~tol:0.001 "delay" 1.0 d
           | _ -> Alcotest.fail "should have Delay schedule")
      | Result.Error _ -> Alcotest.fail "should succeed");

    Alcotest.test_case "exponential backoff at attempt 3" `Quick (fun () ->
      let policy = {
        max_attempts = 5;
        initial_delay = 1.0;
        backoff = Exponential { base = 1.0; max_delay = 60.0 };
        retry_on = [Any_retryable];
        jitter = None;
      } in
      let task = dummy_task ~retry_count:3 () in
      (* base * 2^3 = 8.0 *)
      match State_machine.apply_retry task policy with
      | Result.Ok updated ->
          (match updated.schedule with
           | Some (`Delay d) -> assert_float_eq ~tol:0.001 "delay" 8.0 d
           | _ -> Alcotest.fail "should have Delay schedule")
      | Result.Error _ -> Alcotest.fail "should succeed");

    Alcotest.test_case "exponential backoff capped at max_delay" `Quick (fun () ->
      let policy = {
        max_attempts = 20;
        initial_delay = 1.0;
        backoff = Exponential { base = 2.0; max_delay = 10.0 };
        retry_on = [Any_retryable];
        jitter = None;
      } in
      (* attempt 10: 2.0 * 2^10 = 2048.0, capped to 10.0 *)
      let task = dummy_task ~retry_count:10 () in
      match State_machine.apply_retry task policy with
      | Result.Ok updated ->
          (match updated.schedule with
           | Some (`Delay d) -> assert_float_eq ~tol:0.001 "delay" 10.0 d
           | _ -> Alcotest.fail "should have Delay schedule")
      | Result.Error _ -> Alcotest.fail "should succeed");

    Alcotest.test_case "fixed backoff is constant" `Quick (fun () ->
      let policy = {
        max_attempts = 5;
        initial_delay = 1.0;
        backoff = Fixed 3.5;
        retry_on = [Any_retryable];
        jitter = None;
      } in
      let task = dummy_task ~retry_count:2 () in
      match State_machine.apply_retry task policy with
      | Result.Ok updated ->
          (match updated.schedule with
           | Some (`Delay d) -> assert_float_eq ~tol:0.001 "delay" 3.5 d
           | _ -> Alcotest.fail "should have Delay schedule")
      | Result.Error _ -> Alcotest.fail "should succeed");

    Alcotest.test_case "linear backoff grows linearly" `Quick (fun () ->
      let policy = {
        max_attempts = 5;
        initial_delay = 1.0;
        backoff = Linear { increment = 2.0; max_delay = 100.0 };
        retry_on = [Any_retryable];
        jitter = None;
      } in
      (* attempt 2: 2.0 * (2+1) = 6.0 *)
      let task = dummy_task ~retry_count:2 () in
      match State_machine.apply_retry task policy with
      | Result.Ok updated ->
          (match updated.schedule with
           | Some (`Delay d) -> assert_float_eq ~tol:0.001 "delay" 6.0 d
           | _ -> Alcotest.fail "should have Delay schedule")
      | Result.Error _ -> Alcotest.fail "should succeed");
  ])

let suite = [ validate_suite; transition_suite; retry_suite; backoff_suite ]
