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
    ]
  ]
