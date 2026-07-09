(* test/test_deprecation.ml — v0.7.1 (issue #6)
   Tests the [Deprecation] module:
   - [warn_once] fires [Logs.warn] exactly once per [fn_name] (idempotency)
   - [warn_once] emits a [Deprecated_api_called] event via the registered
     emitter on the first call only
   - distinct [fn_name]s each get their own first-call signal
   - the [Deprecated_api_called] event yojson-round-trips *)

open Par
open Types

(* ─── Event yojson round-trip ──────────────────────────────────── *)

let test_event_roundtrip () =
  let ev =
    Deprecated_api_called {
      fn_name = "Runtime.install_bash_tool";
      since = "v0.6.9";
      removed_in = "v0.8";
      migration = "pass ~fs:(Eio.Stdenv.fs env)";
    }
  in
  let json = event_to_yojson ev in
  (match event_of_yojson json with
   | Ok ev' ->
     let json' = event_to_yojson ev' in
     Alcotest.check Alcotest.bool "yojson round-trips" true
       (Yojson.Safe.equal json json')
   | Error msg ->
     Alcotest.check Alcotest.bool "yojson round-trips" false true;
     Printf.eprintf "Round-trip failed: %s\n" msg)

(* ─── Idempotency: second call is silent ───────────────────────── *)

let test_warn_once_fires_logs_warn_exactly_once () =
  Deprecation.reset_for_tests ();
  Logs.set_level (Some Logs.Warning) |> ignore;
  let before = Logs.warn_count () in
  Deprecation.warn_once
    ~since:"v0.6.9" ~removed_in:"v0.8"
    ~migration:"use X" ~fn_name:"test.fnA" ();
  let after_first = Logs.warn_count () in
  Deprecation.warn_once
    ~since:"v0.6.9" ~removed_in:"v0.8"
    ~migration:"use X" ~fn_name:"test.fnA" ();
  let after_second = Logs.warn_count () in
  Alcotest.(check int) "first call logs at Warn" 1 (after_first - before);
  Alcotest.(check int) "second call is silent" 0 (after_second - after_first)

(* ─── Event emission: Deprecated_api_called fires once ─────────── *)

let test_warn_once_emits_event_once () =
  Deprecation.reset_for_tests ();
  let emitted = ref [] in
  Deprecation.register_event_emitter (fun ev -> emitted := ev :: !emitted);
  Deprecation.warn_once
    ~since:"v0.6.9" ~removed_in:"v0.8"
    ~migration:"use X" ~fn_name:"test.fnB" ();
  Deprecation.warn_once
    ~since:"v0.6.9" ~removed_in:"v0.8"
    ~migration:"use X" ~fn_name:"test.fnB" ();
  let evs = List.rev !emitted in
  Alcotest.(check int) "emitter called exactly once" 1 (List.length evs);
  match evs with
  | [Deprecated_api_called { fn_name; since; removed_in; migration }] ->
    Alcotest.(check string) "fn_name carried" "test.fnB" fn_name;
    Alcotest.(check string) "since carried" "v0.6.9" since;
    Alcotest.(check string) "removed_in carried" "v0.8" removed_in;
    Alcotest.(check string) "migration carried" "use X" migration
  | _ -> Alcotest.fail "expected a single Deprecated_api_called event"

(* ─── Distinct fn_names each get their own first call ──────────── *)

let test_warn_once_distinct_fn_names_each_warn () =
  Deprecation.reset_for_tests ();
  let count = ref 0 in
  Deprecation.register_event_emitter (fun _ev -> incr count);
  Deprecation.warn_once
    ~since:"v0.6.9" ~removed_in:"v0.8"
    ~migration:"use X" ~fn_name:"test.fnC" ();
  Deprecation.warn_once
    ~since:"v0.6.9" ~removed_in:"v0.8"
    ~migration:"use X" ~fn_name:"test.fnD" ();
  Alcotest.(check int) "two distinct fn_names fire twice" 2 !count

(* ─── No emitter registered: log still fires, no event crash ───── *)

let test_warn_once_without_emitter_still_logs () =
  Deprecation.reset_for_tests ();
  Logs.set_level (Some Logs.Warning) |> ignore;
  let before = Logs.warn_count () in
  (* No [register_event_emitter] call — event path is a no-op. *)
  Deprecation.warn_once
    ~since:"v0.6.9" ~removed_in:"v0.8"
    ~migration:"use X" ~fn_name:"test.fnE" ();
  let after = Logs.warn_count () in
  Alcotest.(check int) "log fires even without emitter" 1 (after - before)

(* ─── Runner ──────────────────────────────────────────────────── *)

let () =
  Alcotest.run "deprecation"
    [
      ( "event",
        [
          Alcotest.test_case "Deprecated_api_called yojson round-trip" `Quick
            test_event_roundtrip;
        ] );
      ( "warn_once",
        [
          Alcotest.test_case "fires Logs.warn exactly once" `Quick
            test_warn_once_fires_logs_warn_exactly_once;
          Alcotest.test_case "emits Deprecated_api_called once" `Quick
            test_warn_once_emits_event_once;
          Alcotest.test_case "distinct fn_names each warn" `Quick
            test_warn_once_distinct_fn_names_each_warn;
          Alcotest.test_case "logs without an emitter" `Quick
            test_warn_once_without_emitter_still_logs;
        ] );
    ]
