let vec0_available =
  let db = Sqlite3.db_open ":memory:" in
  let r = Sqlite3.enable_load_extension db true in
  ignore (Sqlite3.db_close db);
  r

let () =
  if not vec0_available then begin
    print_endline "[SKIP] SQLite load_extension not available";
    exit 0
  end
open Par

let make_test_memory svc =
  let open Par_memory in
  { Types.add_fn = (fun ~content ?summary ?scope ?metadata ?categories ?source () ->
    match svc.Memory_service.add_fn ~content ?summary ?scope ?metadata ?categories ?source () with
    | Ok obj -> Ok (Memory_object.to_yojson obj)
    | Error e -> Error (Types.Internal (Memory_error.to_string e)));
    search_fn = (fun ?scope ?limit query ->
      match svc.Memory_service.search_fn ?scope ?limit query with
      | Ok objs -> Ok (List.map Memory_object.to_yojson objs)
      | Error e -> Error (Types.Internal (Memory_error.to_string e)));
    update_fn = (fun json ->
      match Memory_object.of_yojson json with
      | Ok obj ->
        (match svc.Memory_service.update_fn obj with
         | Ok updated -> Ok (Memory_object.to_yojson updated)
         | Error e -> Error (Types.Internal (Memory_error.to_string e)))
      | Error msg -> Error (Types.Internal msg));
    delete_fn = (fun id ->
      match svc.Memory_service.delete_fn id with
      | Ok () -> Ok ()
      | Error e -> Error (Types.Internal (Memory_error.to_string e)));
    list_all_fn = (fun ?scope ?limit () ->
      match svc.Memory_service.list_all_fn ?scope ?limit () with
      | Ok objs -> Ok (List.map Memory_object.to_yojson objs)
      | Error e -> Error (Types.Internal (Memory_error.to_string e)));
    close_fn = svc.Memory_service.close_fn;
    render_index_fn = svc.Memory_service.render_index_fn;
  }

let make_test_config () = Types.{
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = { drain_timeout = 1.0; cancel_grace_period = 0.1;
               flush_batch_size = 10 };
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 100 };
  parallel_tool_execution = true;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 60.0;
}

let run_handler handler input rt =
  let token = Cancellation.create_token (Runtime.cancellation_root rt) in
  handler input token

let test_memory_tools_scope_isolation () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let svc = match Par_memory.Sqlite_memory.make_service ":memory:" with
        | Error e -> Alcotest.failf "make_service: %s" (Par_memory.Memory_error.to_string e)
        | Ok svc -> svc
      in
      let memory = make_test_memory svc in
      let config = make_test_config () in
      match Runtime.create ~config ~memory sw with
      | Error _ -> Alcotest.fail "Runtime.create failed"
      | Ok rt ->
        let registry = Runtime.tool_registry rt in
        let scope_a = "session-alpha" in
        let scope_b = "session-beta" in
        let resolve name = match Tool_registry.resolve registry name with
          | Some h -> h
          | None -> Alcotest.failf "%s tool not found" name
        in

        let ctx_a = Invoke_context.create ~session_id:scope_a () in
        Invoke_context.with_context ctx_a (fun () ->
          let input = `Assoc [("content", `String "OCaml is a great language")] in
          match run_handler (resolve "remember_memory") input rt with
          | Types.Success _ -> ()
          | Types.Error e -> Alcotest.failf "remember_memory: %s" e.message
          | Types.Handoff _ -> Alcotest.fail "unexpected handoff");

        Invoke_context.with_context ctx_a (fun () ->
          let input = `Assoc [("query", `String "OCaml great language")] in
          match run_handler (resolve "recall_memory") input rt with
          | Types.Success result ->
            let count = Yojson.Safe.Util.(result |> member "count" |> to_int) in
            Alcotest.(check int) "scope A recalls 1" 1 count
          | Types.Error e -> Alcotest.failf "recall_memory: %s" e.message
          | Types.Handoff _ -> Alcotest.fail "unexpected handoff");

        let ctx_b = Invoke_context.create ~session_id:scope_b () in
        Invoke_context.with_context ctx_b (fun () ->
          let input = `Assoc [("query", `String "OCaml great language")] in
          match run_handler (resolve "recall_memory") input rt with
          | Types.Success result ->
            let count = Yojson.Safe.Util.(result |> member "count" |> to_int) in
            Alcotest.(check int) "scope B recalls 0" 0 count
          | Types.Error e -> Alcotest.failf "recall_memory: %s" e.message
          | Types.Handoff _ -> Alcotest.fail "unexpected handoff");

        ignore (Runtime.close rt)))

let test_memory_tools_registered () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let svc = match Par_memory.Sqlite_memory.make_service ":memory:" with
        | Error e -> Alcotest.failf "make_service: %s" (Par_memory.Memory_error.to_string e)
        | Ok svc -> svc
      in
      let memory = make_test_memory svc in
      let config = make_test_config () in
      match Runtime.create ~config ~memory sw with
      | Error _ -> Alcotest.fail "Runtime.create failed"
      | Ok rt ->
        let registry = Runtime.tool_registry rt in
        Alcotest.(check bool) "recall_memory registered"
          true (Tool_registry.resolve registry "recall_memory" |> Option.is_some);
        Alcotest.(check bool) "remember_memory registered"
          true (Tool_registry.resolve registry "remember_memory" |> Option.is_some);
        Alcotest.(check bool) "search_history registered"
          true (Tool_registry.resolve registry "search_history" |> Option.is_some);
        ignore (Runtime.close rt)))

let test_no_memory_no_tools () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let config = make_test_config () in
      match Runtime.create ~config sw with
      | Error _ -> Alcotest.fail "Runtime.create failed"
      | Ok rt ->
        let registry = Runtime.tool_registry rt in
        Alcotest.(check bool) "no recall_memory"
          false (Tool_registry.resolve registry "recall_memory" |> Option.is_some);
        Alcotest.(check bool) "no remember_memory"
          false (Tool_registry.resolve registry "remember_memory" |> Option.is_some);
        Alcotest.(check bool) "no search_history"
          false (Tool_registry.resolve registry "search_history" |> Option.is_some);
        ignore (Runtime.close rt)))

let () =
  Alcotest.run "memory_tools" [
    ("registration", [
       Alcotest.test_case "tools registered when memory provided" `Quick
         test_memory_tools_registered;
       Alcotest.test_case "no tools when memory not provided" `Quick
         test_no_memory_no_tools;
     ]);
    ("scope_isolation", [
       Alcotest.test_case "remember in A, recall in A, not in B" `Quick
         test_memory_tools_scope_isolation;
     ]);
  ]
