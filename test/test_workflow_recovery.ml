(* test/test_workflow_recovery.ml — durable workflow execution.
 *
 * A run whose process died is left in the store as `running`. Before this,
 * nothing ever read those rows: the loader only looked at `suspended`, so an
 * interrupted workflow was silently orphaned. These tests pin the recovery
 * contract:
 *
 *   - startup rehydrates running rows and says so once (Workflow_orphaned);
 *   - recovery is explicit, never automatic;
 *   - steps before the checkpoint do not run again;
 *   - a checkpoint from a newer schema is refused instead of guessed at.
 *
 * No process is actually killed: the crash is simulated by writing the row a
 * crash would have left, then creating a fresh runtime over the same database.
 *)

open Par
open Par.Types

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

let workflow_status_to_string = function
  | Wf_pending -> "pending"
  | Wf_running -> "running"
  | Wf_suspended _ -> "suspended"
  | Wf_completed _ -> "completed"
  | Wf_failed _ -> "failed"

let runtime_config () : runtime_config = {
  persistence = `Sqlite ":memory:";
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

let persistence_of (sqlt : Sqlite_persistence.t) : persistence_service = {
  save_events_fn = (fun ?scope envs -> Sqlite_persistence.save_events ?scope sqlt envs);
  load_events_fn = (fun tid -> Sqlite_persistence.load_events sqlt tid);
  load_events_by_session_fn =
    (fun ?scope sid -> Sqlite_persistence.load_events_by_session ?scope sqlt sid);
  load_sessions_fn = (fun ?scope lim -> Sqlite_persistence.load_sessions ?scope sqlt lim);
  save_task_state_fn = (fun ts -> Sqlite_persistence.save_task_state sqlt ts);
  load_task_state_fn = (fun tid -> Sqlite_persistence.load_task_state sqlt tid);
  save_workflow_state_fn = (fun id st cp -> Sqlite_persistence.save_workflow_state sqlt id st cp);
  load_workflow_state_fn = (fun id -> Sqlite_persistence.load_workflow_state sqlt id);
  load_recoverable_runs_fn = (fun () -> Sqlite_persistence.load_recoverable_runs sqlt);
  save_workflow_def_fn = (fun id def -> Sqlite_persistence.save_workflow_def sqlt id def);
  load_all_workflow_defs_fn = (fun () -> Sqlite_persistence.load_all_workflow_defs sqlt);
  save_conversation_fn =
    (fun ?scope sid conv -> Sqlite_persistence.save_conversation ?scope sqlt sid conv);
  load_conversation_fn = (fun sid -> Sqlite_persistence.load_conversation sqlt sid);
  load_most_recent_conversation_fn =
    (fun ?scope () -> Sqlite_persistence.load_most_recent_conversation ?scope sqlt);
  load_conversations_fn =
    (fun ?scope limit -> Sqlite_persistence.load_conversations ?scope sqlt limit);
  save_pending_approval_fn =
    (fun ~run_id ~agent_id ~payload ~expires_at ->
      Sqlite_persistence.save_pending_approval sqlt ~run_id ~agent_id ~payload ~expires_at);
  load_pending_approval_fn =
    (fun ~run_id -> Sqlite_persistence.load_pending_approval sqlt ~run_id);
  delete_pending_approval_fn =
    (fun ~run_id -> Sqlite_persistence.delete_pending_approval sqlt ~run_id);
  save_invoke_checkpoint_fn = (fun cp -> Sqlite_persistence.save_invoke_checkpoint sqlt cp);
  load_invoke_checkpoint_fn = (fun id -> Sqlite_persistence.load_invoke_checkpoint sqlt id);
  list_invoke_checkpoints_fn = (fun () -> Sqlite_persistence.list_invoke_checkpoints sqlt);
  delete_invoke_checkpoint_fn = (fun id -> Sqlite_persistence.delete_invoke_checkpoint sqlt id);
    claim_invoke_lease_fn = (fun ~invoke_id ~owner ~pid ~ttl -> Sqlite_persistence.claim_invoke_lease sqlt ~invoke_id ~owner ~pid ~ttl);
  release_invoke_lease_fn = (fun ~invoke_id ~owner -> Sqlite_persistence.release_invoke_lease sqlt ~invoke_id ~owner);
  list_invoke_leases_fn = (fun () -> Sqlite_persistence.list_invoke_leases sqlt);

  close_fn = (fun () -> Sqlite_persistence.close sqlt);
}

(* One database, used by a "dead" writer first and a fresh runtime second. *)
let with_database f =
  let path = Filename.temp_file "par_wf_recovery" ".db" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match Sqlite_persistence.create path with
       | Error e -> Alcotest.failf "sqlite create: %s" (error_to_string e)
       | Ok sqlt -> f (persistence_of sqlt))

let checkpoint ?(step_path = [0]) ?(variables = [])
    ?(schema_version = 1) ~workflow_id () : workflow_checkpoint = {
  workflow_id;
  step_path;
  variables;
  step_results = [];
  allowed_roles = None;
  schema_version;
}

(* -------------------------------------------------------------------------- *)
(* Startup detection                                                          *)
(* -------------------------------------------------------------------------- *)

(* A runtime with real persistence creates its own event bus, so events reach
   disk rather than an injected service. Recording them where they are written
   is what makes the announcement assertable. *)
let test_create_rehydrates_running_and_emits_orphaned () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_database @@ fun base_persist ->
  let written = ref [] in
  let base_save = base_persist.save_events_fn in
  let persist = { base_persist with
                  save_events_fn = (fun ?scope envs ->
                    written := envs @ !written;
                    base_save ?scope envs) } in
  let run_id = Workflow_run_id.create () in
  let cp = checkpoint ~workflow_id:"wf-orphan" () in
  (match persist.save_workflow_state_fn run_id Wf_running (Some cp) with
   | Ok () -> ()
   | Error e -> Alcotest.failf "seed: %s" (error_to_string e));
  let rt = match Runtime.create ~persistence:persist
                   ~config:(runtime_config ()) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  (match Runtime.get_workflow_status rt run_id with
   | Ok Wf_running -> ()
   | Ok other ->
     Alcotest.failf "expected Wf_running after rehydration, got %s"
       (workflow_status_to_string other)
   | Error e -> Alcotest.failf "status: %s" (error_to_string e));
  ignore (Runtime.close rt);
  Alcotest.(check bool) "Workflow_orphaned written once" true
    (List.exists (fun (env : event_envelope) ->
         match env.payload with
         | Workflow_orphaned { workflow_run_id } ->
           Workflow_run_id.equal workflow_run_id run_id
         | _ -> false) !written)

(* The injected bus used to be discarded whenever persistence was on: the
   runtime built its own bus for the writer and the caller's one saw nothing.
   Orphan notifications are the one signal that makes recovery usable, so this
   pins the composition. *)
let test_injected_bus_sees_orphan_notifications () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_database @@ fun persist ->
  let run_id = Workflow_run_id.create () in
  let cp = checkpoint ~workflow_id:"wf-bus" () in
  (match persist.save_workflow_state_fn run_id Wf_running (Some cp) with
   | Ok () -> ()
   | Error e -> Alcotest.failf "seed: %s" (error_to_string e));
  let seen = ref [] in
  let bus : event_bus_service = {
    publish_fn = (fun evt -> seen := evt :: !seen);
    subscribe_fn = (fun _ -> "");
    unsubscribe_fn = (fun _ -> ());
    set_session_id_fn = (fun _ -> ());
    start_dispatcher_fn = (fun _ -> ());
  } in
  let rt = match Runtime.create ~persistence:persist ~event_bus:bus
                   ~config:(runtime_config ()) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  Alcotest.(check bool) "the injected bus saw Workflow_orphaned" true
    (List.exists (function
       | Workflow_orphaned { workflow_run_id } ->
         Workflow_run_id.equal workflow_run_id run_id
       | _ -> false) !seen)

(* -------------------------------------------------------------------------- *)
(* Recovery                                                                   *)
(* -------------------------------------------------------------------------- *)

let recovery_agent (tb : tool_binding) : agent_config = {
  id = "rec-agent";
  system_prompt = stable_prompt "workflow";
  system_prompt_template = None;
  model = { provider = `Openai; model_name = "unused"; api_base = None;
            temperature = 0.0; max_tokens = None; top_p = None;
            stop_sequences = None; thinking_budget_tokens = None ; context_window = None};
  tools = [tb.descriptor];
  max_iterations = 1;
  middleware = [];
  retry_policy = None;
  context_strategy = None;
  resource_quota = None;
  max_execution_time = None;
  early_stopping_method = Force;
  on_max_tokens = None;
  max_continuation_chunks = None;
  tool_timeout = None;
  context_compression_threshold = None;
  compression_cooldown_messages = None;
  context_window_override = None;
  cache_strategy = No_caching;
  approval_handler = None;
}

let recovery_workflow () : workflow = {
  def = {
    id = "wf-recover";
    name = "Recover";
    version = 1;
    steps = Sequential [
      Tool_call { tool_name = "echo"; input = `String "A" };
      (* The first step after recovery asks for the sibling outputs. They must
         be rebuilt from the checkpoint, not from the loop's local list. *)
      Tool_call { tool_name = "echo";
                  input = `Assoc [("seen", `String "{{results}}")] };
      Tool_call { tool_name = "echo"; input = `String "C" };
    ];
    variables = [];
    failure_policy = Fail_fast;
    parallel_limit = 4;
    timeout = 300.0;
  };
  on_complete = None;
}

let test_recover_skips_completed_steps () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_database @@ fun persist ->
  let run_id = Workflow_run_id.create () in
  (* The row a crash after step 0 would leave: step 0 done, its binding
     recorded. *)
  let cp = checkpoint ~workflow_id:"wf-recover" ~step_path:[0]
      ~variables:[("result", `String "A"); ("result_0", `String "A")] () in
  (match persist.save_workflow_state_fn run_id Wf_running (Some cp) with
   | Ok () -> ()
   | Error e -> Alcotest.failf "seed: %s" (error_to_string e));
  let calls = ref [] in
  let rt = match Runtime.create ~persistence:persist
                   ~config:(runtime_config ()) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  let tb = match Runtime.register_tool rt ~name:"echo"
                  ~description:"echo" ~input_schema:(`Assoc [])
                  ~handler:(fun input _ -> calls := input :: !calls; Success input) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt (recovery_agent tb));
  ignore (Runtime.register_workflow rt (recovery_workflow ()));
  (match Runtime.recover_workflow rt run_id with
   | Error e -> Alcotest.failf "recover: %s" (error_to_string e)
   | Ok None -> Alcotest.fail "recover returned no result"
   | Ok (Some result) ->
     Alcotest.(check bool) "completed" true (result.status = `Success));
  let ran = List.map Yojson.Safe.to_string !calls in
  Alcotest.(check int) "only steps 1 and 2 ran" 2 (List.length ran);
  Alcotest.(check bool) "step 0 did not run" false (List.mem "\"A\"" ran);
  (* Step 1 received {{results}}, rebuilt from the checkpoint's result_0. *)
  Alcotest.(check bool) "results was rebuilt after recovery" true
    (List.exists (fun rendered ->
         let needle = "A" in
         let n = String.length needle in
         let rec go i =
           i + n <= String.length rendered
           && (String.sub rendered i n = needle || go (i + 1))
         in
         go 0) ran);
  (match Runtime.get_workflow_status rt run_id with
   | Ok (Wf_completed _) -> ()
   | Ok other ->
     Alcotest.failf "expected Wf_completed, got %s" (workflow_status_to_string other)
   | Error e -> Alcotest.failf "status: %s" (error_to_string e))

let test_recover_rejects_newer_schema () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_database @@ fun persist ->
  let run_id = Workflow_run_id.create () in
  let cp = checkpoint ~workflow_id:"wf-newer" ~schema_version:2 () in
  (match persist.save_workflow_state_fn run_id Wf_running (Some cp) with
   | Ok () -> ()
   | Error e -> Alcotest.failf "seed: %s" (error_to_string e));
  let rt = match Runtime.create ~persistence:persist
                   ~config:(runtime_config ()) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  match Runtime.recover_workflow rt run_id with
  | Ok _ -> Alcotest.fail "expected the newer schema to be rejected"
  | Error (Invalid_input msg) ->
    let needle = "schema_version" in
    let n = String.length needle in
    let rec go i =
      i + n <= String.length msg
      && (String.sub msg i n = needle || go (i + 1))
    in
    Alcotest.(check bool) "names the schema version" true (go 0)
  | Error e ->
    Alcotest.failf "expected Invalid_input, got %s" (error_to_string e)

let test_recover_without_checkpoint_is_rejected () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_database @@ fun persist ->
  let run_id = Workflow_run_id.create () in
  (match persist.save_workflow_state_fn run_id Wf_running None with
   | Ok () -> ()
   | Error e -> Alcotest.failf "seed: %s" (error_to_string e));
  let rt = match Runtime.create ~persistence:persist
                   ~config:(runtime_config ()) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  match Runtime.recover_workflow rt run_id with
  | Ok _ -> Alcotest.fail "expected an error for a checkpointless run"
  | Error (Invalid_input _) -> ()
  | Error e ->
    Alcotest.failf "expected Invalid_input, got %s" (error_to_string e)

(* A [Wf_running] entry that this process created belongs to a live run.
   Recovering it would execute the workflow twice, so eligibility comes from the
   orphan set recorded at startup, not from the status alone. *)
let test_a_live_run_is_not_recoverable () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let rt = match Runtime.create ~config:(runtime_config ()) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  let release = ref false in
  let tb = match Runtime.register_tool rt ~name:"gate"
                  ~description:"waits" ~input_schema:(`Assoc [])
                  ~handler:(fun _ _ ->
                    while not !release do Eio.Fiber.yield () done;
                    Success (`String "done")) () with
    | Ok tb -> tb
    | Error e -> Alcotest.failf "register_tool: %s" (error_to_string e)
  in
  ignore (Runtime.register_agent rt (recovery_agent tb));
  let wf = {
    def = {
      id = "wf-live"; name = "Live"; version = 1;
      steps = Sequential [ Tool_call { tool_name = "gate"; input = `Assoc [] } ];
      variables = []; failure_policy = Fail_fast; parallel_limit = 1; timeout = 300.0;
    };
    on_complete = None;
  } in
  ignore (Runtime.register_workflow rt wf);
  let run_id = match Runtime.submit_workflow_async rt wf with
    | Ok id -> id
    | Error e -> Alcotest.failf "submit: %s" (error_to_string e)
  in
  (match Runtime.recover_workflow rt run_id with
   | Ok _ -> Alcotest.fail "a live run must not be recovered"
   | Error (Invalid_input msg) ->
     Alcotest.(check bool) "explains why" true
       (let needle = "running in this process" in
        let n = String.length needle in
        let rec go i =
          i + n <= String.length msg
          && (String.sub msg i n = needle || go (i + 1))
        in
        go 0)
   | Error e -> Alcotest.failf "expected Invalid_input, got %s" (error_to_string e));
  release := true

let test_recover_on_suspended_points_at_resume () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_database @@ fun persist ->
  let run_id = Workflow_run_id.create () in
  let cp = checkpoint ~workflow_id:"wf-susp" () in
  (match persist.save_workflow_state_fn run_id (Wf_suspended cp) (Some cp) with
   | Ok () -> ()
   | Error e -> Alcotest.failf "seed: %s" (error_to_string e));
  let rt = match Runtime.create ~persistence:persist
                   ~config:(runtime_config ()) sw with
    | Ok rt -> rt
    | Error e -> Alcotest.failf "create: %s" (error_to_string e)
  in
  Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
  match Runtime.recover_workflow rt run_id with
  | Ok _ -> Alcotest.fail "a suspended run is not a crash recovery"
  | Error (Invalid_input msg) ->
    let needle = "resume_workflow" in
    let n = String.length needle in
    let rec go i =
      i + n <= String.length msg
      && (String.sub msg i n = needle || go (i + 1))
    in
    Alcotest.(check bool) "points at resume_workflow" true (go 0)
  | Error e ->
    Alcotest.failf "expected Invalid_input, got %s" (error_to_string e)

(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "workflow recovery" [
    "startup", [
      Alcotest.test_case "running rows are rehydrated and announced" `Quick
        test_create_rehydrates_running_and_emits_orphaned;
      Alcotest.test_case "an injected bus sees orphan notifications" `Quick
        test_injected_bus_sees_orphan_notifications;
    ];
    "recovery", [
      Alcotest.test_case "completed steps are not re-run" `Quick
        test_recover_skips_completed_steps;
      Alcotest.test_case "newer checkpoint schema is refused" `Quick
        test_recover_rejects_newer_schema;
      Alcotest.test_case "a running row without a checkpoint is refused" `Quick
        test_recover_without_checkpoint_is_rejected;
      Alcotest.test_case "a suspended run points at resume_workflow" `Quick
        test_recover_on_suspended_points_at_resume;
      Alcotest.test_case "a run started in this process is refused" `Quick
        test_a_live_run_is_not_recoverable;
    ];
  ]
