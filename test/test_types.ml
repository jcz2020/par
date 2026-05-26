open Par_core
open Types

let check_roundtrip
    (type a)
    (to_json : a -> Yojson.Safe.t)
    (of_json : Yojson.Safe.t -> (a, string) result)
    (v : a)
    ?(label = "roundtrip") () =
  let json = to_json v in
  match of_json json with
  | Result.Ok v' ->
      let json' = to_json v' in
      Alcotest.check Alcotest.bool label true (Yojson.Safe.equal json json')
  | Result.Error msg ->
      Alcotest.fail (Printf.sprintf "roundtrip failed to deserialize: %s" msg)

let task_id_suite =
  ("Task_id", [
    Alcotest.test_case "create produces unique IDs" `Quick (fun () ->
      let a = Task_id.create () in
      let b = Task_id.create () in
      Alcotest.check Alcotest.bool "not equal" false (Task_id.equal a b));

    Alcotest.test_case "create produces non-empty string" `Quick (fun () ->
      let id = Task_id.create () in
      Alcotest.check Alcotest.bool "non-empty" true
        (String.length (Task_id.to_string id) > 0));

    Alcotest.test_case "to_string returns the ID" `Quick (fun () ->
      let id = Task_id.create () in
      Alcotest.check Alcotest.string "identity" (Task_id.to_string id)
        (Task_id.to_string id));

    Alcotest.test_case "of_string with valid UUID succeeds" `Quick (fun () ->
      let id = Task_id.create () in
      match Task_id.of_string (Task_id.to_string id) with
      | Result.Ok id' -> Alcotest.check Alcotest.string "same"
                            (Task_id.to_string id) (Task_id.to_string id')
      | Result.Error _ -> Alcotest.fail "valid UUID should parse");

    Alcotest.test_case "of_string with invalid string fails" `Quick (fun () ->
      match Task_id.of_string "not-a-uuid" with
      | Result.Error _ -> ()
      | Result.Ok _ -> Alcotest.fail "invalid string should fail");

    Alcotest.test_case "equal: same ID is equal" `Quick (fun () ->
      let id = Task_id.create () in
      Alcotest.check Alcotest.bool "self-equal" true (Task_id.equal id id));

    Alcotest.test_case "compare: different IDs are not equal" `Quick (fun () ->
      let a = Task_id.create () in
      let b = Task_id.create () in
      Alcotest.check Alcotest.bool "not zero" true (Task_id.compare a b <> 0));

    Alcotest.test_case "yojson roundtrip" `Quick (fun () ->
      let id = Task_id.create () in
      check_roundtrip Task_id.to_yojson Task_id.of_yojson id ());
  ])

let error_category_suite =
  ("error_category", [
    Alcotest.test_case "Timeout roundtrip" `Quick (fun () ->
      check_roundtrip error_category_to_yojson error_category_of_yojson
        (Timeout : error_category) ());

    Alcotest.test_case "Invalid_input roundtrip" `Quick (fun () ->
      check_roundtrip error_category_to_yojson error_category_of_yojson
        (Invalid_input "bad arg") ());

    Alcotest.test_case "External_failure roundtrip" `Quick (fun () ->
      check_roundtrip error_category_to_yojson error_category_of_yojson
        (External_failure "service down") ());

    Alcotest.test_case "Rate_limited roundtrip" `Quick (fun () ->
      check_roundtrip error_category_to_yojson error_category_of_yojson
        (Rate_limited : error_category) ());

    Alcotest.test_case "Permission_denied roundtrip" `Quick (fun () ->
      check_roundtrip error_category_to_yojson error_category_of_yojson
        (Permission_denied "no access") ());

    Alcotest.test_case "Internal roundtrip" `Quick (fun () ->
      check_roundtrip error_category_to_yojson error_category_of_yojson
        (Internal "bug") ());

    Alcotest.test_case "Timeout serializes to expected JSON" `Quick (fun () ->
      let json = error_category_to_yojson (Timeout : error_category) in
      let expected = `List [`String "Timeout"] in
      Alcotest.check Alcotest.bool "json shape" true (Yojson.Safe.equal json expected));
  ])

let model_config_suite =
  ("model_config", [
    Alcotest.test_case "Openai config roundtrip" `Quick (fun () ->
      let cfg = {
        provider = `Openai;
        model_name = "gpt-4";
        api_base = Some "https://api.openai.com";
        temperature = 0.7;
        max_tokens = Some 4096;
        top_p = Some 0.9;
        stop_sequences = Some ["END"; "\n"];
      } in
      check_roundtrip model_config_to_yojson model_config_of_yojson cfg ());

    Alcotest.test_case "Anthropic config roundtrip" `Quick (fun () ->
      let cfg = {
        provider = `Anthropic;
        model_name = "claude-3";
        api_base = None;
        temperature = 1.0;
        max_tokens = None;
        top_p = None;
        stop_sequences = None;
      } in
      check_roundtrip model_config_to_yojson model_config_of_yojson cfg ());

    Alcotest.test_case "Ollama config roundtrip" `Quick (fun () ->
      let cfg = {
        provider = `Ollama;
        model_name = "llama3";
        api_base = Some "http://localhost:11434";
        temperature = 0.5;
        max_tokens = Some 2048;
        top_p = None;
        stop_sequences = None;
      } in
      check_roundtrip model_config_to_yojson model_config_of_yojson cfg ());

    Alcotest.test_case "Custom provider roundtrip" `Quick (fun () ->
      let cfg = {
        provider = `Custom "my-provider";
        model_name = "custom-model";
        api_base = None;
        temperature = 0.0;
        max_tokens = None;
        top_p = None;
        stop_sequences = None;
      } in
      check_roundtrip model_config_to_yojson model_config_of_yojson cfg ());
  ])

let tool_permission_suite =
  ("tool_permission", [
    Alcotest.test_case "Allow roundtrip" `Quick (fun () ->
      check_roundtrip tool_permission_to_yojson tool_permission_of_yojson Allow ());

    Alcotest.test_case "Confirm roundtrip" `Quick (fun () ->
      check_roundtrip tool_permission_to_yojson tool_permission_of_yojson Confirm ());

    Alcotest.test_case "Deny roundtrip" `Quick (fun () ->
      check_roundtrip tool_permission_to_yojson tool_permission_of_yojson Deny ());

    Alcotest.test_case "Role_based roundtrip" `Quick (fun () ->
      check_roundtrip tool_permission_to_yojson tool_permission_of_yojson
        (Role_based { allowed_roles = ["admin"; "operator"] }) ());

    Alcotest.test_case "Condition_based roundtrip" `Quick (fun () ->
      let expr = Equals (Literal (`Int 1), Literal (`Int 1)) in
      check_roundtrip tool_permission_to_yojson tool_permission_of_yojson
        (Condition_based expr) ());

    Alcotest.test_case "Allow != Deny (different constructors)" `Quick (fun () ->
      let json_a = tool_permission_to_yojson Allow in
      let json_d = tool_permission_to_yojson Deny in
      Alcotest.check Alcotest.bool "not equal" false (Yojson.Safe.equal json_a json_d));
  ])

let transition_suite =
  ("validate_transition", [
    Alcotest.test_case "valid: Pending -> Scheduled" `Quick (fun () ->
      match validate_transition Pending Scheduled with
      | Result.Ok () -> ()
      | Result.Error msg -> Alcotest.fail ("should be valid: " ^ msg));

    Alcotest.test_case "valid: Running -> Completed" `Quick (fun () ->
      match validate_transition Running Completed with
      | Result.Ok () -> ()
      | Result.Error msg -> Alcotest.fail ("should be valid: " ^ msg));

    Alcotest.test_case "invalid: Pending -> Completed" `Quick (fun () ->
      match validate_transition Pending Completed with
      | Result.Error _ -> ()
      | Result.Ok () -> Alcotest.fail "should be invalid");

    Alcotest.test_case "invalid: Completed -> Running (terminal)" `Quick (fun () ->
      match validate_transition Completed Running with
      | Result.Error _ -> ()
      | Result.Ok () -> Alcotest.fail "terminal state cannot transition");
  ])

let status_to_string_suite =
  ("status_to_string", [
    Alcotest.test_case "all statuses have string representation" `Quick (fun () ->
      let statuses = [Pending; Scheduled; Running; Waiting_input;
                      Suspended; Completed; Failed; Cancelled] in
      List.iter (fun s ->
        let str = status_to_string s in
        Alcotest.check Alcotest.bool (Printf.sprintf "%s non-empty" str)
          true (String.length str > 0)
      ) statuses);

    Alcotest.test_case "string representations are distinct" `Quick (fun () ->
      let strings = List.map status_to_string
        [Pending; Scheduled; Running; Waiting_input;
         Suspended; Completed; Failed; Cancelled] in
      let unique = List.sort_uniq String.compare strings in
      Alcotest.check Alcotest.int "8 unique strings" 8 (List.length unique));
  ])

let task_status_roundtrip_suite =
  ("task_status yojson", [
    Alcotest.test_case "all statuses roundtrip" `Quick (fun () ->
      let statuses = [Pending; Scheduled; Running; Waiting_input;
                      Suspended; Completed; Failed; Cancelled] in
      List.iter (fun s ->
        check_roundtrip ~label:"task_status roundtrip"
          task_status_to_yojson task_status_of_yojson s ()
      ) statuses);
  ])

let backoff_strategy_suite =
  ("backoff_strategy yojson", [
    Alcotest.test_case "Exponential roundtrip" `Quick (fun () ->
      check_roundtrip backoff_strategy_to_yojson backoff_strategy_of_yojson
        (Exponential { base = 1.5; max_delay = 60.0 }) ());

    Alcotest.test_case "Fixed roundtrip" `Quick (fun () ->
      check_roundtrip backoff_strategy_to_yojson backoff_strategy_of_yojson
        (Fixed 2.5) ());

    Alcotest.test_case "Linear roundtrip" `Quick (fun () ->
      check_roundtrip backoff_strategy_to_yojson backoff_strategy_of_yojson
        (Linear { increment = 1.0; max_delay = 30.0 }) ());
  ])

let retryable_condition_suite =
  ("retryable_condition yojson", [
    Alcotest.test_case "all conditions roundtrip" `Quick (fun () ->
      let conditions : retryable_condition list =
        [Timeout; Rate_limited; External_failure; Connection_error; Any_retryable] in
      List.iter (fun c ->
        check_roundtrip ~label:"retryable_condition"
          retryable_condition_to_yojson retryable_condition_of_yojson c ()
      ) conditions);
  ])

let suite = [
  task_id_suite;
  error_category_suite;
  model_config_suite;
  tool_permission_suite;
  transition_suite;
  status_to_string_suite;
  task_status_roundtrip_suite;
  backoff_strategy_suite;
  retryable_condition_suite;
]
