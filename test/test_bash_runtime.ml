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
  | Cancelled _ -> "cancelled"

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
  max_tool_schema_tokens = None;
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
    | Error { category = Types.Permission_denied _; message; _ } ->
      let has_marker =
        try ignore (Str.search_forward (Str.regexp_string "[bash-policy]") message 0); true
        with Not_found -> false
      in
      let has_policy_name =
        try ignore (Str.search_forward (Str.regexp_string policy_name) message 0); true
        with Not_found -> false
      in
      Alcotest.check Alcotest.bool "has [bash-policy] marker" true has_marker;
      Alcotest.check Alcotest.bool "mentions policy name" true has_policy_name
    | Error { category = other; _ } ->
      Alcotest.failf "%s: expected Permission_denied, got %s"
        policy_name (error_to_string other)
    | Success _ ->
      Alcotest.failf "%s: policy %s should have rejected [%s]"
        policy_name policy_name (String.concat " " argv)
    | Handoff _ ->
      Alcotest.failf "%s: unexpected handoff for policy %s"
        policy_name policy_name
    | Approval_required _ -> Alcotest.fail "unexpected approval request")

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

(* A process can exit before its switch-attached output-copy fibers drain.
   Release those fibers from await, without yielding, to make the race reliable. *)
module Delayed_output_process = struct
  type t = { output_ready : unit Eio.Promise.u; exit_code : int }
  type tag = [ `Generic ]

  let pid _ = 0
  let await t =
    Eio.Promise.resolve t.output_ready ();
    `Exited t.exit_code
  let signal _ _ = ()
end

module Delayed_output_manager = struct
  type t = {
    stdout : string;
    stderr : string;
    exit_code : int;
    before_copy : unit -> unit;
  }
  type tag = [ `Generic ]

  let pipe _ ~sw:_ = failwith "unused by bash capture"

  let spawn t ~sw ?cwd:_ ?stdin:_ ?stdout ?stderr ?env:_ ?executable:_ _argv =
    let ready, output_ready = Eio.Promise.create () in
    let copy sink text =
      Option.iter (fun sink ->
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Promise.await ready;
          t.before_copy ();
          Eio.Flow.copy_string text sink)) sink
    in
    copy stdout t.stdout;
    copy stderr t.stderr;
    Eio.Resource.T (
      { Delayed_output_process.output_ready; exit_code = t.exit_code },
      Eio.Process.Pi.process (module Delayed_output_process))
end

let output_capture_suite =
  "output_capture", [
    Alcotest.test_case "both outputs drain after child exit and preserve status" `Quick (fun () ->
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          let process_mgr = Eio.Resource.T (
            { Delayed_output_manager.stdout = "complete stdout\n";
              stderr = "complete stderr\n"; exit_code = 7; before_copy = (fun () -> ()) },
            Eio.Process.Pi.mgr (module Delayed_output_manager)) in
          match Runtime.create ~config:test_config sw with
          | Error e -> Alcotest.failf "create: %s" (error_to_string e)
          | Ok rt ->
            Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () ->
              (match Runtime.install_bash_tool ~process_mgr
                 ~clock:(Eio.Stdenv.clock env) ~fs:(Eio.Stdenv.fs env) rt with
               | Ok () -> ()
               | Error e -> Alcotest.failf "install: %s" (error_to_string e));
              let token = Cancellation.create_token sw in
              match bash_handler rt (`Assoc ["argv", `List [`String "echo"]]) token with
              | Types.Success output ->
                let stdout = Yojson.Safe.Util.(output |> member "stdout" |> to_string) in
                let stderr = Yojson.Safe.Util.(output |> member "stderr" |> to_string) in
                let exit_code = Yojson.Safe.Util.(output |> member "exit_code" |> to_int) in
                Alcotest.(check string) "stdout is complete" "complete stdout\n" stdout;
                Alcotest.(check string) "stderr is complete" "complete stderr\n" stderr;
                Alcotest.(check int) "nonzero status is preserved" 7 exit_code
              | _ -> Alcotest.fail "expected bash success"))));

    Alcotest.test_case "timeout covers unfinished output drain after child exit" `Quick (fun () ->
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          let process_mgr = Eio.Resource.T (
            { Delayed_output_manager.stdout = "unread"; stderr = ""; exit_code = 0;
              before_copy = Eio.Fiber.await_cancel },
            Eio.Process.Pi.mgr (module Delayed_output_manager)) in
          match Runtime.create ~config:test_config sw with
          | Error e -> Alcotest.failf "create: %s" (error_to_string e)
          | Ok rt ->
            Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () ->
              (match Runtime.install_bash_tool ~process_mgr
                 ~clock:(Eio.Stdenv.clock env) ~fs:(Eio.Stdenv.fs env) rt with
               | Ok () -> ()
               | Error e -> Alcotest.failf "install: %s" (error_to_string e));
              let input = `Assoc ["argv", `List [`String "echo"]; "timeout", `Float 0.02] in
              let started = Unix.gettimeofday () in
              (match bash_handler rt input (Cancellation.create_token sw) with
               | Types.Error { category = Types.Timeout; _ } -> ()
               | _ -> Alcotest.fail "must not return before output drains");
              Alcotest.(check bool) "drain cancellation returns promptly" true
                (Unix.gettimeofday () -. started < 2.0)))));
  ]

(* -------------------------------------------------------------------------- *)
(* timeout kills the child process (no process leak past the timeout)         *)
(* -------------------------------------------------------------------------- *)

let read_proc_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in

  close_in ic;
  s

(* Is a `sleep 97` child still alive? Scans /proc cmdlines (Linux only). *)
let sleep_97_alive () =
  Array.to_list (Sys.readdir "/proc")
  |> List.filter (fun e -> e <> "" && e.[0] >= '0' && e.[0] <= '9')
  |> List.exists (fun pid ->
      let f = Filename.concat "/proc" (pid ^ "/cmdline") in
      match (try Some (read_proc_file f) with _ -> None) with
      | None -> false
      | Some s ->
        let s = String.map (fun c -> if c = '\000' then ' ' else c) s in
        String.trim s = "sleep 97")

let timeout_suite =
  "timeout", [
    Alcotest.test_case "real timer still kills the running child" `Quick (fun () ->
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          let Eio.Resource.T (mgr_state, mgr_ops) = Eio.Stdenv.process_mgr env in
          let module Manager = (val Eio.Resource.get mgr_ops Eio.Process.Pi.Mgr) in
          let child_pid = ref None in
          let module Recording_manager = struct
            type t = Manager.t
            type tag = Manager.tag
            let pipe = Manager.pipe
            let spawn t ~sw ?cwd ?stdin ?stdout ?stderr ?env ?executable argv =
              let child = Manager.spawn t ~sw ?cwd ?stdin ?stdout ?stderr ?env ?executable argv in
              child_pid := Some (Eio.Process.pid child);
              child
          end in
          let process_mgr = Eio.Resource.T (mgr_state, Eio.Process.Pi.mgr (module Recording_manager)) in
          match Runtime.create ~config:test_config sw with
          | Error e -> Alcotest.failf "create: %s" (error_to_string e)
          | Ok rt ->
            Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () ->
              (match Runtime.install_bash_tool ~process_mgr
                 ~clock:(Eio.Stdenv.clock env) ~fs:(Eio.Stdenv.fs env) rt with
               | Ok () -> ()
               | Error e -> Alcotest.failf "install: %s" (error_to_string e));
              let input = `Assoc [
                "argv", `List [`String "sleep"; `String "97"];
                "timeout", `Float 0.2;
              ] in
              let started = Unix.gettimeofday () in
              (match bash_handler rt input (Cancellation.create_token sw) with
               | Types.Error { category = Types.Timeout; _ } -> ()
               | Types.Error { category; message; _ } ->
                 Alcotest.failf "expected Timeout, got %s: %s" (error_to_string category) message
               | _ -> Alcotest.fail "expected timed-out running child");
              let elapsed = Unix.gettimeofday () -. started in
              Alcotest.(check bool) "timer was awaited" true (elapsed >= 0.15);
              Alcotest.(check bool) "timeout returned promptly" true (elapsed < 5.0);
              let pid = match !child_pid with
                | Some pid -> pid
                | None -> Alcotest.fail "child never spawned"
              in
              let alive = try Unix.kill pid 0; true with
                | Unix.Unix_error (Unix.ESRCH, _, _) -> false
              in
              Alcotest.(check bool) "timed-out child was killed" false alive))));

    Alcotest.test_case "bash timeout kills the child process" `Quick (fun () ->
      if Sys.os_type = "Win32" then
        print_endline "[SKIP] process-leak check skipped on Windows"
      else if not (Sys.file_exists "/proc") then
        print_endline "[SKIP] process-leak check needs /proc (non-Linux)"
      else
        with_runtime_eio (fun rt mgr fs ->
          (match Runtime.install_bash_tool ~process_mgr:mgr ~fs rt with
           | Ok () -> ()
           | Error e -> Alcotest.failf "install failed: %s" (error_to_string e));
          let h = bash_handler rt in
          let input = `Assoc [
            ("argv", `List [`String "sleep"; `String "97"]);
            ("timeout", `Float 0.5);
          ] in
          let token = Cancellation.create_token (Runtime.cancellation_root rt) in
          let t0 = Unix.gettimeofday () in
          (match h input token with
           | Error { category = Types.Timeout; _ } -> ()
           | Error { category = other; _ } ->
             Alcotest.failf "expected Timeout, got %s" (error_to_string other)
           | Success _ -> Alcotest.fail "expected Timeout error, got Success"
           | Handoff _ -> Alcotest.fail "unexpected Handoff"
           | Approval_required _ -> Alcotest.fail "unexpected Approval_required");
          let elapsed = Unix.gettimeofday () -. t0 in
          Alcotest.(check bool) "handler returned near the timeout, not after sleep"
            true (elapsed < 10.0);
          (* Contract pin: Eio's await-cancellation kills the child when the
             timer fiber wins the race. If an eio upgrade ever changes that
             semantics, this test must fail rather than silently leak. *)
          Alcotest.(check bool) "child process `sleep 97` was killed" false
            (sleep_97_alive ())));
  ]

let () =
  if Sys.os_type = "Win32" then begin
    print_endline "[SKIP] Process spawning tests skipped on Windows";
    exit 0
  end;
  Alcotest.run "bash_runtime" [
    default_policy_suite;
    custom_policy_suite;
    install_suite;
    policy_enforcement_suite;
    output_capture_suite;
    timeout_suite;
  ]
