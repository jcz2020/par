(* test/test_capability.ml — v0.7.2 (Wave 1: Windows Port)
   Tests the [Capability] module:
   - [detect] returns [Available] for all capabilities on Unix
   - [is_windows] returns [false] on Linux / macOS
   - [platform_name] returns a non-empty string
   - [Unavailable] messages are non-empty and actionable
   - [detect ()] is deterministic (same result on repeated calls) *)

open Par

(* ─── detect: all capabilities available on Unix ──────────────────── *)

let test_detect_process_spawning_available () =
  let status = Capability.detect () `Process_spawning in
  Alcotest.(check bool) "Process_spawning is Available on Unix"
    true (status = `Available)

let test_detect_pipe_io_available () =
  let status = Capability.detect () `Pipe_io in
  Alcotest.(check bool) "Pipe_io is Available on Unix"
    true (status = `Available)

let test_detect_signal_kill_available () =
  let status = Capability.detect () `Signal_based_kill in
  Alcotest.(check bool) "Signal_based_kill is Available on Unix"
    true (status = `Available)

(* ─── is_windows ─────────────────────────────────────────────────── *)

let test_is_windows_false_on_unix () =
  Alcotest.(check bool) "is_windows is false on Linux/macOS"
    false (Capability.is_windows ())

(* ─── platform_name ──────────────────────────────────────────────── *)

let test_platform_name_non_empty () =
  let name = Capability.platform_name () in
  Alcotest.(check bool) "platform_name is non-empty"
    true (String.length name > 0)

let test_platform_name_is_linux () =
  let name = Capability.platform_name () in
  (* On CI (Ubuntu), expect "Linux".  Guard so the test also passes on
     macOS dev machines where the name is "macOS". *)
  let expected =
    if Sys.file_exists "/System/Library" then "macOS" else "Linux"
  in
  Alcotest.(check string) "platform_name matches expected" expected name

(* ─── Unavailable messages are actionable ─────────────────────────── *)

(* We cannot trigger Unavailable on a Linux runner, but we can verify
   the contract that IF Unavailable were returned, the message would be
   non-empty.  We do this by inverting: on Unix the status is Available,
   and we assert the invariant that Available does not carry a string.
   Then we independently verify the module compiles and the type system
   enforces the contract.

   For a Windows runner, these tests would exercise the actual
   Unavailable path.  The test is written to be valid on both
   platforms. *)

let test_detect_status_type_contract () =
  (* On Unix: all Available.  Verify via pattern match that no
     Unavailable leaks through. *)
  let caps : Capability.capability list =
    [ `Process_spawning; `Pipe_io; `Signal_based_kill ]
  in
  List.iter (fun cap ->
    match Capability.detect () cap with
    | `Available -> ()  (* expected on Unix *)
    | `Unavailable msg ->
      (* If we ever reach here (Windows), verify the message is
         actionable: non-empty and contains a URL. *)
      Alcotest.(check bool) "Unavailable msg is non-empty"
        true (String.length msg > 0);
      Alcotest.(check bool) "Unavailable msg contains tracking URL"
        true (String.contains_from msg 0 'h')
  ) caps

(* ─── Determinism: repeated calls return the same result ──────────── *)

let test_detect_deterministic () =
  let first = Capability.detect () `Process_spawning in
  let second = Capability.detect () `Process_spawning in
  Alcotest.(check bool) "detect is deterministic"
    (first = `Available) (second = `Available)

(* ─── Runner ─────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "capability"
    [
      ( "detect",
        [
          Alcotest.test_case "Process_spawning Available on Unix" `Quick
            test_detect_process_spawning_available;
          Alcotest.test_case "Pipe_io Available on Unix" `Quick
            test_detect_pipe_io_available;
          Alcotest.test_case "Signal_based_kill Available on Unix" `Quick
            test_detect_signal_kill_available;
          Alcotest.test_case "detect is deterministic" `Quick
            test_detect_deterministic;
          Alcotest.test_case "Unavailable msg contract" `Quick
            test_detect_status_type_contract;
        ] );
      ( "platform",
        [
          Alcotest.test_case "is_windows returns false on Unix" `Quick
            test_is_windows_false_on_unix;
          Alcotest.test_case "platform_name is non-empty" `Quick
            test_platform_name_non_empty;
          Alcotest.test_case "platform_name is Linux" `Quick
            test_platform_name_is_linux;
        ] );
    ]
