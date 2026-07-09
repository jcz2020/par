(* test/test_per_call_workspace.ml — v0.6.6
   Tests for Runtime.per_call_registry and per-run workspace override.

   Strategy: install bash on a runtime, build per_call_registries with two
   different workspaces, then invoke the resolved bash handlers. Workspace
   rejection happens inside [Workspace.admit] BEFORE any process spawn, so
   the rejection tests are hermetic (no subprocess). The admit-own-root test
   reaches spawn (clock=None so the timeout fiber may win the race — we only
   assert admit passed, i.e. the result is NOT a workspace rejection). *)

open Par

let error_to_string (e : Types.error_category) =
  match e with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> Printf.sprintf "Invalid_input %S" s
  | Types.External_failure s -> Printf.sprintf "External_failure %S" s
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> Printf.sprintf "Permission_denied %S" s
  | Types.Internal s -> Printf.sprintf "Internal %S" s
  | Types.Embedding_unsupported -> "Embedding_unsupported"

let test_config : Types.runtime_config = {
  Types.persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
}

let () = Random.self_init ()

let make_temp_dir prefix =
  let dir = Printf.sprintf "/tmp/par_v066_%s_%d_%d"
              prefix (Unix.getpid ()) (Random.int 1_000_000) in
  Unix.mkdir dir 0o755;
  dir

let handler_of reg =
  match Tool_registry.resolve reg "bash" with
  | Some h -> h
  | None -> Alcotest.fail "bash not in per_call_registry"

let is_workspace_rejection = function
  | Types.Error { category = Types.Invalid_input _; _ } -> true
  | Types.Error { category = Types.Permission_denied _; _ } -> true
  | _ -> false

let mk_input cwd = `Assoc [("argv", `List [`String "ls"]); ("cwd", `String cwd)]

let setup_builtins rt ~switch ~net =
  let tools = Builtin_tools.builtin_tools ~switch ~net ~workspace:(Runtime.workspace rt) in
  List.iter (fun (tb : Types.tool_binding) ->
    ignore (Runtime.register_tool rt
      ~name:tb.descriptor.Types.name
      ~description:tb.descriptor.Types.description
      ~input_schema:tb.descriptor.Types.input_schema
      ~handler:tb.handler ())
  ) tools;
  Runtime.register_file_tools_rebuild rt (fun ws ->
    List.map (fun (tb : Types.tool_binding) ->
      (tb.descriptor.Types.name, tb.handler))
      (Builtin_tools.builtin_tools ~switch ~net ~workspace:ws))

(* -------------------------------------------------------------------------- *)
(* per_call_registry isolation                                                *)
(* -------------------------------------------------------------------------- *)

let isolation_suite =
  "per_call_registry_isolation", [

    Alcotest.test_case "handler from ws_a rejects cwd under ws_b" `Quick (fun () ->
      (* Hermetic: Workspace.admit rejects dir_b before any process spawn. *)
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          let mgr = Eio.Stdenv.process_mgr env in
          match Runtime.create ~config:test_config sw with
          | Ok rt ->
            (match Runtime.install_bash_tool ~process_mgr:mgr ~fs:(Eio.Stdenv.fs env) rt with
             | Ok () ->
               let dir_a = make_temp_dir "a" in
               let dir_b = make_temp_dir "b" in
               let ws_a = match Workspace.of_dir dir_a with Ok w -> w | Error _ -> Alcotest.fail "ws_a" in
               let reg_a = Runtime.per_call_registry ~rt ~workspace:ws_a in
               let h_a = handler_of reg_a in
               let token = Cancellation.create_token sw in
               (match is_workspace_rejection (h_a (mk_input dir_b) token) with
                | true -> ()
                | false -> Alcotest.fail "ws_a handler should reject cwd under dir_b")
             | Error e -> Alcotest.failf "install failed: %s" (error_to_string e))
          | Error e -> Alcotest.failf "create failed: %s" (error_to_string e))));

    Alcotest.test_case "handler from ws_a admits cwd under ws_a" `Quick (fun () ->
      (* Admit passes; ls spawns. With clock=None the timeout fiber may win the
         race, so we only assert admit passed (NOT a workspace rejection). *)
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          let mgr = Eio.Stdenv.process_mgr env in
          match Runtime.create ~config:test_config sw with
          | Ok rt ->
            (match Runtime.install_bash_tool ~process_mgr:mgr ~fs:(Eio.Stdenv.fs env) rt with
             | Ok () ->
               let dir_a = make_temp_dir "adm" in
               let ws_a = match Workspace.of_dir dir_a with Ok w -> w | Error _ -> Alcotest.fail "ws_a" in
               let reg_a = Runtime.per_call_registry ~rt ~workspace:ws_a in
               let h_a = handler_of reg_a in
               let token = Cancellation.create_token sw in
               (match is_workspace_rejection (h_a (mk_input dir_a) token) with
                | true -> Alcotest.fail "ws_a handler should ADMIT cwd under dir_a"
                | false -> ())
             | Error e -> Alcotest.failf "install failed: %s" (error_to_string e))
          | Error e -> Alcotest.failf "create failed: %s" (error_to_string e))));

    Alcotest.test_case "two workspaces produce mutually-rejecting handlers" `Quick (fun () ->
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          let mgr = Eio.Stdenv.process_mgr env in
          match Runtime.create ~config:test_config sw with
          | Ok rt ->
            (match Runtime.install_bash_tool ~process_mgr:mgr ~fs:(Eio.Stdenv.fs env) rt with
             | Ok () ->
               let dir_a = make_temp_dir "iso_a" in
               let dir_b = make_temp_dir "iso_b" in
               let ws_a = match Workspace.of_dir dir_a with Ok w -> w | Error _ -> Alcotest.fail "ws_a" in
               let ws_b = match Workspace.of_dir dir_b with Ok w -> w | Error _ -> Alcotest.fail "ws_b" in
               let reg_a = Runtime.per_call_registry ~rt ~workspace:ws_a in
               let reg_b = Runtime.per_call_registry ~rt ~workspace:ws_b in
               let h_a = handler_of reg_a in
               let h_b = handler_of reg_b in
               let token = Cancellation.create_token sw in
               Alcotest.(check bool) "h_a admits dir_a" false
                 (is_workspace_rejection (h_a (mk_input dir_a) token));
               Alcotest.(check bool) "h_a rejects dir_b" true
                 (is_workspace_rejection (h_a (mk_input dir_b) token));
               Alcotest.(check bool) "h_b admits dir_b" false
                 (is_workspace_rejection (h_b (mk_input dir_b) token));
               Alcotest.(check bool) "h_b rejects dir_a" true
                 (is_workspace_rejection (h_b (mk_input dir_a) token))
             | Error e -> Alcotest.failf "install failed: %s" (error_to_string e))
          | Error e -> Alcotest.failf "create failed: %s" (error_to_string e))));

    Alcotest.test_case "per_call_registry without override mirrors rt.tool_registry" `Quick (fun () ->
      Eio_main.run (fun _env ->
        Eio.Switch.run (fun sw ->
          let mgr = Eio.Stdenv.process_mgr _env in
          let net = Eio.Stdenv.net _env in
          match Runtime.create ~config:test_config sw with
          | Ok rt ->
            (match Runtime.install_bash_tool ~process_mgr:mgr ~fs:(Eio.Stdenv.fs _env) rt with
             | Ok () ->
               setup_builtins rt ~switch:sw ~net;
               let reg_default = Runtime.per_call_registry ~rt ~workspace:(Runtime.workspace rt) in
               let names_default = Tool_registry.names reg_default in
               Alcotest.(check bool) "bash present" true (List.mem "bash" names_default);
               Alcotest.(check bool) "read present" true (List.mem "read" names_default)
             | Error e -> Alcotest.failf "install failed: %s" (error_to_string e))
          | Error e -> Alcotest.failf "create failed: %s" (error_to_string e))));

    Alcotest.test_case "file tool (read) handler respects overridden workspace" `Quick (fun () ->
      Eio_main.run (fun _env ->
        Eio.Switch.run (fun sw ->
          let mgr = Eio.Stdenv.process_mgr _env in
          let net = Eio.Stdenv.net _env in
          match Runtime.create ~config:test_config sw with
          | Ok rt ->
            (match Runtime.install_bash_tool ~process_mgr:mgr ~fs:(Eio.Stdenv.fs _env) rt with
             | Ok () ->
               setup_builtins rt ~switch:sw ~net;
               let dir_a = make_temp_dir "ft_a" in
               let dir_b = make_temp_dir "ft_b" in
               let ws_a = match Workspace.of_dir dir_a with Ok w -> w | Error _ -> Alcotest.fail "ws_a" in
               let reg_a = Runtime.per_call_registry ~rt ~workspace:ws_a in
               let h_read = match Tool_registry.resolve reg_a "read" with
                 | Some h -> h | None -> Alcotest.fail "read not in per_call_registry" in
               let token = Cancellation.create_token sw in
               let read_b = `Assoc [("path", `String (dir_b ^ "/file.txt"))] in
               let read_a = `Assoc [("path", `String (dir_a ^ "/file.txt"))] in
               Alcotest.(check bool) "read rejects path under dir_b" true
                 (is_workspace_rejection (h_read read_b token));
               Alcotest.(check bool) "read admits path under dir_a" false
                 (is_workspace_rejection (h_read read_a token))
             | Error e -> Alcotest.failf "install failed: %s" (error_to_string e))
          | Error e -> Alcotest.failf "create failed: %s" (error_to_string e))));

    Alcotest.test_case "invoke ?workspace routes bash through effective workspace (e2e, Mock)" `Quick (fun () ->
      (* E2E: Mock LLM emits a bash tool_call with cwd=dir_a. invoke ?workspace:ws_a
         routes through per_call_registry's bash handler (rebuilt for ws_a), which
         admits dir_a. Satisfies ROADMAP §5 exit condition 2 (positive direction). *)
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          let mgr = Eio.Stdenv.process_mgr env in
          let net = Eio.Stdenv.net env in
          let dir_a = make_temp_dir "e2e_a" in
          let ws_a = match Workspace.of_dir dir_a with Ok w -> w | Error _ -> Alcotest.fail "ws_a" in
          let bash_call : Types.tool_call = {
            id = "c1"; name = "bash";
            arguments = `Assoc [("argv", `List [`String "ls"]); ("cwd", `String dir_a)] } in
          let (llm, _hist) = Mock_provider.create [
            Mock_provider.With_tool_calls { text = None; calls = [bash_call] };
            Mock_provider.Text "done";
          ] in
          match Runtime.create ~config:test_config ~llm sw with
          | Ok rt ->
            (match Runtime.install_bash_tool ~process_mgr:mgr ~fs:(Eio.Stdenv.fs env) rt with
             | Ok () ->
               setup_builtins rt ~switch:sw ~net;
               let model : Types.model_config = {
                 provider = `Openai; model_name = "t"; api_base = None;
                 temperature = 0.7; max_tokens = None; top_p = None; stop_sequences = None } in
               let agent = match Runtime.make_agent ~id:"a"
                 ~system_prompt:(Types.stable_prompt "s") ~model
                 ~tools:[Builtin_tools.bash_tool_descriptor] () with
                 | Ok a -> a | Error e -> Alcotest.failf "make_agent: %s" (error_to_string e) in
               ignore (Runtime.register_agent rt agent);
               (match Runtime.invoke rt ~agent_id:"a" ~message:"m" ~workspace:ws_a () with
                | Ok _ -> ()  (* bash admitted dir_a under ws_a → tool ran → invoke completed *)
                | Error (e, _) -> Alcotest.failf "invoke should succeed with ws_a, got %s" (error_to_string e))
             | Error e -> Alcotest.failf "install: %s" (error_to_string e))
          | Error e -> Alcotest.failf "create: %s" (error_to_string e))));

    Alcotest.test_case "spawn cwd reaches process (regression for runtime.ml:510)" `Quick (fun () ->
      (* Regression: Eio.Process.spawn must receive ~cwd so the child process
         runs in the directory validated by Workspace.admit, not the parent's cwd.
         Before the fix, spawn omitted ~cwd, so all commands ran in the PAR
         process's cwd regardless of what the user passed. *)
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          let mgr = Eio.Stdenv.process_mgr env in
          let fs = Eio.Stdenv.fs env in
          let clock = Eio.Stdenv.clock env in
          match Runtime.create ~config:test_config sw with
          | Ok rt ->
            (match Runtime.install_bash_tool ~process_mgr:mgr ~clock ~fs rt with
             | Ok () ->
               let dir = make_temp_dir "cwd_regress" in
               let ws = match Workspace.of_dir dir with Ok w -> w | Error _ -> Alcotest.fail "ws" in
               let reg = Runtime.per_call_registry ~rt ~workspace:ws in
               let h = handler_of reg in
               let token = Cancellation.create_token sw in
               let input = `Assoc [("argv", `List [`String "pwd"]); ("cwd", `String dir)] in
               (match h input token with
                | Types.Success output ->
                  let stdout = match Yojson.Safe.Util.(output |> member "stdout") with
                    | `String s -> String.trim s | _ -> "" in
                  Alcotest.(check string) "pwd output equals cwd" dir stdout
                | Types.Error _ ->
                  Alcotest.fail "handler returned Error (expected Success with pwd output)"
                | _ -> Alcotest.fail "unexpected result")
             | Error e -> Alcotest.failf "install failed: %s" (error_to_string e))
          | Error e -> Alcotest.failf "create failed: %s" (error_to_string e))));
  ]

let () =
  if Sys.os_type = "Win32" then begin
    print_endline "[SKIP] Process spawning tests skipped on Windows";
    exit 0
  end;
  Alcotest.run "per_call_workspace" [ isolation_suite ]
