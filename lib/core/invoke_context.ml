open Types

type invoke_status = Running | Completed | Cancelled | Failed

type invoke_context = {
  session_id : string;
  metrics_accumulator : Metrics.counters;
  user_activated_skills_snapshot : string list;
  tool_call_hooks_snapshot : Hook.tool_call_hook list;
  steering_queue : Steering_queue.t;
  followup_queue : Steering_queue.t;
  system_prompt_appendix : string option;
}

let invoke_context_key : invoke_context Eio.Fiber.key =
  Eio.Fiber.create_key ()

let create
    ?(session_id = "unknown")
    ?(metrics = Metrics.empty ())
    ?(hooks = [])
    ?(skills = [])
    ?(steering = Steering_queue.create ())
    ?(followup = Steering_queue.create ())
    ?system_prompt_appendix
    () =
  {
    session_id;
    metrics_accumulator = metrics;
    user_activated_skills_snapshot = skills;
    tool_call_hooks_snapshot = hooks;
    steering_queue = steering;
    followup_queue = followup;
    system_prompt_appendix;
  }

let get_current () = Eio.Fiber.get invoke_context_key

(** [appendix_text ()] returns the system_prompt_appendix from the current
    invoke_context, prefixed with ["\\n\\n"] when present, or [""] when no
    context or no appendix is set. *)
let appendix_text () =
  match Eio.Fiber.get invoke_context_key with
  | Some { system_prompt_appendix = Some app; _ } -> "\n\n" ^ app
  | _ -> ""

let get_current_exn () =
  match Eio.Fiber.get invoke_context_key with
  | Some ctx -> ctx
  | None ->
    failwith
      "Invoke_context.get_current_exn: no invoke_context bound to this fiber"

let with_context ctx f = Eio.Fiber.with_binding invoke_context_key ctx f

type invoke_handle = {
  result_promise :
    (invoke_result, error_category * conversation) result Eio.Promise.or_exn;
  token : cancellation_token;
  status : invoke_status Atomic.t;
}

let invoke_handle_status h = Atomic.get h.status

let invoke_handle_token h = h.token

let invoke_handle_await h = Eio.Promise.await_exn h.result_promise

let invoke_handle_cancel h =
  Cancellation.request_cancel h.token;
  (* CAS loop: set to Cancelled only if not already Completed *)
  let rec try_set () =
    match Atomic.get h.status with
    | Completed -> ()  (* already done, don't override *)
    | current ->
      if not (Atomic.compare_and_set h.status current Cancelled) then
        try_set ()  (* retry if CAS failed *)
  in
  try_set ()

let appendix_metadata_key = "_par_system_prompt_appendix"

let empty_conversation = { messages = []; metadata = [] }

let fork_invoke
    ~sw
    ~token
    (f : unit -> (invoke_result, error_category * conversation) result) =
  let status = Atomic.make Running in
  let result_promise =
    Eio.Fiber.fork_promise ~sw (fun () ->
      try
        let r = f () in
        Atomic.set status Completed;
        r
      with
      | Eio.Cancel.Cancelled _ ->
        Atomic.set status Cancelled;
        Error (Timeout, empty_conversation)
      | exn ->
        Atomic.set status Failed;
        Error (Internal (Printexc.to_string exn), empty_conversation))
  in
  { result_promise; token; status }
