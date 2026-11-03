open Par
open Types

let tmp_db () =
  let p = Filename.temp_file "sessions" ".db" in
  Sys.remove p;
  p

let make_envelope i sid ts : event_envelope = {
  id = Printf.sprintf "eid-%d" i;
  metadata = {
    trace_id = None; span_id = None; timestamp = ts;
    source = "test"; session_id = sid;
  };
  payload = (if i mod 2 = 0 then
               Tool_invoked { task_id = Task_id.create (); tool_name = "calc" }
             else
               Llm_request_sent { task_id = Task_id.create (); model = "mock" });
  idempotency_key = Printf.sprintf "key-%d" i;
  delivery_attempt = 0;
}

let sample_conversation : conversation = {
  messages = [{
    role = User;
    content_blocks = Message.content_of_string "hello";
    tool_calls = None;
    tool_call_id = None;
    name = None;
  }];
  metadata = [];
}

let () =
  Alcotest.run "sessions" [
    "sessions", [
      Alcotest.test_case "load_sessions_returns_summaries" `Quick (fun () ->
        let db = tmp_db () in
        (match Sqlite_persistence.create db with
         | Error e -> Alcotest.fail ("create: " ^ Yojson.Safe.to_string (error_category_to_yojson e))
         | Ok t ->
           let sid = "test-session-001" in
           let events = List.init 5 (fun i -> make_envelope i sid (float_of_int i)) in
           (match Sqlite_persistence.save_events t events with
            | Error e -> Sqlite_persistence.close t; Alcotest.fail ("save: " ^ Yojson.Safe.to_string (error_category_to_yojson e))
            | Ok () ->
              (match Sqlite_persistence.load_sessions t 10 with
               | Error e -> Sqlite_persistence.close t; Alcotest.fail ("load_sessions: " ^ Yojson.Safe.to_string (error_category_to_yojson e))
               | Ok ss ->
                 Alcotest.(check bool) "at least 1 session" true (List.length ss >= 1);
                 let s = List.find (fun (s : session_summary) -> s.session_id = sid) ss in
                 Alcotest.(check int) "event_count" 5 s.event_count;
                 Sqlite_persistence.close t))));

      Alcotest.test_case "load_sessions_respects_limit" `Quick (fun () ->
        let db = tmp_db () in
        (match Sqlite_persistence.create db with
         | Error _ -> Alcotest.fail "create failed"
         | Ok t ->
           List.iteri (fun i _ ->
             let sid = Printf.sprintf "session-limit-%d" i in
              let events = [ make_envelope i sid (float_of_int i) ] in
             ignore (Sqlite_persistence.save_events t events)
           ) (List.init 5 (fun i -> i));
           (match Sqlite_persistence.load_sessions t 3 with
             | Error _ -> Sqlite_persistence.close t; Alcotest.fail "load failed"
            | Ok ss ->
              Alcotest.(check int) "respects limit" 3 (List.length ss);
              Sqlite_persistence.close t)));

      Alcotest.test_case "load_events_by_session_returns_correct_events" `Quick (fun () ->
        let db = tmp_db () in
        (match Sqlite_persistence.create db with
         | Error _ -> Alcotest.fail "create failed"
         | Ok t ->
           let sid = "test-order-session" in
           let events = List.init 3 (fun i -> make_envelope i sid (float_of_int i)) in
           ignore (Sqlite_persistence.save_events t events);
           (match Sqlite_persistence.load_events_by_session t sid with
             | Error _ -> Sqlite_persistence.close t; Alcotest.fail "load failed"
            | Ok evs ->
              Alcotest.(check int) "3 events returned" 3 (List.length evs);
              Sqlite_persistence.close t)));

      Alcotest.test_case "scope_filters_sessions" `Quick (fun () ->
        let db = tmp_db () in
        (match Sqlite_persistence.create db with
         | Error _ -> Alcotest.fail "create failed"
         | Ok t ->
           let env_a1 = make_envelope 0 "s1" 1.0 in
           let env_a2 = make_envelope 1 "s2" 2.0 in
           let env_b  = make_envelope 2 "s3" 3.0 in
           ignore (Sqlite_persistence.save_events ~scope:"A" t [env_a1]);
           ignore (Sqlite_persistence.save_events ~scope:"A" t [env_a2]);
           ignore (Sqlite_persistence.save_events ~scope:"B" t [env_b]);
           (match Sqlite_persistence.load_sessions ~scope:"A" t 100 with
            | Error _ -> Sqlite_persistence.close t; Alcotest.fail "load A failed"
            | Ok ss ->
              Alcotest.(check int) "scope A has 2 sessions" 2 (List.length ss));
           (match Sqlite_persistence.load_sessions ~scope:"B" t 100 with
            | Error _ -> Sqlite_persistence.close t; Alcotest.fail "load B failed"
            | Ok ss ->
              Alcotest.(check int) "scope B has 1 session" 1 (List.length ss));
           (match Sqlite_persistence.load_sessions t 100 with
            | Error _ -> Sqlite_persistence.close t; Alcotest.fail "load all failed"
            | Ok ss ->
              Alcotest.(check int) "no scope has all 3 sessions" 3 (List.length ss));
           Sqlite_persistence.close t));

      Alcotest.test_case "load_conversations_includes_eventless_sessions" `Quick (fun () ->
        let db = tmp_db () in
        (match Sqlite_persistence.create db with
         | Error _ -> Alcotest.fail "create failed"
         | Ok t ->
           ignore (Sqlite_persistence.save_conversation ~scope:"A" t "conv-a" sample_conversation);
           ignore (Sqlite_persistence.save_conversation t "conv-b" sample_conversation);
           (match Sqlite_persistence.load_conversations t 10 with
            | Error _ -> Sqlite_persistence.close t; Alcotest.fail "load_conversations failed"
            | Ok ss ->
              Alcotest.(check int) "both conversations listed" 2 (List.length ss);
              (match List.find_opt (fun (s : conversation_summary) ->
                       s.session_id = "conv-b") ss with
               | Some s ->
                 Alcotest.(check int) "turn_count" 1 s.turn_count;
                 Alcotest.(check (option string)) "unscoped" None s.scope
               | None -> Alcotest.fail "conv-b missing"));
           (match Sqlite_persistence.load_conversations ~scope:"A" t 10 with
            | Ok [s] ->
              Alcotest.(check string) "scope filter" "conv-a" s.session_id;
              Alcotest.(check (option string)) "scope recorded" (Some "A") s.scope
            | Ok _ -> Alcotest.fail "expected exactly one scoped conversation"
            | Error _ -> Alcotest.fail "scoped load failed");
           (match Sqlite_persistence.load_conversations t 1 with
            | Ok [_] -> ()
            | Ok _ -> Alcotest.fail "limit not respected"
            | Error _ -> Alcotest.fail "limited load failed");
           Sqlite_persistence.close t));
    ]
  ]
