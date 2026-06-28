(* test_session_resume_cli.ml

   RED test for the CLI session-resume fix (sibling task T1.1).

   Contract under test (post-fix behavior — currently BROKEN on main):

     - [par -c <id>]  [Runtime.load_conversation rt sid] MUST restore
        [rt.session_id] to [sid], so a subsequent [Runtime.invoke] reuses
        [sid] instead of minting a new one. Today [load_conversation] sets
        only [rt.current_conversation]; [rt.session_id] stays [None], so
        the lazy [get_session_id] (and [invoke]) allocates a fresh session
        id — breaking resume.

     - [par ask]      The [cmd_ask] code path must [save_conversation]
        after [invoke] so the conversation is durable for later resume.

     - [par -r]       [Runtime.load_most_recent_conversation] already
        follows the correct pattern (sets BOTH [session_id] AND
        [current_conversation]). Pinned here so the T1.1 fix to
        [load_conversation] does not regress it.

   RED against main: at minimum
   "load_conversation_by_id_restores_session_id" fails because
   [Runtime.get_session_id] after [load_conversation] returns a
   freshly-minted id rather than the loaded sid. *)
open Par
open Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let mock_llm : llm_service =
  { complete_fn = (fun _model _tools _conv -> Ok (text_response "mock answer"));
    stream_fn = (fun _ _tools _ _ _ ->
      Ok { final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = ignore;
    complete_structured_fn = None;
    list_models_fn = None;
  supports_native_tools_fn = None;
  }

let err_str (e : error_category) =
  Yojson.Safe.to_string (error_category_to_yojson e)

let make_runtime_config db : runtime_config =
  {
    persistence = `Sqlite db;
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = true;
    bash_confirm = Types.default_bash_confirm_config;
    event_retention_seconds = 604800.0;
  }

let make_persist (sqlt : Sqlite_persistence.t) : persistence_service =
  {
    save_events_fn = (fun envs -> Sqlite_persistence.save_events sqlt envs);
    load_events_fn = (fun tid -> Sqlite_persistence.load_events sqlt tid);
    load_events_by_session_fn =
      (fun sid -> Sqlite_persistence.load_events_by_session sqlt sid);
    load_sessions_fn = (fun lim -> Sqlite_persistence.load_sessions sqlt lim);
    save_task_state_fn =
      (fun ts -> Sqlite_persistence.save_task_state sqlt ts);
    load_task_state_fn =
      (fun tid -> Sqlite_persistence.load_task_state sqlt tid);
    save_workflow_state_fn =
      (fun id st cp -> Sqlite_persistence.save_workflow_state sqlt id st cp);
    load_workflow_state_fn =
      (fun id -> Sqlite_persistence.load_workflow_state sqlt id);
    save_conversation_fn =
      (fun sid conv -> Sqlite_persistence.save_conversation sqlt sid conv);
    load_conversation_fn =
      (fun sid -> Sqlite_persistence.load_conversation sqlt sid);
    load_most_recent_conversation_fn =
      (fun () -> Sqlite_persistence.load_most_recent_conversation sqlt);
    close_fn = (fun () -> Sqlite_persistence.close sqlt);
  }

let make_test_agent id =
  match Runtime.make_agent ~id ~system_prompt:("You are " ^ id)
          ~model:dummy_model ~max_iterations:5 () with
  | Ok a -> a
  | Error e -> Alcotest.fail ("make_agent failed: " ^ err_str e)

(* Each call opens a fresh sqlite handle on [db], so two sequential calls
   on the same [db] simulate two CLI processes sharing the on-disk store
   (exactly what `par -c` / `par -r` do).

   [Runtime.close] itself calls [persistence.close_fn], which closes the
   sqlite handle — do not double-close. *)
let with_runtime db ?(register_agent = true) f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      match Sqlite_persistence.create db with
      | Error e -> Alcotest.fail ("sqlite create: " ^ err_str e)
      | Ok sqlt ->
        let persist = make_persist sqlt in
        (match Runtime.create ~llm:mock_llm ~persistence:persist
                ~config:(make_runtime_config db) sw with
         | Error e ->
           (* Runtime was not created, so Runtime.close never ran and never
              invoked persistence.close_fn — close sqlite directly. *)
           (try Sqlite_persistence.close sqlt with _ -> ());
           Alcotest.fail ("Runtime.create: " ^ err_str e)
         | Ok rt ->
           if register_agent then begin
             let agent = make_test_agent "test-agent" in
             (match Runtime.register_agent rt agent with
              | Error e ->
                ignore (Runtime.close rt);
                Alcotest.fail ("register_agent: " ^ err_str e)
              | Ok () -> ())
           end;
           let result =
             try f rt
             with exn ->
               ignore (Runtime.close rt);
               raise exn
           in
           ignore (Runtime.close rt);
           result)))

let invoke_ok_or_fail rt msg =
  match Runtime.invoke rt ~agent_id:"test-agent" ~message:msg () with
  | Ok _ -> ()
  | Error (e, _) -> Alcotest.fail ("invoke failed: " ^ err_str e)

let with_tmp_db suffix f =
  let db = Filename.temp_file suffix ".db" in
  Sys.remove db;
  let cleanup () = (try Sys.remove db with _ -> ()) in
  match f db with
  | r -> cleanup (); r
  | exception exn -> cleanup (); raise exn

let () =
  Alcotest.run "session_resume_cli" [
    ("par -c <id>", [
      (* Contract: after `par -c <sid>` loads a conversation, a subsequent
         Runtime.invoke MUST reuse <sid> rather than minting a new one.

         Two-process flow mirroring the CLI:
           Process 1 (prior session): set session id, invoke, save.
           Process 2 (`par -c <sid>`): load_conversation, then check sid.

         RED on main: load_conversation does NOT set rt.session_id, so
         get_session_id mints a fresh id — resume is broken. *)
      Alcotest.test_case "load_conversation_by_id_restores_session_id" `Quick
        (fun () ->
          with_tmp_db "resume_by_id" (fun db ->
            (* Phase 1: prior par session, sid = "S1" *)
            with_runtime db (fun rt ->
              Runtime.set_session_id rt "S1";
              invoke_ok_or_fail rt "hello";
              match Runtime.save_conversation rt with
              | Ok () -> ()
              | Error e -> Alcotest.fail ("save phase 1: " ^ err_str e));
            (* Phase 2: par -c S1 *)
            with_runtime db ~register_agent:false (fun rt ->
              (match Runtime.load_conversation rt "S1" with
               | Ok (Some _conv) -> ()
               | Ok None -> Alcotest.fail
                   "load_conversation returned None for known sid"
               | Error e -> Alcotest.fail
                   ("load_conversation: " ^ err_str e));
              (* POST-FIX CONTRACT.
                 RED today: get_session_id mints a fresh id because
                 load_conversation left rt.session_id = None. *)
              Alcotest.(check string)
                "session_id restored after load_conversation"
                "S1" (Runtime.get_session_id rt))));
    ]);

    ("par ask", [
      (* Contract: the `par ask` flow (Runtime.invoke + Runtime.save_conversation)
         leaves the conversation on disk so a later load by sid recovers it.

         cmd_ask does not call save_conversation today; T1.1 routes it
         through Runtime.save_conversation. This test pins the runtime
         half of that contract: save then load round-trips. *)
      Alcotest.test_case "ask_then_load_by_session_id_round_trip" `Quick
        (fun () ->
          with_tmp_db "resume_ask" (fun db ->
            let saved_sid = ref "" in
            (* Phase 1: par ask — invoke, capture sid, save *)
            with_runtime db (fun rt ->
              invoke_ok_or_fail rt "what is 2+2?";
              saved_sid := Runtime.get_session_id rt;
              match Runtime.save_conversation rt with
              | Ok () -> ()
              | Error e -> Alcotest.fail ("save: " ^ err_str e));
            (* Phase 2: later par -c <sid> recovers the conversation *)
            with_runtime db ~register_agent:false (fun rt ->
              (match Runtime.load_conversation rt !saved_sid with
               | Ok (Some conv) ->
                 Alcotest.(check bool) "loaded conversation has messages"
                   true (List.length conv.messages > 0)
               | Ok None -> Alcotest.fail
                   "load_conversation returned None after save"
               | Error e -> Alcotest.fail ("load: " ^ err_str e)))));
    ]);

    ("par -r", [
      (* Contract: load_most_recent_conversation restores BOTH the
         conversation AND the session id. This is the correct pattern
         that load_conversation should mirror; pinned here so T1.1
         does not regress it. *)
      Alcotest.test_case "load_most_recent_restores_session_id_and_conv" `Quick
        (fun () ->
          with_tmp_db "resume_recent" (fun db ->
            (* Phase 1: prior session, sid = "recent-S2" *)
            with_runtime db (fun rt ->
              Runtime.set_session_id rt "recent-S2";
              invoke_ok_or_fail rt "remember this";
              match Runtime.save_conversation rt with
              | Ok () -> ()
              | Error e -> Alcotest.fail ("save: " ^ err_str e));
            (* Phase 2: par -r *)
            with_runtime db ~register_agent:false (fun rt ->
              (match Runtime.load_most_recent_conversation rt with
               | Ok (Some (sid, conv)) ->
                 Alcotest.(check string)
                   "most-recent sid matches" "recent-S2" sid;
                 Alcotest.(check bool) "most-recent conv has messages"
                   true (List.length conv.messages > 0);
                 Alcotest.(check string)
                   "session_id restored after load_most_recent"
                   "recent-S2" (Runtime.get_session_id rt)
               | Ok None -> Alcotest.fail "no prior session found"
               | Error e -> Alcotest.fail
                   ("load_most_recent: " ^ err_str e)))));
    ]);
  ]
