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
            (match Runtime.install_bash_tool ~process_mgr:mgr rt with
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
            (match Runtime.install_bash_tool ~process_mgr:mgr rt with
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
            (match Runtime.install_bash_tool ~process_mgr:mgr rt with
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
          match Runtime.create ~config:test_config sw with
          | Ok rt ->
            (match Runtime.install_bash_tool ~process_mgr:mgr rt with
             | Ok () ->
               let reg_default = Runtime.per_call_registry ~rt ~workspace:(Runtime.workspace rt) in
               let names_default = Tool_registry.names reg_default in
               let names_orig = Tool_registry.names (Runtime.tool_registry rt) in
               Alcotest.(check bool) "same tool set" true (List.length names_default = List.length names_orig);
               Alcotest.(check bool) "bash present" true (List.mem "bash" names_default)
             | Error e -> Alcotest.failf "install failed: %s" (error_to_string e))
          | Error e -> Alcotest.failf "create failed: %s" (error_to_string e))));
  ]

let () =
  Alcotest.run "per_call_workspace" [ isolation_suite ]
