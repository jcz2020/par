open Par
open Types

let msg ?(calls = []) ?tool_call_id ?name role text : message =
  { role;
    content_blocks = [Text_block { text; cache_control = None }];
    tool_calls = (if calls = [] then None else Some calls);
    tool_call_id;
    name;
  }

let call ?(args = `Assoc []) id name : tool_call =
  { id; name; arguments = args }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let summary_llm : llm_service =
  { complete_fn = (fun model _tools _conv ->
      Ok { text = Some "summary"; reasoning = []; tool_calls = None;
           finish_reason = Stop; usage = dummy_usage;
           model = model.model_name });
    stream_fn = (fun _ _ _ _ _ -> failwith "stream_fn should not be called");
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None }

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None }

let tool_pair_conv () : conversation =
  { messages = [
      msg System "sys";
      msg User "u1";
      msg ~calls:[call "tc1" "search"; call "tc2" "fetch"] Assistant "";
      msg ~tool_call_id:"tc1" Tool "result 1";
      msg ~tool_call_id:"tc2" Tool "result 2";
      msg User "u2";
      msg ~calls:[call "tc3" "read"] Assistant "";
      msg ~tool_call_id:"tc3" Tool "result 3";
      msg User "u3";
    ];
    metadata = [];
  }

let contains needle haystack =
  try ignore (Str.search_forward (Str.regexp_string needle) haystack 0); true
  with Not_found -> false

let () =
  Alcotest.run "conversation_repair" [
    ("normalize_arguments", [
      Alcotest.test_case "non_object_arguments_become_empty_object" `Quick (fun () ->
        let conv = { messages = [
            msg ~calls:[call ~args:`Null "tc1" "a";
                        call ~args:(`List []) "tc2" "b";
                        call ~args:(`String "x") "tc3" "c";
                        call ~args:(`Assoc [("q", `String "ok")]) "tc4" "d"] Assistant "";
          ]; metadata = [] } in
        let conv' = Conversation_repair.normalize_arguments conv in
        let calls = match conv'.messages with
          | [{ tool_calls = Some calls; _ }] -> calls
          | _ -> Alcotest.fail "expected one assistant message with calls"
        in
        List.iter (fun (tc : tool_call) ->
          Alcotest.(check bool) ("object: " ^ tc.id) true
            (match tc.arguments with `Assoc _ -> true | _ -> false)
        ) calls;
        let args_of id =
          match List.find_opt (fun (tc : tool_call) -> tc.id = id) calls with
          | Some tc -> tc.arguments
          | None -> Alcotest.failf "missing %s" id
        in
        Alcotest.(check string) "null -> {}" "{}"
          (Yojson.Safe.to_string (args_of "tc1"));
        Alcotest.(check string) "valid object preserved" {|{"q":"ok"}|}
          (Yojson.Safe.to_string (args_of "tc4")));
    ]);

    ("repair_tool_pairs", [
      Alcotest.test_case "drops_leading_orphan_tool_result" `Quick (fun () ->
        let conv = { messages = [
            msg ~tool_call_id:"gone" Tool "orphan";
            msg User "hello";
          ]; metadata = [] } in
        let repaired = Conversation_repair.repair_tool_pairs conv in
        Alcotest.(check int) "orphan dropped" 1 (List.length repaired.messages);
        (match repaired.messages with
         | [{ role = User; _ }] -> ()
         | _ -> Alcotest.fail "expected only the User message"));

      Alcotest.test_case "synthesizes_missing_tool_result" `Quick (fun () ->
        let conv = { messages = [
            msg ~calls:[call "tc1" "search"] Assistant "calling";
            msg User "next";
          ]; metadata = [] } in
        let repaired = Conversation_repair.repair_tool_pairs conv in
        Alcotest.(check int) "synthetic result inserted" 3
          (List.length repaired.messages);
        (match repaired.messages with
         | [_assistant; tool; { role = User; _ }] ->
           Alcotest.(check bool) "tool id preserved" true
             (tool.tool_call_id = Some "tc1");
           Alcotest.(check bool) "repair marker present" true
             (contains "context repair" (Message.text_of_message tool))
         | _ -> Alcotest.fail "expected assistant/tool/user"));

      Alcotest.test_case "valid_pairing_is_unchanged" `Quick (fun () ->
        let conv = tool_pair_conv () in
        let repaired = Conversation_repair.repair_tool_pairs conv in
        Alcotest.(check int) "message count unchanged"
          (List.length conv.messages) (List.length repaired.messages));
    ]);

    ("validate", [
      Alcotest.test_case "accepts_well_formed_tool_pairs" `Quick (fun () ->
        Alcotest.(check bool) "valid" true
          (Conversation_repair.validate (tool_pair_conv ()) = Ok ()));

      Alcotest.test_case "rejects_orphan_tool_result_with_id" `Quick (fun () ->
        let conv = { messages = [
            msg User "hi";
            msg ~tool_call_id:"tc_orphan" Tool "orphan";
          ]; metadata = [] } in
        match Conversation_repair.validate conv with
        | Ok () -> Alcotest.fail "expected Error"
        | Error msg ->
          Alcotest.(check bool) "mentions id" true (contains "tc_orphan" msg));

      Alcotest.test_case "accepts_dangling_call_for_handoff" `Quick (fun () ->
        let conv = { messages = [
            msg User "hi";
            msg ~calls:[call "tc_handoff" "handoff"] Assistant "";
          ]; metadata = [] } in
        Alcotest.(check bool) "handoff call without result is allowed" true
          (Conversation_repair.validate conv = Ok ()));

      Alcotest.test_case "rejects_non_object_arguments" `Quick (fun () ->
        let conv = { messages = [
            msg User "hi";
            msg ~calls:[call ~args:`Null "tc_null" "search"] Assistant "";
            msg ~tool_call_id:"tc_null" Tool "result";
          ]; metadata = [] } in
        match Conversation_repair.validate conv with
        | Ok () -> Alcotest.fail "expected Error"
        | Error msg ->
          Alcotest.(check bool) "mentions id" true (contains "tc_null" msg));
    ]);

    ("truncate_conversation", [
      Alcotest.test_case "every_cut_is_provider_valid" `Quick (fun () ->
        let conv = tool_pair_conv () in
        for max_tokens = 1 to 400 do
          for min_messages = 1 to 5 do
            List.iter (fun keep_system ->
              let truncated = Context_manager.truncate_conversation
                ~keep_system ~min_messages ~max_tokens conv in
              match Conversation_repair.validate truncated with
              | Ok () -> ()
              | Error msg ->
                Alcotest.failf
                  "max_tokens=%d min_messages=%d keep_system=%b: %s"
                  max_tokens min_messages keep_system msg
            ) [true; false]
          done
        done);

      Alcotest.test_case "sliding_window_result_is_provider_valid" `Quick (fun () ->
        let conv = tool_pair_conv () in
        match Context_manager.apply_strategy
                (Sliding_window { max_messages = 1; max_tokens = 1 })
                conv None ~on_event:None with
        | Error _ -> Alcotest.fail "expected Ok"
        | Ok conv' ->
          (match Conversation_repair.validate conv' with
           | Ok () -> ()
           | Error msg -> Alcotest.fail ("sliding window invalid: " ^ msg)));

      Alcotest.test_case "summarize_result_is_provider_valid" `Quick (fun () ->
        let conv = tool_pair_conv () in
        match Context_manager.apply_strategy ~default_model:dummy_model
                (Summarize { max_tokens = 1; summary_model = None })
                conv (Some summary_llm) ~on_event:None with
        | Error _ -> Alcotest.fail "expected Ok"
        | Ok conv' ->
          (match Conversation_repair.validate conv' with
           | Ok () -> ()
           | Error msg -> Alcotest.fail ("summarize invalid: " ^ msg)));
    ]);
  ]
