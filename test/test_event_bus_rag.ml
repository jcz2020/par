open Par.Types

let () =
  let open Alcotest in
  let tests = [
    test_case "construct + serialize embedding events" `Quick (fun () ->
      let e1 = Embedding_request_sent { model = "text-embedding-3-small"; input_count = 5 } in
      let e2 = Embedding_response_received { model = "text-embedding-3-small"; output_count = 5; duration_ms = 120.0 } in
      let e3 = Retrieval_completed { query_count = 1; retrieved_count = 4; top_k = 4 } in
      let json1 = event_to_yojson e1 in
      let json2 = event_to_yojson e2 in
      let json3 = event_to_yojson e3 in
      check bool "json1 non-null" true (json1 <> `Null);
      check bool "json2 non-null" true (json2 <> `Null);
      check bool "json3 non-null" true (json3 <> `Null));

    test_case "round-trip embedding events" `Quick (fun () ->
      let e = Embedding_request_sent { model = "test"; input_count = 3 } in
      let json = event_to_yojson e in
      (match event_of_yojson json with
       | Ok (Embedding_request_sent { model; input_count = _ }) ->
         check string "model roundtrip" "test" model
       | Ok _ -> fail "wrong variant after roundtrip"
       | Error msg -> failwith ("roundtrip failed: " ^ msg)));

    test_case "retrieval event round-trip" `Quick (fun () ->
      let e = Retrieval_completed { query_count = 2; retrieved_count = 8; top_k = 4 } in
      let json = event_to_yojson e in
      (match event_of_yojson json with
       | Ok (Retrieval_completed { query_count; retrieved_count; top_k }) ->
         check int "query_count" 2 query_count;
         check int "retrieved_count" 8 retrieved_count;
         check int "top_k" 4 top_k
       | Ok _ -> fail "wrong variant"
       | Error msg -> failwith ("roundtrip failed: " ^ msg)));
  ] in
  run "event_bus_rag" [ "rag_events", tests ]
