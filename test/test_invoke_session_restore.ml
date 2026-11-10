(* test/test_invoke_session_restore.ml — the event-bus session contract for
   the non-ReAct invoke entry points (PAR-188).

   PAR-48p fixed this for [Runtime.invoke]/[invoke_content]: a run tags events
   with its own session while it works, then puts the caller's session back.
   [invoke_generate] and [invoke_structured] used to leave the finished run's
   session on the bus, so every event published afterwards was tagged with a
   session that no longer existed. These two cases pin the contract:

     - with no prior session, the bus is restored to its explicit empty state;
     - a prior session survives a run that minted its own session.

   Fixtures copied verbatim from test_generate.ml / test_engine_structured.ml
   per project convention (ROADMAP §Test Conventions point 3: no shared
   helpers). *)

open Par
open Types

(* -------------------------------------------------------------------------- *)
(* Fixtures                                                                   *)
(* -------------------------------------------------------------------------- *)

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None ; context_window = None}

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 ; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; reasoning = []; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let mock_llm responses =
  let counter = ref 0 in
  let next () =
    let idx = !counter in
    incr counter;
    match List.nth_opt responses idx with
    | Some resp -> resp
    | None -> text_response "default"
  in
  { complete_fn = (fun _model _tools _conv -> Ok (next ()));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None;
  }

let error_to_string : error_category -> string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"
  | Cancelled _ -> "cancelled"

let runtime_config () : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = false;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
  max_tool_schema_tokens = None;
}

(* Records every session the bus is asked to tag events with, newest first. *)
let recording_bus sessions : event_bus_service = {
  publish_fn = (fun _ -> ());
  subscribe_fn = (fun _ -> "");
  unsubscribe_fn = (fun _ -> ());
  set_session_id_fn = (fun sid -> sessions := sid :: !sessions);
  start_dispatcher_fn = (fun _ -> ());
}

let with_runtime ~llm ~bus f =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  match Runtime.create ~event_bus:bus ~llm ~config:(runtime_config ()) sw with
  | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  | Ok rt ->
    Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) (fun () -> f rt)

let register_agent rt id =
  let agent = match Runtime.make_agent ~id
                       ~system_prompt:(stable_prompt "session restore fixture")
                       ~model:dummy_model () with
    | Ok a -> a
    | Error e -> Alcotest.failf "make_agent: %s" (error_to_string e)
  in
  match Runtime.register_agent rt agent with
  | Ok () -> ()
  | Error e -> Alcotest.failf "register_agent: %s" (error_to_string e)

(* The two calls a run must make on the bus: tag with the run's own session,
   then put the caller's state back. [run_sid] must not be confused with the
   restored value. *)
let check_tagged_then_restored ~expected label sessions =
  match !sessions with
  | restored :: run_sid :: _ ->
    Alcotest.(check string) (label ^ ": restored session") expected restored;
    Alcotest.(check bool) (label ^ ": run had its own session") true
      (run_sid <> "" && run_sid <> expected)
  | _ ->
    Alcotest.failf
      "%s: expected the bus to be tagged with the run's session and then restored" label

(* -------------------------------------------------------------------------- *)
(* invoke_generate                                                            *)
(* -------------------------------------------------------------------------- *)

let test_invoke_generate_restores_bus_session () =
  (* No prior session: the run mints one, and the bus must go back to the
     explicit empty state. With [update_current] the runtime keeps the minted
     session, which is exactly why the restore cannot read [rt.session_id]. *)
  let case ~update_current label =
    let sessions = ref [] in
    let bus = recording_bus sessions in
    let llm = mock_llm [text_response "ok"] in
    with_runtime ~llm ~bus @@ fun rt ->
    register_agent rt "generate-agent";
    (match Runtime.invoke_generate rt ~agent_id:"generate-agent" ~message:"hi"
             ~update_current () with
     | Ok _ -> ()
     | Error (e, _) -> Alcotest.failf "invoke_generate: %s" (error_to_string e));
    check_tagged_then_restored ~expected:"" label sessions
  in
  case ~update_current:true "update_current";
  (* Background generate: the runtime's current session is deliberately left
     alone, so a leaked bus session would be the only trace of the run. *)
  case ~update_current:false "update_current:false"

(* -------------------------------------------------------------------------- *)
(* invoke_structured                                                          *)
(* -------------------------------------------------------------------------- *)

let response_schema : Yojson.Safe.t =
  `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [("answer", `Assoc [("type", `String "integer")])]);
    ("required", `List [`String "answer"]);
  ]

let structured_reply = text_response {|{"answer": 42}|}

let test_invoke_structured_restores_bus_session () =
  let sessions = ref [] in
  let bus = recording_bus sessions in
  let llm = mock_llm [structured_reply; structured_reply] in
  with_runtime ~llm ~bus @@ fun rt ->
  register_agent rt "structured-agent";
  (* No prior session: restore to the explicit empty state. *)
  sessions := [];
  (match Runtime.invoke_structured rt ~agent_id:"structured-agent"
           ~message:"hi" ~response_schema () with
   | Ok _ -> ()
   | Error (e, _) -> Alcotest.failf "invoke_structured: %s" (error_to_string e));
  check_tagged_then_restored ~expected:"" "no prior session" sessions;
  (* A session the caller had before the run must come back, not the run's. *)
  Runtime.set_session_id rt "prior-session";
  sessions := [];
  (match Runtime.invoke_structured rt ~agent_id:"structured-agent"
           ~message:"hi" ~response_schema () with
   | Ok _ -> ()
   | Error (e, _) -> Alcotest.failf "invoke_structured: %s" (error_to_string e));
  check_tagged_then_restored ~expected:"prior-session" "prior session" sessions

(* -------------------------------------------------------------------------- *)
(* Test suite                                                                 *)
(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "test_invoke_session_restore" [
    ("invoke_generate", [
      Alcotest.test_case "restores the event-bus session" `Quick
        test_invoke_generate_restores_bus_session;
    ]);
    ("invoke_structured", [
      Alcotest.test_case "restores the event-bus session" `Quick
        test_invoke_structured_restores_bus_session;
    ]);
  ]
