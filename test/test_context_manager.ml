open Par

let dummy_msg role content =
  { Types.role = role; content = Some content;
    tool_calls = None; tool_call_id = None; name = None }

let () =
  Alcotest.run "context_manager" [
    ("estimate_tokens", [
      Alcotest.test_case "empty_conversation_zero_tokens" `Quick (fun () ->
        let conv = { Types.messages = []; metadata = [] } in
        Alcotest.(check int) "empty conv" 0 (Context_manager.estimate_tokens conv));

      Alcotest.test_case "nonempty_counts_chars" `Quick (fun () ->
        let conv = {
          Types.messages = [dummy_msg Types.User (String.make 40 'x')];
          metadata = [];
        } in
        let tokens = Context_manager.estimate_tokens conv in
        Alcotest.(check bool) "40 chars → ~10 tokens" (tokens > 0 && tokens <= 15) true);
    ]);

    ("truncate_conversation", [
      Alcotest.test_case "small_conv_unchanged" `Quick (fun () ->
        let conv = {
          Types.messages = [dummy_msg Types.User "hello"];
          metadata = [];
        } in
        let truncated = Context_manager.truncate_conversation
          ~min_messages:1 ~max_tokens:1000 conv in
        Alcotest.(check int) "still 1 message"
          1 (List.length truncated.Types.messages));

      Alcotest.test_case "drops_oldest_to_fit_budget" `Quick (fun () ->
        let msgs = List.init 10 (fun i ->
          dummy_msg Types.User (String.make 100 (char_of_int (48 + i))))
        in
        let conv = { Types.messages = msgs; metadata = [] } in
        let truncated = Context_manager.truncate_conversation
          ~min_messages:2 ~max_tokens:50 conv in
        let n = List.length truncated.Types.messages in
        Alcotest.(check bool) "dropped some messages" (n < 10) true);
    ]);
  ]
