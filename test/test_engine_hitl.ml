(* Engine-level HITL approval tests — v0.8.0 Wave 5 C5.2.
   Exercises execute_approval three-way partition, approval_handler
   variants (Sync_local/Async_callback/Webhook), and Runtime.resume_approval.

   Fixtures follow test_handoff.ml + test_engine_assistant_message.ml patterns. *)

open Par
open Types

(* -------------------------------------------------------------------------- *)
(* Shared fixtures (inline, no shared helpers per convention)                 *)
(* -------------------------------------------------------------------------- *)

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let tool_call_response calls : llm_response =
  { text = None; tool_calls = Some calls; finish_reason = Tool_calls;
    usage = dummy_usage; model = "mock" }

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unsupported"

let with_token f =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let token = Cancellation.create_token sw in
      f token))

let with_switch f =
  Eio_main.run (fun _env ->
    Eio.Switch.run f)

let str_contains haystack needle =
  let rec aux i =
    if i + String.length needle > String.length haystack then false
    else if String.sub haystack i (String.length needle) = needle then true
    else aux (i + 1)
  in
  aux 0

let make_tool ?(name = "test_tool") handler : tool_binding =
  let descriptor = {
    name;
    description = "A test tool";
    input_schema = `Assoc [];
    output_schema = None;
    permission = Allow;
    timeout = None;
    concurrency_limit = None;
    on_update = None;
    cache_control = None
  } in
  { descriptor; handler }

let make_agent ?(max_iterations = 10) ?(approval_handler = None)
    ?(tools = []) id system_prompt : agent_config =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id; system_prompt = stable_prompt system_prompt;
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations;
    middleware = []; retry_policy = None; context_strategy = None;
    resource_quota = None; max_execution_time = None; tool_timeout = None;
    early_stopping_method = Force; on_max_tokens = Some Return_partial;
    max_continuation_chunks = Some 3;
    context_compression_threshold = None; compression_cooldown_messages = None;
    context_window_override = None; cache_strategy = No_caching;
    approval_handler }

let make_registry tools =
  let reg = Tool_registry.create () in
  List.iter (fun (tb : tool_binding) ->
    ignore (Tool_registry.register reg tb.descriptor tb.handler)
  ) tools;
  reg

let system_prompt_of conv =
  match conv.messages with
  | { role = System; content_blocks = [Text_block { text = s; cache_control = None }]; _ } :: _ -> Some s
  | _ -> None

let mock_llm_dynamic f : llm_service =
  { complete_fn = (fun _model _tools conv -> Ok (f conv));
    stream_fn = (fun _ _tools _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None;
  }

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

let tool_call ?(id = "tc-1") ?(name = "guarded_tool") () : tool_call =
  { id; name; arguments = `Assoc [] }

let check_ok_text (resp : (llm_response * conversation, error_category * conversation) result) expected =
  match resp with
  | Ok (r, _) ->
    Alcotest.(check (option string)) "text" (Some expected) r.text
  | Error (e, _) ->
    Alcotest.fail ("expected Ok, got Error: " ^ error_to_string e)

(* -------------------------------------------------------------------------- *)
(* Runtime helpers for resume_approval tests                                  *)
(* -------------------------------------------------------------------------- *)

let runtime_config () : runtime_config =
  { persistence = `Sqlite ":memory:";
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
    parallel_tool_execution = true;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = 604800.0; }

let make_sqlite_persist (sqlt : Sqlite_persistence.t) : persistence_service =
  { save_events_fn = (fun ?scope envs -> Sqlite_persistence.save_events ?scope sqlt envs);
    load_events_fn = (fun tid -> Sqlite_persistence.load_events sqlt tid);
    load_events_by_session_fn =
      (fun ?scope sid -> Sqlite_persistence.load_events_by_session ?scope sqlt sid);
    load_sessions_fn = (fun ?scope lim -> Sqlite_persistence.load_sessions ?scope sqlt lim);
    save_task_state_fn = (fun ts -> Sqlite_persistence.save_task_state sqlt ts);
    load_task_state_fn = (fun tid -> Sqlite_persistence.load_task_state sqlt tid);
    save_workflow_state_fn = (fun id st cp -> Sqlite_persistence.save_workflow_state sqlt id st cp);
    load_workflow_state_fn = (fun id -> Sqlite_persistence.load_workflow_state sqlt id);
    load_all_suspended_workflows_fn = (fun () -> Sqlite_persistence.load_all_suspended_workflows sqlt);
    save_workflow_def_fn = (fun id def -> Sqlite_persistence.save_workflow_def sqlt id def);
    load_all_workflow_defs_fn = (fun () -> Sqlite_persistence.load_all_workflow_defs sqlt);
    save_conversation_fn = (fun ?scope sid conv -> Sqlite_persistence.save_conversation ?scope sqlt sid conv);
    load_conversation_fn = (fun sid -> Sqlite_persistence.load_conversation sqlt sid);
    load_most_recent_conversation_fn = (fun ?scope () -> Sqlite_persistence.load_most_recent_conversation ?scope sqlt);
    save_pending_approval_fn =
      (fun ~run_id ~agent_id ~payload ~expires_at ->
        Sqlite_persistence.save_pending_approval sqlt ~run_id ~agent_id ~payload ~expires_at);
    load_pending_approval_fn =
      (fun ~run_id -> Sqlite_persistence.load_pending_approval sqlt ~run_id);
    delete_pending_approval_fn =
      (fun ~run_id -> Sqlite_persistence.delete_pending_approval sqlt ~run_id);
    close_fn = (fun () -> Sqlite_persistence.close sqlt); }

let create_runtime ?(llm = mock_llm [text_response "default"]) ?persistence sw =
  let persist = match persistence with
    | Some p -> p
    | None ->
      match Sqlite_persistence.create ":memory:" with
      | Error e -> Alcotest.failf "sqlite create: %s" (error_to_string e)
      | Ok sqlt -> make_sqlite_persist sqlt
  in
  match Runtime.create ~llm ~persistence:persist ~config:(runtime_config ()) sw with
  | Ok rt -> rt
  | Error e -> Alcotest.failf "create_runtime: %s" (error_to_string e)

(* Approval tool that returns Approval_required *)
let approval_tool ?(name = "guarded_tool") ?(prompt = "Approve?")
    ?(timeout = Some 60.0) ?(allowed_roles = []) () : tool_binding =
  let descriptor = {
    name; description = "Tool requiring approval";
    input_schema = `Assoc []; output_schema = None;
    permission = Allow; timeout = None; concurrency_limit = None;
    on_update = None; cache_control = None
  } in
  let handler _input _tok =
    Approval_required {
      tool_name = name; tool_input = `Assoc [];
      prompt; timeout; allowed_roles
    }
  in
  { descriptor; handler }

(* ======================================================================== *)
(* Engine-level HITL tests — Sync_local approval outcomes                   *)
(* ======================================================================== *)

let test_sync_approved_executes_tool () =
  (* Sync_local returns Approved → engine synthesizes Success result *)
  let guarded = approval_tool () in
  let llm = mock_llm [
    tool_call_response [ tool_call () ];
    text_response "done";
  ] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx -> Approval.Approved)))
    ~tools:[guarded] in
  let reg = make_registry [guarded] in
  with_token (fun token ->
    match Engine.run_agent token agent "do it" llm reg with
    | Ok (resp, conv) ->
      (* Terminal response text *)
      Alcotest.(check (option string)) "final text" (Some "done") resp.text;
      (* Tool result message present (synthetic approved result) *)
      let has_approved = List.exists (fun (m : message) ->
        m.role = Tool && str_contains (Message.text_of_message m) "approved"
      ) conv.messages in
      Alcotest.(check bool) "tool result with approved" true has_approved
    | Error (e, _) ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_sync_rejected_marks_rejected () =
  let guarded = approval_tool () in
  let llm = mock_llm [
    tool_call_response [ tool_call () ];
    text_response "after reject";
  ] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx ->
      Approval.Rejected { reason = "not safe" })))
    ~tools:[guarded] in
  let reg = make_registry [guarded] in
  with_token (fun token ->
    match Engine.run_agent token agent "do it" llm reg with
    | Ok (_resp, conv) ->
      let has_rejected = List.exists (fun (m : message) ->
        m.role = Tool && str_contains (Message.text_of_message m) "not safe"
      ) conv.messages in
      Alcotest.(check bool) "tool result with rejection reason" true has_rejected
    | Error (e, _) ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_sync_modified_reruns_with_new_input () =
  let captured_input = ref `Null in
  let call_count = ref 0 in
  let tool_desc = {
    name = "guarded_tool"; description = "Tool requiring approval";
    input_schema = `Assoc []; output_schema = None;
    permission = Allow; timeout = None; concurrency_limit = None;
    on_update = None; cache_control = None
  } in
  let handler input _tok =
    incr call_count;
    if !call_count = 1 then
      Approval_required {
        tool_name = "guarded_tool"; tool_input = input;
        prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
      }
    else begin
      captured_input := input;
      Success (`String "modified-result")
    end
  in
  let tool_binding = { descriptor = tool_desc; handler } in
  let llm = mock_llm [
    tool_call_response [ tool_call () ];
    text_response "done";
  ] in
  let new_input = `Assoc [("key", `String "new_value")] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx ->
      Approval.Modified { new_input })))
    ~tools:[tool_binding] in
  let reg = make_registry [tool_binding] in
  with_token (fun token ->
    match Engine.run_agent token agent "do it" llm reg with
    | Ok (_resp, _conv) ->
      Alcotest.(check string) "tool received modified input"
        (Yojson.Safe.to_string new_input)
        (Yojson.Safe.to_string !captured_input)
    | Error (e, _) ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_sync_escalated_switches_agent () =
  let guarded = approval_tool () in
  let b_called = ref false in
  let llm = mock_llm_dynamic (fun conv ->
    match system_prompt_of conv with
    | Some "You are B" ->
      b_called := true;
      text_response "B handled it"
    | _ ->
      tool_call_response [ tool_call () ]
  ) in
  let agent_a = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx ->
      Approval.Escalated { target = "B" })))
    ~tools:[guarded] in
  let agent_b = make_agent "B" "You are B" in
  let reg = make_registry [guarded] in
  let resolver = function "B" -> Some agent_b | _ -> None in
  with_token (fun token ->
    match Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
            token agent_a "do it" llm reg with
    | Ok (resp, _conv) ->
      Alcotest.(check bool) "agent B was called" true !b_called;
      Alcotest.(check (option string)) "B response" (Some "B handled it") resp.text
    | Error (e, _) ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_sync_timeout_rejects_with_timeout_event () =
  let events = ref [] in
  let guarded = approval_tool () in
  let llm = mock_llm [
    tool_call_response [ tool_call () ];
    text_response "after timeout";
  ] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx -> Approval.Timeout)))
    ~tools:[guarded] in
  let reg = make_registry [guarded] in
  with_token (fun token ->
    match Engine.run_agent
            ~on_tool_event:(Some (fun ev -> events := ev :: !events))
            token agent "do it" llm reg with
    | Ok (_resp, conv) ->
      (* Approval_timeout event emitted *)
      let found = List.exists (function
        | Approval_timeout -> true | _ -> false) !events in
      Alcotest.(check bool) "Approval_timeout event" true found;
      (* Tool result is error with timeout message *)
      let has_timeout = List.exists (fun (m : message) ->
        m.role = Tool && str_contains (Message.text_of_message m) "timed out"
      ) conv.messages in
      Alcotest.(check bool) "tool result with timeout" true has_timeout
    | Error (e, _) ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

let test_no_handler_emits_handler_missing_and_errors () =
  let events = ref [] in
  let guarded = approval_tool () in
  let llm = mock_llm [
    tool_call_response [ tool_call () ];
    text_response "should not reach";
  ] in
  (* Agent has NO approval_handler *)
  let agent = make_agent "A" "You are A" ~tools:[guarded] in
  let reg = make_registry [guarded] in
  with_token (fun token ->
    match Engine.run_agent
            ~on_tool_event:(Some (fun ev -> events := ev :: !events))
            token agent "do it" llm reg with
    | Ok _ -> Alcotest.fail "expected Error for missing handler"
    | Error (Internal msg, _) ->
      Alcotest.(check bool) "mentions handler missing" true
        (str_contains msg "Approval_handler_missing");
      let found = List.exists (function
        | Approval_handler_missing _ -> true | _ -> false) !events in
      Alcotest.(check bool) "Approval_handler_missing event" true found
    | Error (e, _) ->
      Alcotest.failf "expected Internal, got: %s" (error_to_string e))

(* ======================================================================== *)
(* Engine-level HITL tests — Async/Webhook raise Approval_pending           *)
(* ======================================================================== *)

let test_async_callback_raises_approval_pending () =
  let guarded = approval_tool () in
  let llm = mock_llm [
    tool_call_response [ tool_call () ];
    text_response "should not reach";
  ] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Async_callback (fun _ctx ->
      Eio.Promise.create_resolved Approval.Approved)))
    ~tools:[guarded] in
  let reg = make_registry [guarded] in
  with_token (fun token ->
    let caught = ref false in
    (try
       ignore (Engine.run_agent ~runtime_id:"test-run" token agent "do it" llm reg)
     with Engine.Approval_pending payload ->
       caught := true;
       Alcotest.(check string) "agent_id" "A" payload.agent_id;
       Alcotest.(check string) "tool_name" "guarded_tool" payload.tool_name;
       Alcotest.(check string) "run_id" "test-run" payload.run_id;
       Alcotest.(check bool) "expires_at > 0" true (payload.expires_at > 0.0));
    Alcotest.(check bool) "Approval_pending raised" true !caught)

let test_webhook_raises_approval_pending () =
  let guarded = approval_tool () in
  let llm = mock_llm [
    tool_call_response [ tool_call () ];
    text_response "should not reach";
  ] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Webhook {
      url = "https://example.com/approve";
      secret = "s3cret";
      timeout_sec = 120.0;
    }))
    ~tools:[guarded] in
  let reg = make_registry [guarded] in
  with_token (fun token ->
    let caught = ref false in
    (try
       ignore (Engine.run_agent ~runtime_id:"webhook-run" token agent "do it" llm reg)
     with Engine.Approval_pending payload ->
       caught := true;
       Alcotest.(check string) "agent_id" "A" payload.agent_id;
       Alcotest.(check string) "tool_name" "guarded_tool" payload.tool_name;
       Alcotest.(check string) "run_id" "webhook-run" payload.run_id);
    Alcotest.(check bool) "Approval_pending raised" true !caught)

(* ======================================================================== *)
(* Engine-level HITL tests — multiple approvals in batch                    *)
(* ======================================================================== *)

let test_multiple_approvals_in_batch_errors () =
  let guarded1 = approval_tool ~name:"guard1" () in
  let guarded2 = approval_tool ~name:"guard2" () in
  let llm = mock_llm [
    tool_call_response [
      tool_call ~id:"tc-1" ~name:"guard1" ();
      tool_call ~id:"tc-2" ~name:"guard2" ();
    ];
    text_response "should not reach";
  ] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx -> Approval.Approved)))
    ~tools:[guarded1; guarded2] in
  let reg = make_registry [guarded1; guarded2] in
  with_token (fun token ->
    match Engine.run_agent token agent "do it" llm reg with
    | Ok _ -> Alcotest.fail "expected Error for multiple approvals"
    | Error (Invalid_input msg, _) ->
      Alcotest.(check bool) "mentions multiple approvals" true
        (str_contains msg "Multiple approvals")
    | Error (e, _) ->
      Alcotest.failf "expected Invalid_input, got: %s" (error_to_string e))

(* ======================================================================== *)
(* Engine-level HITL tests — approval events emitted                        *)
(* ======================================================================== *)

let test_approval_granted_event_emitted () =
  let events = ref [] in
  let guarded = approval_tool () in
  let llm = mock_llm [
    tool_call_response [ tool_call () ];
    text_response "done";
  ] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx -> Approval.Approved)))
    ~tools:[guarded] in
  let reg = make_registry [guarded] in
  with_token (fun token ->
    check_ok_text
      (Engine.run_agent
         ~on_tool_event:(Some (fun ev -> events := ev :: !events))
         token agent "do it" llm reg)
      "done";
    let found = List.exists (function
      | Approval_granted _ -> true | _ -> false) !events in
    Alcotest.(check bool) "Approval_granted event" true found)

let test_approval_rejected_event_emitted () =
  let events = ref [] in
  let guarded = approval_tool () in
  let llm = mock_llm [
    tool_call_response [ tool_call () ];
    text_response "after";
  ] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx ->
      Approval.Rejected { reason = "nope" })))
    ~tools:[guarded] in
  let reg = make_registry [guarded] in
  with_token (fun token ->
    ignore (Engine.run_agent
              ~on_tool_event:(Some (fun ev -> events := ev :: !events))
              token agent "do it" llm reg);
    let found = List.exists (function
      | Approval_rejected _ -> true | _ -> false) !events in
    Alcotest.(check bool) "Approval_rejected event" true found)

let test_approval_modified_event_emitted () =
  let events = ref [] in
  let call_count = ref 0 in
  let tool_desc = {
    name = "guarded_tool"; description = "Tool requiring approval";
    input_schema = `Assoc []; output_schema = None;
    permission = Allow; timeout = None; concurrency_limit = None;
    on_update = None; cache_control = None
  } in
  let handler input _tok =
    incr call_count;
    if !call_count = 1 then
      Approval_required {
        tool_name = "guarded_tool"; tool_input = input;
        prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
      }
    else
      Success (`String "ok")
  in
  let tool_binding = { descriptor = tool_desc; handler } in
  let llm = mock_llm [
    tool_call_response [ tool_call () ];
    text_response "done";
  ] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx ->
      Approval.Modified { new_input = `String "x" })))
    ~tools:[tool_binding] in
  let reg = make_registry [tool_binding] in
  with_token (fun token ->
    ignore (Engine.run_agent
              ~on_tool_event:(Some (fun ev -> events := ev :: !events))
              token agent "do it" llm reg);
    let found = List.exists (function
      | Approval_modified _ -> true | _ -> false) !events in
    Alcotest.(check bool) "Approval_modified event" true found)

let test_approval_escalated_event_emitted () =
  let events = ref [] in
  let guarded = approval_tool () in
  let llm = mock_llm_dynamic (fun conv ->
    match system_prompt_of conv with
    | Some "You are B" -> text_response "B ok"
    | _ -> tool_call_response [ tool_call () ]
  ) in
  let agent_a = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx ->
      Approval.Escalated { target = "B" })))
    ~tools:[guarded] in
  let agent_b = make_agent "B" "You are B" in
  let reg = make_registry [guarded] in
  let resolver = function "B" -> Some agent_b | _ -> None in
  with_token (fun token ->
    ignore (Engine.run_agent ~agent_resolver:resolver ~enable_handoff:true
              ~on_tool_event:(Some (fun ev -> events := ev :: !events))
              token agent_a "do it" llm reg);
    let found = List.exists (function
      | Approval_escalated _ -> true | _ -> false) !events in
    Alcotest.(check bool) "Approval_escalated event" true found)

(* ======================================================================== *)
(* Engine-level HITL tests — approval with non-approval tools in batch      *)
(* ======================================================================== *)

let test_approval_with_non_approval_tools_in_batch () =
  (* When a batch has both approval and non-approval tools,
     non-approval tools execute first, then approval is processed *)
  let ok_tool = make_tool ~name:"ok_tool" (fun _ _ ->
    Success (`String "ok-result")) in
  let guarded = approval_tool () in
  let llm = mock_llm [
    tool_call_response [
      tool_call ~id:"tc-ok" ~name:"ok_tool" ();
      tool_call ~id:"tc-g" ~name:"guarded_tool" ();
    ];
    text_response "done";
  ] in
  let agent = make_agent "A" "You are A"
    ~approval_handler:(Some (Sync_local (fun _ctx -> Approval.Approved)))
    ~tools:[ok_tool; guarded] in
  let reg = make_registry [ok_tool; guarded] in
  with_token (fun token ->
    match Engine.run_agent token agent "do it" llm reg with
    | Ok (_resp, conv) ->
      (* ok_tool result present *)
      let has_ok = List.exists (fun (m : message) ->
        m.role = Tool && str_contains (Message.text_of_message m) "ok-result"
      ) conv.messages in
      Alcotest.(check bool) "ok_tool result present" true has_ok;
      (* approval result present *)
      let has_approved = List.exists (fun (m : message) ->
        m.role = Tool && str_contains (Message.text_of_message m) "approved"
      ) conv.messages in
      Alcotest.(check bool) "approval result present" true has_approved
    | Error (e, _) ->
      Alcotest.failf "expected Ok: %s" (error_to_string e))

(* ======================================================================== *)
(* Runtime-level HITL tests — resume_approval                               *)
(* ======================================================================== *)

let test_resume_approved_completes () =
  with_switch (fun sw ->
    let llm = mock_llm_dynamic (fun conv ->
      let has_continue = List.exists (fun (m : message) ->
        m.role = User &&
        str_contains (Message.text_of_message m) "Approval resolved"
      ) conv.messages in
      if has_continue then text_response "approval flow complete"
      else tool_call_response [ tool_call () ]
    ) in
    let guarded = approval_tool () in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Async_callback (fun _ctx ->
        Eio.Promise.create_resolved Approval.Approved)))
      ~tools:[guarded] in
    let rt = create_runtime ~llm sw in
    (match Runtime.register_agent rt agent with
     | Ok () -> () | Error e -> Alcotest.failf "register_agent: %s" (error_to_string e));
    (match Runtime.register_tool rt ~name:"guarded_tool"
            ~description:"approval tool" ~input_schema:(`Assoc [])
            ~handler:(fun _input _tok ->
              Approval_required {
                tool_name = "guarded_tool"; tool_input = `Assoc [];
                prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
              }) () with
     | Ok _ -> () | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e));
    match Runtime.invoke rt ~agent_id:"A" ~message:"do it" () with
    | Error (e, _) ->
      Alcotest.failf "invoke failed: %s" (error_to_string e)
    | Ok result ->
      (match result.approval_pending with
       | None -> Alcotest.fail "expected approval_pending"
       | Some info ->
         Alcotest.(check bool) "run_id non-empty" true (info.run_id <> "");
         Alcotest.(check string) "agent_id" "A" info.agent_id;
         Alcotest.(check string) "tool_name" "guarded_tool" info.tool_name;
         (match Runtime.resume_approval ~rt ~run_id:info.run_id
                 ~outcome:Approval.Approved ~approver:"test-user" with
          | Ok () -> ()
          | Error e ->
            Alcotest.failf "resume_approval failed: %s" (error_to_string e))))

let test_resume_preserves_original_context () =
  with_switch (fun sw ->
    let saw_original_in_resume = ref false in
    let llm = mock_llm_dynamic (fun conv ->
      let has_approval_resolved = List.exists (fun (m : message) ->
        m.role = User && str_contains (Message.text_of_message m) "Approval resolved"
      ) conv.messages in
      let has_original_do_it = List.exists (fun (m : message) ->
        m.role = User && str_contains (Message.text_of_message m) "do it"
      ) conv.messages in
      if has_approval_resolved then begin
        if has_original_do_it then saw_original_in_resume := true;
        text_response "context preserved"
      end else
        tool_call_response [ tool_call () ]
    ) in
    let guarded = approval_tool () in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Async_callback (fun _ctx ->
        Eio.Promise.create_resolved Approval.Approved)))
      ~tools:[guarded] in
    let rt = create_runtime ~llm sw in
    (match Runtime.register_agent rt agent with
     | Ok () -> () | Error e -> Alcotest.failf "register_agent: %s" (error_to_string e));
    (match Runtime.register_tool rt ~name:"guarded_tool"
            ~description:"approval tool" ~input_schema:(`Assoc [])
            ~handler:(fun _input _tok ->
              Approval_required {
                tool_name = "guarded_tool"; tool_input = `Assoc [];
                prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
              }) () with
     | Ok _ -> () | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e));
    match Runtime.invoke rt ~agent_id:"A" ~message:"do it" () with
    | Error (e, _) -> Alcotest.failf "invoke failed: %s" (error_to_string e)
    | Ok result ->
      (match result.approval_pending with
       | None -> Alcotest.fail "expected approval_pending"
       | Some info ->
         (match Runtime.resume_approval ~rt ~run_id:info.run_id
                 ~outcome:Approval.Approved ~approver:"test-user" with
          | Ok () ->
            Alcotest.(check bool)
              "LLM saw original 'do it' message in resumed conversation"
              true !saw_original_in_resume
          | Error e ->
            Alcotest.failf "resume_approval failed: %s" (error_to_string e))))

let test_resume_rejected_no_redispatch () =
  with_switch (fun sw ->
    let llm = mock_llm [
      tool_call_response [ tool_call () ];
      text_response "unused";
    ] in
    let guarded = approval_tool () in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Async_callback (fun _ctx ->
        Eio.Promise.create_resolved Approval.Approved)))
      ~tools:[guarded] in
    let rt = create_runtime ~llm sw in
    (match Runtime.register_agent rt agent with
     | Ok () -> () | Error e -> Alcotest.failf "register: %s" (error_to_string e));
    (match Runtime.register_tool rt ~name:"guarded_tool"
            ~description:"approval tool" ~input_schema:(`Assoc [])
            ~handler:(fun _ _ ->
              Approval_required {
                tool_name = "guarded_tool"; tool_input = `Assoc [];
                prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
              }) () with
     | Ok _ -> () | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e));
    match Runtime.invoke rt ~agent_id:"A" ~message:"do it" () with
    | Error (e, _) ->
      Alcotest.failf "invoke failed: %s" (error_to_string e)
    | Ok result ->
      (match result.approval_pending with
       | None -> Alcotest.fail "expected approval_pending"
       | Some info ->
         match Runtime.resume_approval ~rt ~run_id:info.run_id
                 ~outcome:(Approval.Rejected { reason = "denied" })
                 ~approver:"test-user" with
         | Ok () -> ()  (* Rejected does not re-dispatch, returns Ok () *)
         | Error e ->
            Alcotest.failf "resume_approval rejected failed: %s" (error_to_string e)))

let test_resume_timeout_no_redispatch () =
  with_switch (fun sw ->
    let llm = mock_llm [
      tool_call_response [ tool_call () ];
      text_response "unused";
    ] in
    let guarded = approval_tool () in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Async_callback (fun _ctx ->
        Eio.Promise.create_resolved Approval.Approved)))
      ~tools:[guarded] in
    let rt = create_runtime ~llm sw in
    (match Runtime.register_agent rt agent with
     | Ok () -> () | Error e -> Alcotest.failf "register: %s" (error_to_string e));
    (match Runtime.register_tool rt ~name:"guarded_tool"
            ~description:"approval tool" ~input_schema:(`Assoc [])
            ~handler:(fun _ _ ->
              Approval_required {
                tool_name = "guarded_tool"; tool_input = `Assoc [];
                prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
              }) () with
     | Ok _ -> () | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e));
    match Runtime.invoke rt ~agent_id:"A" ~message:"do it" () with
    | Error (e, _) ->
      Alcotest.failf "invoke failed: %s" (error_to_string e)
    | Ok result ->
      (match result.approval_pending with
       | None -> Alcotest.fail "expected approval_pending"
       | Some info ->
         match Runtime.resume_approval ~rt ~run_id:info.run_id
                 ~outcome:Approval.Timeout ~approver:"system" with
         | Ok () -> ()  (* Timeout does not re-dispatch *)
         | Error e ->
            Alcotest.failf "resume_approval timeout failed: %s" (error_to_string e)))

let test_resume_unknown_run_id_errors () =
  with_switch (fun sw ->
    let llm = mock_llm [text_response "unused"] in
    let rt = create_runtime ~llm sw in
    match Runtime.resume_approval ~rt ~run_id:"nonexistent-id"
            ~outcome:Approval.Approved ~approver:"test" with
    | Error (Invalid_input msg) ->
      Alcotest.(check bool) "mentions not found or expired" true
        (str_contains msg "not found" || str_contains msg "expired")
    | Ok () -> Alcotest.fail "expected Error for unknown run_id"
    | Error e ->
      Alcotest.failf "expected Invalid_input, got: %s" (error_to_string e))

let test_resume_emits_events () =
  with_switch (fun sw ->
    let llm = mock_llm_dynamic (fun conv ->
      let has_continue = List.exists (fun (m : message) ->
        m.role = User &&
        str_contains (Message.text_of_message m) "Approval resolved"
      ) conv.messages in
      if has_continue then text_response "resumed ok"
      else tool_call_response [ tool_call () ]
    ) in
    let guarded = approval_tool () in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Async_callback (fun _ctx ->
        Eio.Promise.create_resolved Approval.Approved)))
      ~tools:[guarded] in
    let rt = create_runtime ~llm sw in
    (match Runtime.register_agent rt agent with
     | Ok () -> () | Error e -> Alcotest.failf "register: %s" (error_to_string e));
    (match Runtime.register_tool rt ~name:"guarded_tool"
            ~description:"approval tool" ~input_schema:(`Assoc [])
            ~handler:(fun _ _ ->
              Approval_required {
                tool_name = "guarded_tool"; tool_input = `Assoc [];
                prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
              }) () with
     | Ok _ -> () | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e));
    match Runtime.invoke rt ~agent_id:"A" ~message:"do it" () with
    | Error (e, _) ->
      Alcotest.failf "invoke: %s" (error_to_string e)
    | Ok result ->
      (match result.approval_pending with
       | None -> Alcotest.fail "expected approval_pending"
       | Some info ->
         (match Runtime.resume_approval ~rt ~run_id:info.run_id
                 ~outcome:Approval.Approved ~approver:"admin" with
          | Ok () -> ()
          | Error e ->
            Alcotest.failf "resume: %s" (error_to_string e))))

let test_invoke_catches_approval_pending () =
  (* Verify Runtime.invoke catches Approval_pending and returns
     approval_pending info instead of propagating the exception *)
  with_switch (fun sw ->
    let llm = mock_llm [
      tool_call_response [ tool_call () ];
      text_response "should not reach";
    ] in
    let guarded = approval_tool () in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Async_callback (fun _ctx ->
        Eio.Promise.create_resolved Approval.Approved)))
      ~tools:[guarded] in
    let rt = create_runtime ~llm sw in
    (match Runtime.register_agent rt agent with
     | Ok () -> () | Error e -> Alcotest.failf "register: %s" (error_to_string e));
    (match Runtime.register_tool rt ~name:"guarded_tool"
            ~description:"approval tool" ~input_schema:(`Assoc [])
            ~handler:(fun _ _ ->
              Approval_required {
                tool_name = "guarded_tool"; tool_input = `Assoc [];
                prompt = "Approve?"; timeout = Some 60.0; allowed_roles = []
              }) () with
     | Ok _ -> () | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e));
    match Runtime.invoke rt ~agent_id:"A" ~message:"do it" () with
    | Error (e, _) ->
      Alcotest.failf "invoke should not error: %s" (error_to_string e)
    | Ok result ->
      Alcotest.(check bool) "approval_pending is Some" true
        (Option.is_some result.approval_pending);
      (match result.approval_pending with
       | None -> ()
       | Some info ->
         Alcotest.(check string) "agent_id" "A" info.agent_id;
         Alcotest.(check string) "tool_name" "guarded_tool" info.tool_name;
         Alcotest.(check bool) "run_id non-empty" true (info.run_id <> "")))

let test_resume_approval_missing_agent_emits_handler_missing () =
  with_switch (fun sw ->
    let llm = mock_llm [text_response "unused"] in
    let pending_store = Hashtbl.create 4 in
    let persist : persistence_service = {
      save_events_fn = (fun ?scope:_ _ -> Ok ());
      load_events_fn = (fun _ -> Ok []);
      load_events_by_session_fn = (fun ?scope:_ _ -> Ok []);
      load_sessions_fn = (fun ?scope:_ _ -> Ok []);
      save_task_state_fn = (fun _ -> Ok ());
      load_task_state_fn = (fun _ -> Ok None);
      save_workflow_state_fn = (fun _ _ _ -> Ok ());
      load_workflow_state_fn = (fun _ -> Ok None);
      load_all_suspended_workflows_fn = (fun () -> Ok []);
      save_workflow_def_fn = (fun _ _ -> Ok ());
      load_all_workflow_defs_fn = (fun () -> Ok []);
      save_conversation_fn = (fun ?scope:_ _ _ -> Ok ());
      load_conversation_fn = (fun _ -> Ok None);
      load_most_recent_conversation_fn = (fun ?scope:_ () -> Ok None);
      save_pending_approval_fn =
        (fun ~run_id ~agent_id ~payload ~expires_at ->
          Hashtbl.replace pending_store run_id
            (agent_id, payload, expires_at);
          Ok ());
      load_pending_approval_fn =
        (fun ~run_id ->
          match Hashtbl.find_opt pending_store run_id with
          | Some (_, payload, _) -> Ok (Some payload)
          | None -> Ok None);
      delete_pending_approval_fn =
        (fun ~run_id ->
          Hashtbl.remove pending_store run_id;
          Ok ());
      close_fn = ignore;
    } in
    let rt = create_runtime ~llm ~persistence:persist sw in
    let run_id = "test-missing-agent-run" in
    Hashtbl.replace pending_store run_id
      ("nonexistent",
       `Assoc [("agent_id", `String "nonexistent");
               ("tool_name", `String "t");
               ("conv_snapshot",
                Types.conversation_to_yojson { messages = []; metadata = [] })],
       Unix.gettimeofday () +. 300.0);
    match Runtime.resume_approval ~rt ~run_id
            ~outcome:Approval.Approved ~approver:"admin" with
    | Error (Invalid_input msg) ->
      Alcotest.(check bool) "mentions not registered" true
        (str_contains msg "not registered")
    | Ok () -> Alcotest.fail "expected Error for missing agent"
    | Error e ->
      Alcotest.failf "expected Invalid_input, got: %s" (error_to_string e))

(* ======================================================================== *)
(* Suite wiring                                                             *)
(* ======================================================================== *)

let () =
  Alcotest.run "Engine HITL" [
    ("Sync_local outcomes", [
      Alcotest.test_case "Approved executes tool (synthetic Success)" `Quick
        test_sync_approved_executes_tool;
      Alcotest.test_case "Rejected marks tool result rejected" `Quick
        test_sync_rejected_marks_rejected;
      Alcotest.test_case "Modified reruns tool with new_input" `Quick
        test_sync_modified_reruns_with_new_input;
      Alcotest.test_case "Escalated switches to target agent" `Quick
        test_sync_escalated_switches_agent;
      Alcotest.test_case "Timeout rejects + Approval_timeout event" `Quick
        test_sync_timeout_rejects_with_timeout_event;
    ]);
    ("Approval handler missing", [
      Alcotest.test_case "no handler emits Approval_handler_missing + Error" `Quick
        test_no_handler_emits_handler_missing_and_errors;
    ]);
    ("Async/Webhook raises Approval_pending", [
      Alcotest.test_case "Async_callback raises Approval_pending" `Quick
        test_async_callback_raises_approval_pending;
      Alcotest.test_case "Webhook raises Approval_pending" `Quick
        test_webhook_raises_approval_pending;
    ]);
    ("Multiple approvals in batch", [
      Alcotest.test_case "multiple Approval_required in batch → Error" `Quick
        test_multiple_approvals_in_batch_errors;
    ]);
    ("Approval events", [
      Alcotest.test_case "Approval_granted event emitted" `Quick
        test_approval_granted_event_emitted;
      Alcotest.test_case "Approval_rejected event emitted" `Quick
        test_approval_rejected_event_emitted;
      Alcotest.test_case "Approval_modified event emitted" `Quick
        test_approval_modified_event_emitted;
      Alcotest.test_case "Approval_escalated event emitted" `Quick
        test_approval_escalated_event_emitted;
    ]);
    ("Mixed batch (approval + non-approval)", [
      Alcotest.test_case "non-approval tools execute alongside approval" `Quick
        test_approval_with_non_approval_tools_in_batch;
    ]);
    ("Runtime.invoke catches Approval_pending", [
      Alcotest.test_case "invoke returns approval_pending info" `Quick
        test_invoke_catches_approval_pending;
    ]);
    ("Runtime.resume_approval", [
      Alcotest.test_case "Approved → re-dispatches, conversation completes" `Quick
        test_resume_approved_completes;
      Alcotest.test_case "Rejected → no re-dispatch, returns Ok" `Quick
        test_resume_rejected_no_redispatch;
      Alcotest.test_case "Timeout → no re-dispatch, returns Ok" `Quick
        test_resume_timeout_no_redispatch;
      Alcotest.test_case "unknown run_id → Error" `Quick
        test_resume_unknown_run_id_errors;
      Alcotest.test_case "resume emits Approval_granted event" `Quick
        test_resume_emits_events;
      Alcotest.test_case "missing agent → Approval_handler_missing event" `Quick
        test_resume_approval_missing_agent_emits_handler_missing;
      Alcotest.test_case "resume preserves original user message in conv" `Quick
        test_resume_preserves_original_context;
    ]);
  ]
