(* P-A-R Core Types — DESIGN.md v1.1 
   All types use [@@deriving yojson] for serialization.
   Only depends on: base, yojson, eio. *)

(* -------------------------------------------------------------------------- *)
(* Identifier types                                                     *)
(* -------------------------------------------------------------------------- *)

module Task_id : sig
  type t [@@deriving yojson]

  val create : unit -> t
  val to_string : t -> string
  val of_string : string -> (t, [> `Invalid_id of string ]) result
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val sexp_of_t : t -> Sexplib0.Sexp.t
end

module Workflow_run_id : sig
  type t [@@deriving yojson]

  val create : unit -> t
  val to_string : t -> string
  val of_string : string -> t
  val equal : t -> t -> bool
end

module Session_id : sig
  type t [@@deriving yojson]

  val create : unit -> t
  val to_string : t -> string
  val equal : t -> t -> bool
end

(* -------------------------------------------------------------------------- *)
(* Error categories and handler result                                  *)
(* -------------------------------------------------------------------------- *)

type error_category =
  | Timeout
  | Invalid_input of string
  | External_failure of string
  | Rate_limited
  | Permission_denied of string
  | Internal of string
  | Embedding_unsupported
[@@deriving yojson]

type handler_result =
  | Success of Yojson.Safe.t
  | Error of {
      category : error_category;
      message : string;
      retryable : bool;
      metadata : (string * Yojson.Safe.t) list;
    }
  | Handoff of {
      target_agent_id : string;
      carry_context : bool;
      task : string option;
    }
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* LLM response types                                                   *)
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

val llm_response_validate : llm_response -> (unit, string) result

(* -------------------------------------------------------------------------- *)
(* Conversation types (early — referenced by middleware_hook)            *)
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

type invoke_result = {
  response : llm_response;
  conversation : conversation;
}

type structured_invoke_result = {
  value        : Yojson.Safe.t;   (* schema-validated JSON returned by LLM *)
  raw_response : llm_response;    (* original LLM reply (debugging / token accounting) *)
  conversation : conversation;    (* updated, includes any repair messages *)
  attempts     : int;             (* 1 = happy path; >1 = repairs happened *)
}

(* -------------------------------------------------------------------------- *)
(* Agent configuration types                                            *)
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

(* Forward declaration — expression defined in *)
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
  output_schema : Yojson.Safe.t option;
  permission : tool_permission;
  timeout : float option;
  concurrency_limit : int option;
  on_update : (string -> unit) option;
}

type tool_binding = {
  descriptor : tool_descriptor;
  handler : Yojson.Safe.t -> cancellation_token -> handler_result;
}
(* Note: handler is a function type, not derivable *)

(* Forward declaration: the concrete `runtime` record is defined in
   lib/core/runtime.ml (which depends on this module). For A.1 we
   declare it as an abstract type so skill_binding.activate can be
   typed without modifying runtime.ml. A.3a (Wave 2) will properly
   link this with runtime.ml's `type runtime`. *)
type runtime

(** Skill system — typed abstraction over reusable instruction bundles.
    Mirrors [tool_descriptor] pattern. Revised 2026-06-24 after Oracle
    architectural review (see docs/v0.5.2-ROADMAP.md A.0 revision log). *)
type tool_filter =
  | All_tools
  | Only of string list       (** allowlist *)
  | Except of string list     (** denylist *)

type skill_trigger =
  | Auto                                                (** always load desc; LLM judges *)
  | Manual                                              (** never auto-load; explicit invoke only *)
  | Keyword of { keywords : string list;
                 llm_confirm : bool }                   (** [false] = deterministic activate-on-match;
                                                           [true] = filter then LLM judges (2-stage) *)

(** Effect returned by skill activation. Runtime applies per-invoke, discards after.
    Pure: reads runtime state, returns overlay. Does NOT mutate runtime directly.

    Composition rule (INTERSECTION): when multiple skills activate simultaneously,
    effective filter = intersection of all [Only] filters
                      ∪ (universe − union of all [Except] filters).
    [All_tools] is identity element. Fails safe (most restrictive wins). *)
type skill_effect = {
  system_prompt_override : string option;
  tool_filter_overlay    : tool_filter;
}

type skill_descriptor = {
  schema_version : int;                              (** required frontmatter field: 1 for v0.5.2.
                                                        Loader rejects unknown versions with clear
                                                        error pointing to MIGRATION.md. *)
  id : string;                                       (** lowercase-hyphen, matches dir name *)
  name : string;                                     (** display name *)
  description : string;                              (** ≤1024 chars; L1 metadata always resident *)
  system_prompt_override : string option;            (** OpenAI instructions pattern *)
  tool_filter : tool_filter;                         (** typed — better than all 5 competitors *)
  trigger : skill_trigger;                           (** ADT, not bool flags *)
  expected_output : Yojson.Safe.t option;            (** STOLEN FROM CREWAI — typed success criteria.
                                                        Forward-looking: informational-only in v0.5.2
                                                        (no LLM judge consumer yet); v0.5.3+ will add
                                                        judge that reads this field. STRATEGY §3
                                                        differentiation: only framework with typed
                                                        success criteria. *)
  body_path : string;                                (** L2 lazy-loaded content (markdown body) *)
}

type skill_binding = {
  descriptor : skill_descriptor;
  activate   : runtime -> skill_effect               (** pure: reads runtime, returns overlay *)
}

type middleware_hook = {
  name : string;
  on_before_llm : (conversation -> conversation option) option;
  on_after_llm : (llm_response -> llm_response option) option;
  on_before_tool : (tool_call -> tool_call option) option;
  on_after_tool : (tool_call * handler_result -> handler_result option) option;
  on_error : (error_category -> handler_result option) option;
}
(* Note: function fields, not derivable *)

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

type system_prompt_template = {
  template : string;
  variables : string list;
  required : string list;
}
[@@deriving yojson]

type early_stopping_method = Force | Generate

type agent_config = {
  id : string;
  system_prompt : string;
  system_prompt_template : system_prompt_template option;
  model : model_config;
  tools : tool_descriptor list;
  max_iterations : int;
  middleware : middleware_hook list;
  retry_policy : retry_policy option;
  context_strategy : context_strategy option;
  resource_quota : resource_quota option;
  max_execution_time : float option;
  early_stopping_method : early_stopping_method;
}

(* -------------------------------------------------------------------------- *)
(* Task state machine                                                    *)
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

val validate_transition : task_status -> task_status -> (unit, string) result

val status_to_string : task_status -> string

val valid_transitions : (task_status * task_status) list

(* -------------------------------------------------------------------------- *)
(* Task types                                                            *)
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
(* Event types                                                           *)
(* -------------------------------------------------------------------------- *)

type event_metadata = {
  trace_id : string option;
  span_id : string option;
  timestamp : float;
  source : string;
  session_id : string;
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
  | Tool_completed of { task_id : Task_id.t; tool_name : string; duration_ms : float; result_preview : string option }
  | Tool_failed of { task_id : Task_id.t; tool_name : string; error : error_category }
  | Tool_progress of { task_id : Task_id.t; tool_name : string; message : string }
  | Bash_invoked of {
      task_id : Task_id.t;
      tool_name : string;
      argv : string list;
      cwd : string;
      timeout : float;
      risk : string;
      started_at : float;
    }
  | Bash_completed of {
      task_id : Task_id.t;
      tool_name : string;
      argv : string list;
      exit_code : int;
      duration : float;
      stdout_truncated : bool;
      stderr_truncated : bool;
    }
  | Workflow_started of { workflow_run_id : Workflow_run_id.t }
  | Workflow_step_completed of { step_id : string }
  | Workflow_completed of { workflow_run_id : Workflow_run_id.t }
  | Workflow_failed of { workflow_run_id : Workflow_run_id.t; error : error_category }
  | Approval_requested of { prompt : string; allowed_roles : string list }
  | Approval_granted of { approver : string }
  | Approval_timeout
  | Shutdown_initiated
  | Shutdown_completed of { exit_code : int }
  (* MCP server lifecycle events *)
  | Mcp_server_started of { server_id : string; server_name : string }
  | Mcp_server_failed of { server_id : string; error : error_category }
  | Mcp_server_stopped of { server_id : string }
  | Mcp_tool_invoked of { server_id : string; tool_name : string }
  | Mcp_tool_completed of { server_id : string; tool_name : string; duration_ms : float }
  | Mcp_resource_read of { server_id : string; uri : string }
  | Mcp_prompt_rendered of { server_id : string; prompt_name : string }
  | Agent_handoff of { from_agent : string; to_agent : string; task_id : Task_id.t }
  | Structured_output_completed of {
      attempts : int;
      schema_valid : bool;
      task_id : Task_id.t;
    }
  | Embedding_request_sent of { model : string; input_count : int }
  | Embedding_response_received of { model : string; output_count : int; duration_ms : float }
  | Retrieval_completed of { query_count : int; retrieved_count : int; top_k : int }
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
(* Event bus config                                                      *)
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
  dlq_max_size : int;
  critical_event_types : string list;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* LLM Provider types                                                    *)
(* -------------------------------------------------------------------------- *)

type llm_provider_config =
  | Openai of { api_key : string; base_url : string option; organization : string option; embedding_model : string option }
  | Anthropic of { api_key : string; base_url : string option }
  | Ollama of { base_url : string }
  | Custom of {
      base_url : string;
      headers : (string * string) list;
      request_format : [ `Openai_compatible | `Anthropic_compatible ];
    }
[@@deriving yojson]

(* Provider registry + fallback policy (T0.5 stubs — semantics filled in by
   Wave 3/T6a and Wave 4/T6c). Declared now to avoid later patch conflicts. *)
type provider_config = {
  id : string;
  provider : llm_provider_config;
  is_default : bool option;
  extras : (string * Yojson.Safe.t) list;
}
[@@deriving yojson]

type fallback_policy =
  | No_fallback
  | Ordered of string list
  | Tagged of { primary : string; backup : string }
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* Streaming types                                                       *)
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
(* Shutdown config                                                         *)
(* -------------------------------------------------------------------------- *)

type shutdown_config = {
  drain_timeout : float;
  cancel_grace_period : float;
  flush_batch_size : int;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* Expression evaluator limits                                           *)
(* -------------------------------------------------------------------------- *)

type eval_limits = {
  max_depth : int;
  max_node_visits : int;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* Bash confirmation policy                                              *)
(* -------------------------------------------------------------------------- *)

type bash_confirm_policy = [
  | `Always
  | `Never
  | `Pattern
]
[@@deriving yojson]

type bash_confirm_config = {
  default_policy : bash_confirm_policy;
  patterns : (string * bash_confirm_policy) list;
}
[@@deriving yojson]

val default_bash_confirm_config : bash_confirm_config

(* -------------------------------------------------------------------------- *)
(* Runtime config                                                        *)
(* -------------------------------------------------------------------------- *)

type runtime_config = {
  persistence : [ `Sqlite of string | `Postgresql of string ];
  event_bus : event_bus_config;
  default_quota : resource_quota;
  shutdown : shutdown_config;
  llm_providers : (string * llm_provider_config) list;
  eval_limits : eval_limits;
  parallel_tool_execution : bool;
  bash_confirm : bash_confirm_config;
  event_retention_seconds : float;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* Service registry (module types)                                       *)
(* -------------------------------------------------------------------------- *)

module type PERSISTENCE_SERVICE = sig
  type t

  val save_events :
    t -> event_envelope list -> (unit, error_category) result

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

module type EMBEDDING_SERVICE = sig
  type t

  val create : llm_provider_config -> (t, error_category) result

  val embed : t -> string list -> (float array list, error_category) result

  val close : t -> unit
end

type event_subscription = string

type event_bus_service = {
  publish_fn : event -> unit;
  subscribe_fn : (event_envelope -> unit) -> event_subscription;
  unsubscribe_fn : event_subscription -> unit;
  set_session_id_fn : string -> unit;
  start_dispatcher_fn : Eio.Switch.t -> unit;
}

type session_summary = {
  session_id : string;
  event_count : int;
  first_event_at : float;
  last_event_at : float;
}
[@@deriving yojson]

type llm_service = {
  complete_fn : model_config -> tool_descriptor list -> conversation -> (llm_response, error_category) result;
  stream_fn : model_config -> tool_descriptor list -> conversation -> stream_config ->
    (llm_response_chunk -> unit) ->
    (stream_complete, error_category) result;
  close_fn : unit -> unit;
  complete_structured_fn :
    (model_config -> tool_descriptor list -> conversation ->
     Yojson.Safe.t ->
     (llm_response, error_category) result) option;
  list_models_fn : (unit -> (string list, error_category) result) option;
}

type embedding_service = {
  embed_fn : string list -> (float array list, error_category) result;
  close_fn : unit -> unit;
}

(* Forward declarations for persistence_service (full definitions in ) *)
type workflow_result = {
  outputs : (string * Yojson.Safe.t) list;
  status : [ `Success | `Partial | `Failed ];
  elapsed : float;
  metadata : (string * string) list;
}
[@@deriving yojson]

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

type persistence_service = {
  save_events_fn : event_envelope list -> (unit, error_category) result;
  load_events_fn : Task_id.t -> (event list, error_category) result;
  load_events_by_session_fn : string -> (event list, error_category) result;
  load_sessions_fn : int -> (session_summary list, error_category) result;
  save_task_state_fn : task_state -> (unit, error_category) result;
  load_task_state_fn : Task_id.t -> (task_state option, error_category) result;
  save_workflow_state_fn : Workflow_run_id.t -> workflow_status -> workflow_checkpoint option -> (unit, error_category) result;
  load_workflow_state_fn : Workflow_run_id.t -> (workflow_checkpoint option, error_category) result;
  save_conversation_fn : string -> conversation -> (unit, error_category) result;
  load_conversation_fn : string -> (conversation option, error_category) result;
  load_most_recent_conversation_fn : unit -> ((string * conversation) option, error_category) result;
  close_fn : unit -> unit;
}

type service_registry = {
  persistence : persistence_service;
  llm : llm_service;
  embeddings : embedding_service option;
  event_bus : event_bus_service;
  config : runtime_config;
}

(* -------------------------------------------------------------------------- *)
(* Concurrent hashtbl                                                    *)
(* -------------------------------------------------------------------------- *)

type ('k, 'v) protected_hashtbl = {
  data : ('k, 'v) Hashtbl.t;
  mutex : Eio.Mutex.t;
}

val htbl_get : ('k, 'v) protected_hashtbl -> 'k -> 'v option
val htbl_set : ('k, 'v) protected_hashtbl -> 'k -> 'v -> unit
val htbl_remove : ('k, 'v) protected_hashtbl -> 'k -> unit
val htbl_iter : ('k, 'v) protected_hashtbl -> ('k -> 'v -> unit) -> unit

(* -------------------------------------------------------------------------- *)
(* Middleware stack                                                     *)
(* -------------------------------------------------------------------------- *)

type middleware_stack

val compose_middleware : middleware_hook list -> middleware_stack

(* -------------------------------------------------------------------------- *)
(* Workflow types                                                       *)
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

type workflow_run = {
  id : Workflow_run_id.t;
  workflow_id : string;
  status : workflow_status;
  checkpoint : workflow_checkpoint option;
  created_at : float;
  updated_at : float;
}
[@@deriving yojson]

type task_completion = {
  task_id : Task_id.t;
  result : (Yojson.Safe.t, error_category) result;
  elapsed : float;
}

val task_completion_to_yojson : task_completion -> Yojson.Safe.t
val task_completion_of_yojson : Yojson.Safe.t -> (task_completion, string) result

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

type health_status = {
  runtime_alive : bool;
  last_llm_call_at : float option;
  last_llm_call_status : [ `Success | `Error of error_category | `Never_called ];
  persistence_ok : bool;
}
