open Par

let () =
  Alcotest.run "noop_persistence" [
    ("lifecycle", [
      Alcotest.test_case "create_returns_ok" `Quick (fun () ->
        (match Noop_persistence.create ":memory:" with
         | Ok _ -> ()
         | Error e ->
           Alcotest.fail ("create failed: " ^
             Yojson.Safe.to_string (Types.error_category_to_yojson e))));

      Alcotest.test_case "close_is_noop" `Quick (fun () ->
        (match Noop_persistence.create ":memory:" with
         | Ok t -> Noop_persistence.close t
         | Error _ -> Alcotest.fail "create failed"));
    ]);

    ("event_operations", [
      Alcotest.test_case "save_then_load_returns_empty" `Quick (fun () ->
        (match Noop_persistence.create ":memory:" with
         | Ok t ->
           (match Noop_persistence.save_events t [] with
            | Ok () ->
              let result = Noop_persistence.load_events t (Types.Task_id.create ()) in
              (match result with
               | Ok events ->
                 Alcotest.(check int) "noop returns empty" 0 (List.length events)
               | Error _ -> Alcotest.fail "load_events failed")
            | Error _ -> Alcotest.fail "save_events failed")
         | Error _ -> Alcotest.fail "create failed"));

      Alcotest.test_case "transaction_passes_through" `Quick (fun () ->
        (match Noop_persistence.create ":memory:" with
         | Ok t ->
           (match Noop_persistence.transaction t (fun _t' -> Ok 42) with
            | Ok (Ok v) -> Alcotest.(check int) "transaction result" 42 v
            | Ok (Error _) -> Alcotest.fail "inner transaction returned Error"
            | Error _ -> Alcotest.fail "transaction failed")
         | Error _ -> Alcotest.fail "create failed"));
    ]);
  ]
