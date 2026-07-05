(* test/test_bash_runtime.ml — v0.3.1
   Tests for Runtime.install_bash_tool and ?bash_policy parameter.

   These tests verify the wiring between Runtime, Bash_policy, and the
   tool registry. They invoke the registered bash handler with inputs
   the chosen policy rejects, so the handler never needs to actually
   spawn a process — keeping tests hermetic and fast. *)

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

let make_runtime ?bash_policy () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      match Runtime.create ?bash_policy ~config:test_config sw with
      | Ok rt -> rt
      | Error e -> Alcotest.failf "Runtime.create failed: %s" (error_to_string e)))

let with_runtime_eio ?bash_policy f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let mgr = Eio.Stdenv.process_mgr env in
      let fs = Eio.Stdenv.fs env in
      match Runtime.create ?bash_policy ~config:test_config sw with
      | Ok rt -> f rt mgr fs
      | Error e -> Alcotest.failf "Runtime.create failed: %s" (error_to_string e)))

let bash_handler rt =
  match Tool_registry.resolve (Runtime.tool_registry rt) "bash" with
  | Some h -> h
  | None -> Alcotest.fail "bash tool not registered"

(* -------------------------------------------------------------------------- *)
(* default policy                                                             *)
(* -------------------------------------------------------------------------- *)

let default_policy_suite =
  "default_policy", [
    Alcotest.test_case "default Coder policy" `Quick (fun () ->
      let rt = make_runtime () in
      let module P = (val Runtime.bash_policy rt : Bash_policy.POLICY) in
      Alcotest.(check string) "policy name" "Coder" P.name;
      Alcotest.(check bool) "allow_write=true" true P.allow_write;
      Alcotest.(check bool) "allow_network=true" true P.allow_network);
  ]

(* -------------------------------------------------------------------------- *)
(* custom policy injection                                                    *)
(* -------------------------------------------------------------------------- *)

let custom_policy_suite =
  "custom_policy", [
    Alcotest.test_case "explicit Coder policy" `Quick (fun () ->
      let rt = make_runtime ~bash_policy:(module Bash_policy.Coder : Bash_policy.POLICY) () in
      let module P = (val Runtime.bash_policy rt : Bash_policy.POLICY) in
      Alcotest.(check string) "name" "Coder" P.name);

    Alcotest.test_case "explicit ReadOnly policy" `Quick (fun () ->
      let rt = make_runtime ~bash_policy:(module Bash_policy.ReadOnly : Bash_policy.POLICY) () in
      let module P = (val Runtime.bash_policy rt : Bash_policy.POLICY) in
      Alcotest.(check string) "name" "ReadOnly" P.name;
      Alcotest.(check bool) "allow_write=false" false P.allow_write);
  ]

(* -------------------------------------------------------------------------- *)
(* install_bash_tool                                                          *)
(* -------------------------------------------------------------------------- *)

let install_first_succeeds =
  Alcotest.test_case "first install succeeds" `Quick (fun () ->
    with_runtime_eio (fun rt mgr fs ->
      match Runtime.install_bash_tool ~process_mgr:mgr ~fs rt with
      | Ok () -> ()
      | Error e -> Alcotest.failf "install_bash_tool failed: %s" (error_to_string e)))

let install_second_fails =
  Alcotest.test_case "second install fails (idempotency)" `Quick (fun () ->
    with_runtime_eio (fun rt mgr fs ->
      (match Runtime.install_bash_tool ~process_mgr:mgr ~fs rt with
       | Ok () -> ()
       | Error e -> Alcotest.failf "first install failed: %s" (error_to_string e));
      match Runtime.install_bash_tool ~process_mgr:mgr ~fs rt with
      | Ok () -> Alcotest.fail "second install should have failed"
      | Error (Types.Invalid_input msg) ->
        Alcotest.(check bool) "msg mentions already" true
          (let re = Str.regexp "already" in
           try ignore (Str.search_forward re msg 0); true
           with Not_found -> false)
      | Error e -> Alcotest.failf "wrong error: %s" (error_to_string e)))

let install_appears_in_registry =
  Alcotest.test_case "bash tool appears in tool list" `Quick (fun () ->
    with_runtime_eio (fun rt mgr fs ->
      (match Runtime.install_bash_tool ~process_mgr:mgr ~fs rt with
       | Ok () -> ()
       | Error e -> Alcotest.failf "install failed: %s" (error_to_string e));
      let names = Tool_registry.names (Runtime.tool_registry rt) in
      Alcotest.(check bool) "bash in names" true (List.mem "bash" names)))

let install_requires_process_mgr =
  Alcotest.test_case "install without process_mgr fails gracefully" `Quick (fun () ->
    with_runtime_eio (fun rt _mgr _fs ->
      match Runtime.install_bash_tool rt with
      | Ok () -> Alcotest.fail "install should require process_mgr"
      | Error (Types.Invalid_input msg) ->
        Alcotest.(check bool) "msg mentions process_mgr" true
          (let re = Str.regexp "process_mgr" in
           try ignore (Str.search_forward re msg 0); true
           with Not_found -> false)
      | Error e -> Alcotest.failf "wrong error: %s" (error_to_string e)))

let install_suite =
  "install_bash_tool", [
    install_first_succeeds;
    install_second_fails;
    install_appears_in_registry;
    install_requires_process_mgr;
  ]

(* -------------------------------------------------------------------------- *)
(* policy enforcement via the installed handler                               *)
(* -------------------------------------------------------------------------- *)

let policy_rejects ~policy_name ~policy_mod ~argv =
  with_runtime_eio ~bash_policy:policy_mod (fun rt mgr fs ->
    (match Runtime.install_bash_tool ~process_mgr:mgr ~fs rt with
     | Ok () -> ()
     | Error e -> Alcotest.failf "install failed: %s" (error_to_string e));
    let h = bash_handler rt in
    let input = `Assoc [("argv", `List (List.map (fun s -> `String s) argv))] in
    let token = Cancellation.create_token (Runtime.cancellation_root rt) in
    match h input token with
    | Error { category = Types.Permission_denied _; _ } -> ()
    | Error { category = other; _ } ->
      Alcotest.failf "%s: expected Permission_denied, got %s"
        policy_name (error_to_string other)
    | Success _ ->
      Alcotest.failf "%s: policy %s should have rejected [%s]"
        policy_name policy_name (String.concat " " argv)
    | Handoff _ ->
      Alcotest.failf "%s: unexpected handoff for policy %s"
        policy_name policy_name)

let policy_enforcement_suite =
  "policy_enforcement", [
    Alcotest.test_case "Coder allows cat (no Permission_denied)" `Quick (fun () ->
      with_runtime_eio
        ~bash_policy:(module Bash_policy.Coder : Bash_policy.POLICY)
        (fun rt mgr fs ->
          (match Runtime.install_bash_tool ~process_mgr:mgr ~fs rt with
           | Ok () -> ()
           | Error e -> Alcotest.failf "install failed: %s" (error_to_string e));
          let h = bash_handler rt in
          let input = `Assoc [("argv", `List [`String "cat"; `String "README.md"])] in
          let token = Cancellation.create_token (Runtime.cancellation_root rt) in
          match h input token with
          | Error { category = Types.Permission_denied _; _ } ->
            Alcotest.fail "Coder should accept cat (no Permission_denied)"
          | _ -> ()));

    Alcotest.test_case "ReadOnly rejects rm" `Quick (fun () ->
      policy_rejects ~policy_name:"ReadOnly"
        ~policy_mod:(module Bash_policy.ReadOnly : Bash_policy.POLICY)
        ~argv:["rm"; "-rf"; "build/"]);

    Alcotest.test_case "ReadOnlyNoNet rejects curl" `Quick (fun () ->
      policy_rejects ~policy_name:"ReadOnlyNoNet"
        ~policy_mod:(module Bash_policy.ReadOnlyNoNet : Bash_policy.POLICY)
        ~argv:["curl"; "http://example.com"]);

    Alcotest.test_case "ReadOnlyNoNet rejects write tool" `Quick (fun () ->
      policy_rejects ~policy_name:"ReadOnlyNoNet"
        ~policy_mod:(module Bash_policy.ReadOnlyNoNet : Bash_policy.POLICY)
        ~argv:["chmod"; "755"; "foo"]);
  ]

let () =
  Alcotest.run "bash_runtime" [
    default_policy_suite;
    custom_policy_suite;
    install_suite;
    policy_enforcement_suite;
  ]
