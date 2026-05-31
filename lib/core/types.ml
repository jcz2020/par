(* P-A-R Core Types — implementation *)

(* -------------------------------------------------------------------------- *)
(* §2.1 Identifier types                                                     *)
(* -------------------------------------------------------------------------- *)

module Task_id = struct
  type t = string [@@deriving yojson]

  let create () =
    let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () in
    Uuidm.to_string uuid

  let to_string t = t

  let of_string s =
    match Uuidm.of_string s with
    | Some _ -> Ok s
    | None -> Result.Error (`Invalid_id s)

  let equal = String.equal

  let compare a b = String.compare a b

  let sexp_of_t s = Sexplib0.Sexp.Atom s
end

module Workflow_run_id = struct
  type t = string [@@deriving yojson]

  let create () =
    let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () in
    Uuidm.to_string uuid

  let to_string t = t
  let of_string s = s
  let equal = String.equal
end

module Session_id = struct
  type t = string [@@deriving yojson]

  let create () =
    let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () in
    Uuidm.to_string uuid

  let to_string t = t
  let equal = String.equal
end

(* -------------------------------------------------------------------------- *)
(* §2.2 Error categories and handler result                                  *)
(* -------------------------------------------------------------------------- *)

type error_category =
  | Timeout
  | Invalid_input of string
  | External_failure of string
  | Rate_limited
  | Permission_denied of string
  | Internal of string
[@@deriving yojson]

type handler_result =
  | Success of Yojson.Safe.t
  | Error of {
      category : error_category;
      message : string;
      retryable : bool;
      metadata : (string * Yojson.Safe.t) list;
    }
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §2.3 LLM response types                                                   *)
(* -------------------------------------------------------------------------- *)

type tool_call = {
  id : string;
  name : string;
  arguments : Yojson.Safe.t;
}
[@@deriving yojson]

type finish_reason =
  | Stop
  | Tool_calls
  | Max_tokens
  | Content_filter
[@@deriving yojson]

type usage_stats = {
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
}
[@@deriving yojson]

type llm_response = {
  text : string option;
  tool_calls : tool_call list option;
  finish_reason : finish_reason;
  usage : usage_stats;
  model : string;
}
[@@deriving yojson]

let llm_response_validate resp =
  match (resp.text, resp.tool_calls) with
  | None, None | None, Some [] -> Result.Error "llm_response must have text or tool_calls"
  | _ -> Ok ()

(* -------------------------------------------------------------------------- *)
(* §3.1 Conversation types (early — referenced by middleware_hook)            *)
(* -------------------------------------------------------------------------- *)

type message_role = System | User | Assistant | Tool
[@@deriving yojson]

type message = {
  role : message_role;
  content : string option;
  tool_calls : tool_call list option;
  tool_call_id : string option;
  name : string option;
}
[@@deriving yojson]

and conversation = {
  messages : message list;
  metadata : (string * Yojson.Safe.t) list;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §2.4 Agent configuration types                                            *)
(* -------------------------------------------------------------------------- *)

type model_config = {
  provider : [ `Openai | `Anthropic | `Ollama | `Custom of string ];
  model_name : string;
  api_base : string option;
  temperature : float;
  max_tokens : int option;
  top_p : float option;
  stop_sequences : string list option;
}
[@@deriving yojson]

type expression =
  | Literal of Yojson.Safe.t
  | Variable of string
  | Equals of expression * expression
  | Not_equals of expression * expression
  | Greater_than of expression * expression
  | Less_than of expression * expression
  | And of expression * expression
  | Or of expression * expression
  | Not of expression
  | Contains of expression * expression
  | Has_key of expression * string
  | Is_empty of expression
  | Matches of expression * string
[@@deriving yojson]

type tool_permission =
  | Allow
  | Confirm
  | Deny
  | Role_based of { allowed_roles : string list }
  | Condition_based of expression
[@@deriving yojson]

type cancellation_token = {
  switch : Eio.Switch.t;
  mutable cancelled : bool;
}

type tool_descriptor = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  permission : tool_permission;
  timeout : float option;
  concurrency_limit : int option;
}
[@@deriving yojson]

type tool_binding = {
  descriptor : tool_descriptor;
  handler : Yojson.Safe.t -> cancellation_token -> handler_result;
}

type middleware_hook = {
  name : string;
  on_before_llm : (conversation -> conversation option) option;
  on_after_llm : (llm_response -> llm_response option) option;
  on_before_tool : (tool_call -> tool_call option) option;
  on_after_tool : (tool_call * handler_result -> handler_result option) option;
  on_error : (error_category -> handler_result option) option;
}

type context_strategy =
  | Truncate_oldest of { keep_system : bool; min_messages : int }
  | Summarize of { max_tokens : int; summary_model : model_config option }
  | Sliding_window of { max_messages : int; max_tokens : int }
[@@deriving yojson]

type retryable_condition =
  | Timeout
  | Rate_limited
  | External_failure
  | Connection_error
  | Any_retryable
[@@deriving yojson]

type backoff_strategy =
  | Exponential of { base : float; max_delay : float }
  | Fixed of float
  | Linear of { increment : float; max_delay : float }
[@@deriving yojson]

type retry_policy = {
  max_attempts : int;
  initial_delay : float;
  backoff : backoff_strategy;
  retry_on : retryable_condition list;
  jitter : float option;
}
[@@deriving yojson]

type resource_quota = {
  max_concurrent_tasks : int;
  max_concurrent_tools_per_agent : int;
  max_tokens_per_turn : int option;
  max_total_tokens : int option;
}
[@@deriving yojson]

type agent_config = {
  id : string;
  system_prompt : string;
  model : model_config;
  tools : tool_descriptor list;
  max_iterations : int;
  middleware : middleware_hook list;
  retry_policy : retry_policy option;
  context_strategy : context_strategy option;
  resource_quota : resource_quota option;
}

(* -------------------------------------------------------------------------- *)
(* §2.6 Task state machine                                                    *)
(* -------------------------------------------------------------------------- *)

type task_status =
  | Pending
  | Scheduled
  | Running
  | Waiting_input
  | Suspended
  | Completed
  | Failed
  | Cancelled
[@@deriving yojson]

type task_type =
  | Agent_call
  | Tool_call
  | Human_approval
  | Workflow
[@@deriving yojson]

let valid_transitions : (task_status * task_status) list =
  [
    (Pending, Scheduled);
    (Pending, Cancelled);
    (Scheduled, Running);
    (Scheduled, Cancelled);
    (Running, Waiting_input);
    (Running, Suspended);
    (Running, Completed);
    (Running, Failed);
    (Running, Cancelled);
    (Waiting_input, Running);
    (Waiting_input, Completed);
    (Waiting_input, Failed);
    (Waiting_input, Cancelled);
    (Suspended, Scheduled);
    (Suspended, Running);
    (Suspended, Completed);
    (Suspended, Failed);
    (Suspended, Cancelled);
  ]

let status_to_string = function
  | Pending -> "Pending"
  | Scheduled -> "Scheduled"
  | Running -> "Running"
  | Waiting_input -> "Waiting_input"
  | Suspended -> "Suspended"
  | Completed -> "Completed"
  | Failed -> "Failed"
  | Cancelled -> "Cancelled"

let validate_transition from_status to_status =
  let is_terminal = function Completed | Failed | Cancelled -> true | _ -> false in
  if from_status = to_status then
    Result.Error (Printf.sprintf "Self-transition not allowed: %s" (status_to_string from_status))
  else if is_terminal from_status then
    Result.Error (Printf.sprintf "Terminal state cannot transition: %s" (status_to_string from_status))
  else if List.mem (from_status, to_status) valid_transitions then
    Ok ()
  else
    Result.Error
      (Printf.sprintf "Invalid transition: %s -> %s"
         (status_to_string from_status)
         (status_to_string to_status))

(* -------------------------------------------------------------------------- *)
(* §2.9 Task types                                                            *)
(* -------------------------------------------------------------------------- *)

type task_input =
  | Agent_input of { agent_id : string; message : string }
  | Tool_input of { tool_name : string; arguments : Yojson.Safe.t }
  | Approval_input of { prompt : string; timeout : float; allowed_roles : string list }
  | Workflow_input of { workflow_id : string; variables : (string * Yojson.Safe.t) list }
[@@deriving yojson]

type task_state = {
  id : Task_id.t;
  input : task_input;
  status : task_status;
  parent_id : Task_id.t option;
  workflow_run_id : Workflow_run_id.t option;
  priority : int;
  schedule : [ `At of float | `Delay of float ] option;
  timeout : float;
  retry_policy : retry_policy option;
  retry_count : int;
  dependencies : Task_id.t list;
  depend_mode : [ `All_success | `Any_success | `All_complete ];
  created_at : float;
  updated_at : float;
  output : Yojson.Safe.t option;
  error : error_category option;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §6.1 Event types                                                           *)
(* -------------------------------------------------------------------------- *)

type event_metadata = {
  trace_id : string option;
  span_id : string option;
  timestamp : float;
  source : string;
}
[@@deriving yojson]

type event =
  | Task_created of { task_id : Task_id.t; task_type : string; priority : int }
  | Task_started of { task_id : Task_id.t }
  | Task_completed of { task_id : Task_id.t; duration_ms : float }
  | Task_failed of { task_id : Task_id.t; error : error_category }
  | Task_cancelled of { task_id : Task_id.t; reason : string }
  | Task_suspended of { task_id : Task_id.t }
  | Task_resumed of { task_id : Task_id.t }
  | Llm_request_sent of { task_id : Task_id.t; model : string }
  | Llm_response_received of { task_id : Task_id.t; usage : usage_stats }
  | Tool_invoked of { task_id : Task_id.t; tool_name : string }
  | Tool_completed of { task_id : Task_id.t; tool_name : string; duration_ms : float }
  | Tool_failed of { task_id : Task_id.t; tool_name : string; error : error_category }
  | Workflow_started of { workflow_run_id : Workflow_run_id.t }
  | Workflow_step_completed of { step_id : string }
  | Workflow_completed of { workflow_run_id : Workflow_run_id.t }
  | Workflow_failed of { workflow_run_id : Workflow_run_id.t; error : error_category }
  | Approval_requested of { prompt : string; allowed_roles : string list }
  | Approval_granted of { approver : string }
  | Approval_timeout
  | Shutdown_initiated
  | Shutdown_completed of { exit_code : int }
[@@deriving yojson]

type event_envelope = {
  id : string;
  metadata : event_metadata;
  payload : event;
  idempotency_key : string;
  delivery_attempt : int;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §6.2 Event bus config                                                      *)
(* -------------------------------------------------------------------------- *)

type event_delivery_config = {
  max_delivery_attempts : int;
  initial_retry_delay : float;
  retry_backoff : backoff_strategy;
  delivery_timeout : float;
}
[@@deriving yojson]

type dead_letter_entry = {
  envelope : event_envelope;
  error : string;
  failure_reason : error_category;
  failed_at : float;
  attempt_count : int;
}
[@@deriving yojson]

type event_bus_config = {
  buffer_capacity : int;
  delivery : event_delivery_config;
  dlq_enabled : bool;
  critical_event_types : string list;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §8.1 LLM Provider types                                                    *)
(* -------------------------------------------------------------------------- *)

type llm_provider_config =
  | Openai of { api_key : string; base_url : string option; organization : string option }
  | Anthropic of { api_key : string; base_url : string option }
  | Ollama of { base_url : string }
  | Custom of {
      base_url : string;
      headers : (string * string) list;
      request_format : [ `Openai_compatible | `Anthropic_compatible ];
    }
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §8.2 Streaming types                                                       *)
(* -------------------------------------------------------------------------- *)

type llm_response_chunk =
  | Text_delta of { text : string }
  | Tool_call_start of { tool_call_id : string; name : string }
  | Tool_call_delta of { tool_call_id : string; args_json : string }
  | Usage_update of usage_stats
  | Done of { finish_reason : finish_reason }
[@@deriving yojson]

type stream_config = {
  chunk_timeout : float;
  total_timeout : float option;
  buffer_size : int;
}
[@@deriving yojson]

type stream_complete = {
  final_usage : usage_stats;
  finish_reason : finish_reason;
  chunks_received : int;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §5 Shutdown config                                                         *)
(* -------------------------------------------------------------------------- *)

type shutdown_config = {
  drain_timeout : float;
  cancel_grace_period : float;
  flush_batch_size : int;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §9.0 Expression evaluator limits                                           *)
(* -------------------------------------------------------------------------- *)

type eval_limits = {
  max_depth : int;
  max_node_visits : int;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §9.1 Runtime config                                                        *)
(* -------------------------------------------------------------------------- *)

type runtime_config = {
  persistence : [ `Sqlite of string | `Postgresql of string ];
  event_bus : event_bus_config;
  default_quota : resource_quota;
  shutdown : shutdown_config;
  llm_providers : (string * llm_provider_config) list;
  eval_limits : eval_limits;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §2.8 Service registry (module types)                                       *)
(* -------------------------------------------------------------------------- *)

module type PERSISTENCE_SERVICE = sig
  type t

  val save_events :
    t -> event list -> (unit, error_category) result

  val load_events :
    t -> Task_id.t -> (event list, error_category) result

  val save_task_state :
    t -> task_state -> (unit, error_category) result

  val load_task_state :
    t -> Task_id.t -> (task_state option, error_category) result

  val transaction :
    t -> (t -> 'a) -> ('a, error_category) result
end

module type LLM_SERVICE = sig
  type t

  val create : llm_provider_config -> (t, error_category) result

  val complete :
    t -> model_config -> tool_descriptor list -> conversation ->
    (llm_response, error_category) result

  val stream :
    t -> model_config -> tool_descriptor list -> conversation -> stream_config ->
    (llm_response_chunk -> unit) ->
    (stream_complete, error_category) result

  val close : t -> unit
end

module type EVENT_BUS_SERVICE = sig
  type t

  type subscription

  val publish : t -> event -> unit

  val subscribe : t -> (event -> unit) -> subscription

  val unsubscribe : t -> subscription -> unit
end

type llm_service = {
  complete_fn : model_config -> tool_descriptor list -> conversation -> (llm_response, error_category) result;
  stream_fn : model_config -> tool_descriptor list -> conversation -> stream_config ->
    (llm_response_chunk -> unit) ->
    (stream_complete, error_category) result;
  close_fn : unit -> unit;
}

(* -------------------------------------------------------------------------- *)
(* §4.3 Concurrent hashtbl                                                    *)
(* -------------------------------------------------------------------------- *)

type ('k, 'v) protected_hashtbl = {
  data : ('k, 'v) Hashtbl.t;
  mutex : Eio.Mutex.t;
}

let htbl_get tbl key =
  Eio.Mutex.use_ro tbl.mutex (fun () -> Hashtbl.find_opt tbl.data key)

let htbl_set tbl key value =
  Eio.Mutex.use_rw ~protect:false tbl.mutex (fun () -> Hashtbl.replace tbl.data key value)

let htbl_remove tbl key =
  Eio.Mutex.use_rw ~protect:false tbl.mutex (fun () -> Hashtbl.remove tbl.data key)

let htbl_iter tbl f =
  Eio.Mutex.use_ro tbl.mutex (fun () -> Hashtbl.iter f tbl.data)

(* -------------------------------------------------------------------------- *)
(* §10.1 Middleware stack                                                     *)
(* -------------------------------------------------------------------------- *)

type middleware_stack = middleware_hook list

let compose_middleware hooks = hooks

(* -------------------------------------------------------------------------- *)
(* §11.1 Workflow types                                                       *)
(* -------------------------------------------------------------------------- *)

type workflow_step =
  | Agent_call of { agent_id : string; prompt_template : string }
  | Tool_call of { tool_name : string; input : Yojson.Safe.t }
  | Parallel of workflow_step list
  | Sequential of workflow_step list
  | Conditional of {
      condition : expression;
      then_step : workflow_step;
      else_step : workflow_step option;
    }
  | Map_reduce of {
      over : string;
      step : workflow_step;
      reduce : [ `Collect_all | `First_success | `Majority ];
    }
  | Human_approval of {
      prompt_template : string;
      timeout : float;
      allowed_roles : string list;
    }
  | Sub_workflow of {
      workflow_id : string;
      variables : (string * Yojson.Safe.t) list;
    }
[@@deriving yojson]

type failure_policy =
  | Fail_fast
  | Continue_on_failure
  | Conditional of { on_failure : workflow_step }
[@@deriving yojson]

type workflow_result = {
  outputs : (string * Yojson.Safe.t) list;
  status : [ `Success | `Partial | `Failed ];
  elapsed : float;
  metadata : (string * string) list;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* §11.2 Workflow checkpoint and run tracking                                  *)
(* -------------------------------------------------------------------------- *)

type workflow_checkpoint = {
  step_path : int list;
  variables : (string * Yojson.Safe.t) list;
  step_results : Yojson.Safe.t list;
}
[@@deriving yojson]

type workflow_status =
  | Wf_pending
  | Wf_running
  | Wf_suspended of workflow_checkpoint
  | Wf_completed of workflow_result
  | Wf_failed of error_category
 [@@deriving yojson]

type workflow_run = {
  id : Workflow_run_id.t;
  workflow_id : string;
  status : workflow_status;
  checkpoint : workflow_checkpoint option;
  created_at : float;
  updated_at : float;
}
[@@deriving yojson]

type persistence_service = {
  save_events_fn : event list -> (unit, error_category) result;
  load_events_fn : Task_id.t -> (event list, error_category) result;
  save_task_state_fn : task_state -> (unit, error_category) result;
  load_task_state_fn : Task_id.t -> (task_state option, error_category) result;
  save_workflow_state_fn : Workflow_run_id.t -> workflow_status -> workflow_checkpoint option -> (unit, error_category) result;
  load_workflow_state_fn : Workflow_run_id.t -> (workflow_checkpoint option, error_category) result;
  close_fn : unit -> unit;
}

type service_registry = {
  persistence : persistence_service;
  llm : llm_service;
  event_bus : (module EVENT_BUS_SERVICE);
  config : runtime_config;
}

type task_completion = {
  task_id : Task_id.t;
  result : (Yojson.Safe.t, error_category) result;
  elapsed : float;
}

let task_completion_to_yojson tc =
  let result_json = match tc.result with
    | Ok v -> `Assoc [ ("Ok", v) ]
    | Error e -> `Assoc [ ("Error", error_category_to_yojson e) ]
  in
  `Assoc [
    ("task_id", Task_id.to_yojson tc.task_id);
    ("result", result_json);
    ("elapsed", `Float tc.elapsed);
  ]

let task_completion_of_yojson = function
  | `Assoc xs ->
    let get_task_id = match List.assoc_opt "task_id" xs with
      | None -> Result.Error "task_completion: missing task_id"
      | Some v -> (match Task_id.of_yojson v with
          | Ok t -> Ok t
          | Error _ -> Result.Error "task_completion: invalid task_id")
    in
    let get_elapsed = match List.assoc_opt "elapsed" xs with
      | Some (`Float f) -> Ok f
      | Some (`Int i) -> Ok (float_of_int i)
      | _ -> Result.Error "task_completion: invalid elapsed"
    in
    let get_result : (_, string) result = match List.assoc_opt "result" xs with
      | Some (`Assoc [ ("Ok", v) ]) -> Ok (Ok v)
      | Some (`Assoc [ ("Error", e) ]) ->
        (match error_category_of_yojson e with
        | Ok ec -> Ok (Error ec)
        | Error _ -> Result.Error "task_completion: invalid error category")
      | _ -> Result.Error "task_completion: invalid result"
    in
    (match get_task_id, get_result, get_elapsed with
     | Ok task_id, Ok result, Ok elapsed ->
       Result.Ok { task_id; result; elapsed }
     | Error e, _, _ | _, Error e, _ | _, _, Error e -> Result.Error e)
  | _ -> Result.Error "task_completion: expected object"

type workflow = {
  id : string;
  name : string;
  version : int;
  steps : workflow_step;
  variables : (string * Yojson.Safe.t) list;
  failure_policy : failure_policy;
  parallel_limit : int;
  timeout : float;
  on_complete : (workflow_result -> unit) option;
}
