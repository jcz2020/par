open Par
open Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None; context_window = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; reasoning = []; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let last_user_text conv =
  match List.rev conv.messages with
  | msg :: _ -> Message.text_of_message msg
  | [] -> ""

let mock_llm : llm_service =
  { complete_fn = (fun _model _tools conv ->
      Ok (text_response ("reply:" ^ last_user_text conv)));
    stream_fn = (fun _ _ _ _ _ -> Error Timeout);
    close_fn = (ignore : unit -> unit);
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None }

let err_str (e : error_category) =
  Yojson.Safe.to_string (error_category_to_yojson e)

let runtime_config : runtime_config =
  { persistence = `Sqlite ":memory:";
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = true;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = 604800.0;
    max_tool_schema_tokens = None;
  }

let with_persisted_runtime (f : Runtime.runtime -> 'a) : 'a =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      match Sqlite_persistence.create ":memory:" with
      | Error e -> Alcotest.fail ("sqlite create: " ^ err_str e)
      | Ok sqlt ->
        let persist : persistence_service = {
          save_events_fn = (fun ?scope envs -> Sqlite_persistence.save_events ?scope sqlt envs);
          load_events_fn = (fun tid -> Sqlite_persistence.load_events sqlt tid);
          load_events_by_session_fn =
            (fun ?scope sid -> Sqlite_persistence.load_events_by_session ?scope sqlt sid);
          load_sessions_fn = (fun ?scope lim -> Sqlite_persistence.load_sessions ?scope sqlt lim);
          save_task_state_fn = (fun ts -> Sqlite_persistence.save_task_state sqlt ts);
          load_task_state_fn = (fun tid -> Sqlite_persistence.load_task_state sqlt tid);
          save_workflow_state_fn =
            (fun id st cp -> Sqlite_persistence.save_workflow_state sqlt id st cp);
          load_workflow_state_fn =
            (fun id -> Sqlite_persistence.load_workflow_state sqlt id);
          load_recoverable_runs_fn =
            (fun () -> Sqlite_persistence.load_recoverable_runs sqlt);
          save_workflow_def_fn =
            (fun id def -> Sqlite_persistence.save_workflow_def sqlt id def);
          load_all_workflow_defs_fn =
            (fun () -> Sqlite_persistence.load_all_workflow_defs sqlt);
          save_conversation_fn =
            (fun ?scope sid conv -> Sqlite_persistence.save_conversation ?scope sqlt sid conv);
          load_conversation_fn =
            (fun sid -> Sqlite_persistence.load_conversation sqlt sid);
          load_most_recent_conversation_fn =
            (fun ?scope () -> Sqlite_persistence.load_most_recent_conversation ?scope sqlt);
          load_conversations_fn =
            (fun ?scope limit -> Sqlite_persistence.load_conversations ?scope sqlt limit);
          save_pending_approval_fn =
            (fun ~run_id ~agent_id ~payload ~expires_at ->
              Sqlite_persistence.save_pending_approval sqlt ~run_id ~agent_id ~payload ~expires_at);
          load_pending_approval_fn =
            (fun ~run_id -> Sqlite_persistence.load_pending_approval sqlt ~run_id);
          delete_pending_approval_fn =
            (fun ~run_id -> Sqlite_persistence.delete_pending_approval sqlt ~run_id);
          save_invoke_checkpoint_fn = (fun cp -> Sqlite_persistence.save_invoke_checkpoint sqlt cp);
          load_invoke_checkpoint_fn = (fun id -> Sqlite_persistence.load_invoke_checkpoint sqlt id);
          list_invoke_checkpoints_fn = (fun () -> Sqlite_persistence.list_invoke_checkpoints sqlt);
          delete_invoke_checkpoint_fn = (fun id -> Sqlite_persistence.delete_invoke_checkpoint sqlt id);
          close_fn = (fun () -> Sqlite_persistence.close sqlt);
        } in
        match Runtime.create ~llm:mock_llm ~persistence:persist
                ~config:runtime_config sw with
        | Error e ->
          (try Sqlite_persistence.close sqlt with _ -> ());
          Alcotest.fail ("Runtime.create: " ^ err_str e)
        | Ok rt ->
          let agent = match Runtime.make_agent ~id:"echo"
                        ~system_prompt:(stable_prompt "test") ~model:dummy_model () with
            | Ok a -> a | Error e -> Alcotest.fail ("make_agent: " ^ err_str e)
          in
          (match Runtime.register_agent rt agent with
           | Error e -> Alcotest.fail ("register_agent: " ^ err_str e)
           | Ok () -> ());
          let result =
            try f rt
            with exn ->
              ignore (Runtime.close rt);
              raise exn
          in
          ignore (Runtime.close rt);
          result))

let conversation_contains conv needle =
  List.exists (fun (m : message) ->
    try ignore (Str.search_forward (Str.regexp_string needle)
                  (Message.text_of_message m) 0); true
    with Not_found -> false) conv.messages

let test_async_flags () =
  with_persisted_runtime (fun rt ->
    Runtime.set_session_id rt "parent";
    (match Runtime.invoke rt ~agent_id:"echo" ~message:"parent" ~save:true () with
     | Ok _ -> ()
     | Error (e, _) -> Alcotest.fail ("parent invoke: " ^ err_str e));
    let parent_before = match Runtime.load_conversation rt "parent" with
      | Ok (Some c) -> c
      | Ok None -> Alcotest.fail "parent conversation missing"
      | Error e -> Alcotest.fail ("load parent: " ^ err_str e)
    in
    Alcotest.(check bool) "parent saved" true
      (conversation_contains parent_before "reply:parent");

    (* Background branch: no save, no current-conversation replacement. *)
    let h = Runtime.invoke_async rt ~agent_id:"echo" ~message:"child"
              ~update_current:false ~save:false () in
    (match Invoke_context.invoke_handle_await h with
     | Ok _ -> ()
     | Error (e, _) -> Alcotest.fail ("child async: " ^ err_str e));
    let parent_after = match Runtime.load_conversation rt "parent" with
      | Ok (Some c) -> c
      | Ok None -> Alcotest.fail "parent conversation disappeared"
      | Error e -> Alcotest.fail ("reload parent: " ^ err_str e)
    in
    Alcotest.(check bool) "parent unchanged" true
      (conversation_contains parent_after "reply:parent"
       && not (conversation_contains parent_after "reply:child"));

    (* Explicit save with an isolated session context. *)
    let ctx = Invoke_context.create ~session_id:"child-session" () in
    let h = Runtime.invoke_async rt ~agent_id:"echo" ~message:"child-save"
              ~context:ctx ~update_current:false ~save:true () in
    (match Invoke_context.invoke_handle_await h with
     | Ok _ -> ()
     | Error (e, _) -> Alcotest.fail ("child save async: " ^ err_str e));
    (match Runtime.load_conversation rt "child-session" with
     | Ok (Some c) ->
       Alcotest.(check bool) "child saved in its own session" true
         (conversation_contains c "reply:child-save")
     | Ok None -> Alcotest.fail "child conversation was not saved"
     | Error e -> Alcotest.fail ("load child: " ^ err_str e));

    (match Runtime.list_conversations rt ~limit:10 () with
     | Ok summaries ->
       let ids = List.map (fun (s : conversation_summary) -> s.session_id) summaries in
       Alcotest.(check bool) "parent listed" true (List.mem "parent" ids);
       Alcotest.(check bool) "child listed" true (List.mem "child-session" ids);
       List.iter (fun (s : conversation_summary) ->
         Alcotest.(check bool) ("turn_count for " ^ s.session_id) true
           (s.turn_count > 0)) summaries
     | Error e -> Alcotest.fail ("list_conversations: " ^ err_str e)))

let test_cancel_first_cause_wins () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      Alcotest.(check bool) "initially live" false (Cancellation.is_cancelled token);
      Cancellation.request_cancel token User_cancelled;
      Cancellation.request_cancel token (Guard_cancelled "later");
      Alcotest.(check bool) "cancelled" true (Cancellation.is_cancelled token);
      Alcotest.(check (option string)) "first reason wins"
        (Some "User_cancelled")
        (match Cancellation.reason token with
         | Some User_cancelled -> Some "User_cancelled"
         | Some (Guard_cancelled s) -> Some s
         | None -> None)))

let () =
  Alcotest.run "invoke_async_isolation" [
    "async", [
      Alcotest.test_case "save_and_update_current_flags" `Quick test_async_flags;
      Alcotest.test_case "cancel_first_cause_wins" `Quick test_cancel_first_cause_wins;
    ]
  ]
