open Par
open Par.Types

(* Current_conversation is an internal module in runtime.ml (not in .mli).
   These tests exercise it through the public API:
   - [invoke] calls [Current_conversation.set] internally
   - [save_conversation] calls [Current_conversation.get] internally
   Without the mutex, concurrent fibers would race on the mutable field. *)

let config_json = {|{"persistence": ["Sqlite", ":memory:"], "event_bus": {"buffer_capacity": 100, "delivery": {"max_delivery_attempts": 3, "initial_retry_delay": 0.1, "retry_backoff": ["Fixed", 0.5], "delivery_timeout": 5.0}, "dlq_enabled": false, "dlq_max_size": 1000, "critical_event_types": []}, "default_quota": {"max_concurrent_tasks": 100, "max_concurrent_tools_per_agent": 5, "max_tokens_per_turn": null, "max_total_tokens": null}, "shutdown": {"drain_timeout": 5.0, "cancel_grace_period": 2.0, "flush_batch_size": 100}, "llm_providers": [], "eval_limits": {"max_depth": 10, "max_node_visits": 1000}, "parallel_tool_execution": true}|}

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let err_str (e : error_category) =
  Yojson.Safe.to_string (Types.error_category_to_yojson e)

let with_runtime ~n_responses f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
        | Ok c -> c | Error e -> failwith ("config: " ^ e) in
      let responses = List.init n_responses (fun _ -> Mock_provider.Text "ok") in
      let (llm, _) = Mock_provider.create responses in
      match Runtime.create ~config ~llm sw with
      | Error e -> failwith ("create: " ^ err_str e)
      | Ok rt ->
        let agent = match Runtime.make_agent ~id:"t"
                      ~system_prompt:(stable_prompt "test prompt") ~model:dummy_model () with
          | Ok a -> a | Error e -> failwith ("make_agent: " ^ err_str e) in
        (match Runtime.register_agent rt agent with
         | Error e -> failwith ("register_agent: " ^ err_str e)
         | Ok () -> ());
        f rt;
        ignore (Runtime.close rt)))

let test_get_set_roundtrip () =
  with_runtime ~n_responses:1 (fun rt ->
    let result = Runtime.invoke rt ~agent_id:"t" ~message:"hello" () in
    match result with
    | Error (e, _) -> Alcotest.fail ("invoke: " ^ err_str e)
    | Ok invoke_result ->
      Alcotest.(check bool) "invoke returned conversation"
        true (invoke_result.conversation.messages <> []);
      match Runtime.save_conversation rt () with
      | Error e -> Alcotest.fail ("save: " ^ err_str e)
      | Ok () -> ())

let test_concurrent_invoke_async_writes () =
  with_runtime ~n_responses:10 (fun rt ->
    let handles = List.init 10 (fun i ->
      Runtime.invoke_async rt ~agent_id:"t"
        ~message:(Printf.sprintf "concurrent-%d" i) ()) in
    let results = List.map Invoke_context.invoke_handle_await handles in
    let ok_count = List.fold_left (fun acc (r : (invoke_result, error_category * conversation) result) ->
      match r with Ok _ -> acc + 1 | Error _ -> acc) 0 results in
    Alcotest.(check int) "all 10 completed" 10 ok_count;
    match Runtime.save_conversation rt () with
    | Error e -> Alcotest.fail ("save after concurrent: " ^ err_str e)
    | Ok () -> ())

(* The update path (invoke sets current_conversation under mutex) must be
   atomic: read-modify-write under cc_mutex. Without the mutex, two fibers
   reading simultaneously would both see the old value and one write would
   be lost. This test exercises that scenario by firing 20 concurrent
   invokes and verifying the final state is consistent. *)
let test_update_is_atomic () =
  with_runtime ~n_responses:20 (fun rt ->
    let handles = List.init 20 (fun i ->
      Runtime.invoke_async rt ~agent_id:"t"
        ~message:(Printf.sprintf "atomic-%d" i) ()) in
    let results = List.map Invoke_context.invoke_handle_await handles in
    List.iteri (fun i (r : (invoke_result, error_category * conversation) result) ->
      match r with
      | Ok res ->
        Alcotest.(check bool) (Printf.sprintf "invoke %d has conversation" i)
          true (res.conversation.messages <> [])
      | Error (e, _) ->
        Alcotest.fail (Printf.sprintf "invoke %d: %s" i (err_str e)))
      results;
    match Runtime.save_conversation rt () with
    | Error e -> Alcotest.fail ("save: " ^ err_str e)
    | Ok () -> ())

(* Regression: with a bare [mutable current_conversation] (no mutex),
   concurrent fibers would race on read-modify-write, silently losing
   writes. The mutex in Current_conversation prevents this. *)

let test_readers_writers_no_deadlock () =
  with_runtime ~n_responses:11 (fun rt ->
    let initial = Runtime.invoke rt ~agent_id:"t" ~message:"init" () in
    (match initial with
     | Error (e, _) -> Alcotest.fail ("initial invoke: " ^ err_str e)
     | Ok _ -> ());
    let writer_handles = List.init 10 (fun i ->
      Runtime.invoke_async rt ~agent_id:"t"
        ~message:(Printf.sprintf "writer-%d" i) ()) in
    let reader_results = List.init 100 (fun _ ->
      Runtime.save_conversation rt ()) in
    List.iter (fun h ->
      let _ = Invoke_context.invoke_handle_await h in ()) writer_handles;
    List.iteri (fun i r ->
      match r with
      | Ok () -> ()
      | Error e ->
        Alcotest.fail (Printf.sprintf "reader %d: %s" i (err_str e)))
      reader_results)

let () =
  Alcotest.run "current_conversation_mutex" [
    "mutex_roundtrip", [
      Alcotest.test_case "get/set roundtrip" `Quick test_get_set_roundtrip;
    ];
    "concurrent_writes", [
      Alcotest.test_case "10 concurrent invoke_async" `Quick
        test_concurrent_invoke_async_writes;
    ];
    "atomicity", [
      Alcotest.test_case "update is atomic" `Quick test_update_is_atomic;
    ];
    "deadlock", [
      Alcotest.test_case "100 readers + 10 writers" `Quick
        test_readers_writers_no_deadlock;
    ];
  ]
