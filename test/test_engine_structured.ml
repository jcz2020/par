(* Tests for Engine.run_structured — schema-driven structured output with
   repair-on-failure loop. See docs/v0.4.8-ROADMAP.md §WU-2.

   Fixtures copied verbatim from test/test_integration.ml per project
   convention (ROADMAP §Test Conventions point 3: no shared helpers). *)

open Par
open Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 ; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"

let mock_llm responses =
  let counter = ref 0 in
  let next () =
    let idx = !counter in
    incr counter;
    match List.nth_opt responses idx with
    | Some resp -> resp
    | None -> text_response "default"
  in
  { complete_fn = (fun _model _tools _conv -> Ok (next ()));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
  supports_native_tools_fn = None;
  context_window_fn = None; cache_control_fn = None;
  }

(* mock_llm_with_structured: native path. complete_structured_fn = Some _.
   on_call fires once per LLM call so tests can assert invocation count
   or trigger side effects (e.g. mid-loop cancellation in test 8). *)
let mock_llm_with_structured ?(on_call : unit -> unit = ignore) responses =
  let counter = ref 0 in
  let next () =
    on_call ();
    let idx = !counter in
    incr counter;
    match List.nth_opt responses idx with
    | Some resp -> resp
    | None -> text_response "default"
  in
  let structured_fn _model _tools _conv _schema = Ok (next ()) in
  { complete_fn = (fun _model _tools _conv -> Ok (next ()));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = Some structured_fn;
    list_models_fn = None;
  supports_native_tools_fn = None;
  context_window_fn = None; cache_control_fn = None;
  }

let mock_llm_with_error err =
  { complete_fn = (fun _model _tools _conv -> Error err);
    stream_fn = (fun _ _tools _ _ _ -> Error err);
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
  supports_native_tools_fn = None;
  context_window_fn = None; cache_control_fn = None;
  }

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let basic_agent ?(tools = []) ?(middleware = []) ?(max_iterations = 10) () =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id = "test-agent"; system_prompt = stable_prompt "You are a test agent.";
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations; middleware;
    retry_policy = None; context_strategy = None; resource_quota = None; max_execution_time = None; tool_timeout = None; early_stopping_method = Force; on_max_tokens = Some Return_partial; max_continuation_chunks = Some 3;
    context_compression_threshold = None; compression_cooldown_messages = None; context_window_override = None; cache_strategy = No_caching }

(* Person schema: required name (string) + age (integer), no extras. *)
let person_schema : Yojson.Safe.t =
  `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("name", `Assoc [("type", `String "string")]);
      ("age",  `Assoc [("type", `String "integer")]);
    ]);
    ("required", `List [`String "name"; `String "age"]);
    ("additionalProperties", `Bool false);
  ]

let valid_person_json : Yojson.Safe.t =
  `Assoc [("name", `String "Alice"); ("age", `Int 30)]

let get_string_field key json =
  match json with
  | `Assoc xs -> (match List.assoc_opt key xs with
                  | Some (`String s) -> s
                  | _ -> "MISSING")
  | _ -> "NOT_ASSOC"

let str_contains s sub =
  try ignore (Str.search_forward (Str.regexp_string sub) s 0); true
  with Not_found -> false

let structured_suite =
  ("Engine.run_structured", [

    Alcotest.test_case "1. happy path native (1 attempt)" `Quick (fun () ->
      let llm = mock_llm_with_structured
        [ text_response (Yojson.Safe.to_string valid_person_json) ] in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            llm token agent "Who is Alice?" with
        | Ok result ->
          Alcotest.(check int) "attempts" 1 result.attempts;
          Alcotest.(check string) "name field"
            "Alice" (get_string_field "name" result.value)
        | Error (e, _) ->
          Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    Alcotest.test_case "2. happy path fallback (1 attempt)" `Quick (fun () ->
      (* complete_structured_fn = None forces the fallback closure: the
         schema directive is prepended to the system message (ephemeral,
         only for the LLM call) and complete_fn runs. *)
      let llm = mock_llm [ text_response (Yojson.Safe.to_string valid_person_json) ] in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            llm token agent "Who is Alice?" with
        | Ok result ->
          Alcotest.(check int) "attempts" 1 result.attempts;
          Alcotest.(check string) "name field"
            "Alice" (get_string_field "name" result.value)
        | Error (e, _) ->
          Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    (* Separate test pins that the fallback actually injects the schema
       directive into the system message sent to complete_fn. *)
    Alcotest.test_case "2b. fallback injects schema directive into system msg" `Quick (fun () ->
      let received_convs : conversation list ref = ref [] in
      let capturing_llm = {
        complete_fn = (fun _model _tools conv ->
          received_convs := conv :: !received_convs;
          Ok (text_response (Yojson.Safe.to_string valid_person_json)));
        stream_fn = (fun _ _ _ _ _ -> Ok {
            final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
        close_fn = (fun () -> ());
        complete_structured_fn = None;
        list_models_fn = None;
  supports_native_tools_fn = None;
  context_window_fn = None; cache_control_fn = None;
      } in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            capturing_llm token agent "x" with
        | Ok _ ->
          (match !received_convs with
           | conv :: _ ->
             (match conv.messages with
              | sys_msg :: _ ->
                Alcotest.(check bool) "system message carries schema directive"
                  true
                  (match (Message.content_opt sys_msg) with
                   | Some t -> str_contains t "MUST respond with a valid JSON object"
                   | None -> false)
              | [] -> Alcotest.fail "no messages in captured conversation")
           | [] -> Alcotest.fail "complete_fn was not called")
        | Error (e, _) ->
          Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    Alcotest.test_case "3. repair loop succeeds on attempt 2" `Quick (fun () ->
      let llm = mock_llm_with_structured [
        text_response "Sure! Here is Alice: Alice is 30 years old.";
        text_response (Yojson.Safe.to_string valid_person_json);
      ] in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            ~max_repair_attempts:3 llm token agent "Who is Alice?" with
        | Ok result ->
          Alcotest.(check int) "attempts (repaired)" 2 result.attempts;
          Alcotest.(check string) "name field"
            "Alice" (get_string_field "name" result.value)
        | Error (e, _) ->
          Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    Alcotest.test_case "4. repair loop exhausts max_repair_attempts=2" `Quick (fun () ->
      let llm = mock_llm_with_structured [
        text_response "garbage 1";
        text_response "garbage 2";
      ] in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            ~max_repair_attempts:2 llm token agent "Who is Alice?" with
        | Ok _ ->
          Alcotest.fail "expected Error after exhausting attempts, got Ok"
        | Error (e, conv) ->
          (match e with
           | Invalid_input _ -> ()
           | other ->
             Alcotest.fail
               ("expected Invalid_input, got: " ^ error_to_string other));
          let assistant_count =
            List.length (List.filter (fun (m : message) ->
              m.role = Assistant) conv.messages) in
          Alcotest.(check int) "two assistant replies recorded" 2 assistant_count));

    Alcotest.test_case "5. JSON parse failure on all attempts" `Quick (fun () ->
      let llm = mock_llm_with_structured [
        text_response "totally not json 1";
        text_response "totally not json 2";
        text_response "totally not json 3";
      ] in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            ~max_repair_attempts:3 llm token agent "x" with
        | Ok _ -> Alcotest.fail "expected Error, got Ok"
        | Error (Invalid_input msg, _) ->
          Alcotest.(check bool) "error mentions JSON parse"
            true (str_contains msg "JSON")
        | Error (e, _) ->
          Alcotest.fail ("expected Invalid_input, got: " ^ error_to_string e)));

    Alcotest.test_case "6. schema validation failure on all attempts" `Quick (fun () ->
      let bad = `Assoc [("name", `String "Alice")] in
      let llm = mock_llm_with_structured [
        text_response (Yojson.Safe.to_string bad);
        text_response (Yojson.Safe.to_string bad);
        text_response (Yojson.Safe.to_string bad);
      ] in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            ~max_repair_attempts:3 llm token agent "x" with
        | Ok _ -> Alcotest.fail "expected Error, got Ok"
        | Error (Invalid_input _, _) -> ()
        | Error (e, _) ->
          Alcotest.fail ("expected Invalid_input, got: " ^ error_to_string e)));

    Alcotest.test_case "7. conversation chaining has repair messages" `Quick (fun () ->
      let llm = mock_llm_with_structured [
        text_response "not json";
        text_response (Yojson.Safe.to_string valid_person_json);
      ] in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            ~max_repair_attempts:3 llm token agent "Who is Alice?" with
        | Ok result ->
          Alcotest.(check int) "attempts" 2 result.attempts;
          (* After repair: [sys; user; assistant(bad); user(feedback);
             assistant(good)] = 5 messages. *)
          Alcotest.(check int) "conversation length"
            5 (List.length result.conversation.messages);
          let feedback_msg = List.nth result.conversation.messages 3 in
          Alcotest.(check bool) "4th message is User feedback"
            true (feedback_msg.role = User);
          Alcotest.(check bool) "feedback mentions JSON"
            true (match (Message.content_opt feedback_msg) with
                  | Some s -> str_contains s "JSON"
                  | None -> false)
        | Error (e, _) ->
          Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    Alcotest.test_case "8. cancellation mid-loop returns Error Timeout (BS-1)" `Quick (fun () ->
      (* The mock cancels the token after the first LLM response is delivered.
         When loop recurses for attempt 2, the top-of-loop check fires
         and aborts before any second LLM call. *)
      let cancelled_token_ref : cancellation_token option ref = ref None in
      let on_call_cancel () =
        (match !cancelled_token_ref with
         | Some tok -> tok.cancelled <- true
         | None -> ())
      in
      let llm = mock_llm_with_structured ~on_call:on_call_cancel [
        text_response "bad json attempt 1";
        text_response "would never be reached";
      ] in
      let agent = basic_agent () in
      with_token (fun token ->
        cancelled_token_ref := Some token;
        match Engine.run_structured ~response_schema:person_schema
            ~max_repair_attempts:5 llm token agent "x" with
        | Ok _ -> Alcotest.fail "expected Error, got Ok"
        | Error (e, _) ->
          (match e with
           | Timeout -> ()
           | other ->
             Alcotest.fail ("expected Timeout, got: " ^ error_to_string other))));

    Alcotest.test_case "9. middleware hooks fired (D2)" `Quick (fun () ->
      let before_fired = ref 0 in
      let after_fired = ref 0 in
      let on_before conv = incr before_fired; Some conv in
      let on_after resp = incr after_fired; Some resp in
      let llm = mock_llm_with_structured
        [ text_response (Yojson.Safe.to_string valid_person_json) ] in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            ~on_before_llm:(Some on_before)
            ~on_after_llm:(Some on_after)
            llm token agent "Who is Alice?" with
        | Ok _ ->
          Alcotest.(check int) "on_before_llm fired once" 1 !before_fired;
          Alcotest.(check int) "on_after_llm fired once" 1 !after_fired
        | Error (e, _) ->
          Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    Alcotest.test_case "10. on_repair_attempt callback invoked per repair" `Quick (fun () ->
      let repair_calls : (int * error_category) list ref = ref [] in
      let on_repair attempt err _conv =
        repair_calls := (attempt, err) :: !repair_calls
      in
      let llm = mock_llm_with_structured [
        text_response "bad 1";
        text_response "bad 2";
        text_response (Yojson.Safe.to_string valid_person_json);
      ] in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            ~max_repair_attempts:3
            ~on_repair_attempt:on_repair
            llm token agent "x" with
        | Ok result ->
          Alcotest.(check int) "attempts" 3 result.attempts;
          Alcotest.(check int) "two repair callbacks"
            2 (List.length !repair_calls);
          (* repair_calls is prepended each call, so head is most recent
             (the attempt-2 callback). *)
          (match !repair_calls with
           | (attempt2, _) :: _ ->
             Alcotest.(check int) "most recent repair attempt number" 2 attempt2
           | [] -> Alcotest.fail "expected at least one repair callback")
        | Error (e, _) ->
          Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    Alcotest.test_case "11. LLM network error propagates without retry" `Quick (fun () ->
      let llm = mock_llm_with_error (External_failure "test") in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            ~max_repair_attempts:5 llm token agent "x" with
        | Ok _ -> Alcotest.fail "expected Error, got Ok"
        | Error (e, _) ->
          (match e with
           | External_failure _ -> ()
           | other ->
             Alcotest.fail
               ("expected External_failure, got: " ^ error_to_string other))));

    Alcotest.test_case "12. schema validation with all required fields" `Quick (fun () ->
      let llm = mock_llm_with_structured
        [ text_response (Yojson.Safe.to_string valid_person_json) ] in
      let agent = basic_agent () in
      with_token (fun token ->
        match Engine.run_structured ~response_schema:person_schema
            llm token agent "x" with
        | Ok result ->
          Alcotest.(check int) "attempts" 1 result.attempts;
          Alcotest.(check string) "name" "Alice"
            (get_string_field "name" result.value);
          let missing_field = `Assoc [("name", `String "Bob")] in
          (match Validation.validate_tool_input_result person_schema missing_field with
           | Ok () -> Alcotest.fail "validator should reject missing required field"
           | Error _ -> ())
         | Error (e, _) ->
          Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)));

    Alcotest.test_case "13. ?conversation resumes existing conversation (GAP-2 fix)" `Quick (fun () ->
      let llm = mock_llm_with_structured
        [ text_response (Yojson.Safe.to_string valid_person_json);
          text_response (Yojson.Safe.to_string valid_person_json) ] in
      let agent = basic_agent () in
      with_token (fun token ->
        let conv1 = match Engine.run_structured ~response_schema:person_schema
            llm token agent "First" with
          | Ok r -> r.conversation
          | Error (e, _) -> Alcotest.fail ("first call: " ^ error_to_string e)
        in
        Alcotest.(check int) "first conv: sys + user + assistant" 3 (List.length conv1.messages);
        match Engine.run_structured ~response_schema:person_schema
            ~conversation:conv1
            llm token agent "Second" with
        | Ok r ->
          Alcotest.(check int) "resumed conv appends user+assistant" 5 (List.length r.conversation.messages);
          (match List.nth_opt r.conversation.messages 3 with
           | Some m ->
             (match Message.content_opt m with
              | Some "Second" -> ()
              | _ -> Alcotest.fail "4th message should be user 'Second'")
           | None -> Alcotest.fail "4th message missing")
        | Error (e, _) ->
          Alcotest.fail ("second call: " ^ error_to_string e)));
  ])

let () =
  Alcotest.run "test_engine_structured" [ structured_suite ]
