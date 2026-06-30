(* P-A-R Core Types — implementation *)

(* -------------------------------------------------------------------------- *)
(* Identifier types                                                     *)
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
  cached_tokens : int;
  cache_creation_input_tokens : int;
  cache_read_input_tokens : int;
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
(* Prompt caching + content block types (PAR-4lh, v0.6.4)                   *)
(* -------------------------------------------------------------------------- *)

(* cache_ttl: the canonical TTL type. Single definition in types.ml.
   Referenced by cache_strategy, content_block.cache_control,
   cache_breakpoint.ml, and event payloads. *)
type cache_ttl = [`Five_min | `One_hour]
[@@deriving yojson]

(* cache_control: typed breakpoint marker, mirrors Anthropic's
   CacheControlEphemeralParam. type_ is always `Ephemeral today;
   future-proofed as a variant for persistent cache modes. *)
type cache_control = {
  type_ : [`Ephemeral];
  ttl : cache_ttl option;
}
[@@deriving yojson]

(* image_source: where an image block's data lives. *)
type image_source =
  | Url of string
  | Base64 of string
[@@deriving yojson]

(* content_block: structured content, replacing the old
   message.content : string option. Each block is independently
   addressable for cache_control marking. *)
type content_block =
  | Text_block of {
      text : string;
      cache_control : cache_control option;
    }
  | Tool_use_block of {
      id : string;
      name : string;
      arguments : Yojson.Safe.t;
      cache_control : cache_control option;
    }
  | Tool_result_block of {
      tool_use_id : string;
      content : string;
      cache_control : cache_control option;
    }
  | Image_block of {
      source : image_source;
      media_type : string;
      data : string;
      cache_control : cache_control option;
    }
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* Conversation types (early — referenced by middleware_hook)            *)
(* -------------------------------------------------------------------------- *)

type message_role = System | User | Assistant | Tool
[@@deriving yojson]

type message = {
  role : message_role;
  content_blocks : content_block list;
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

(* Long-output generation result (plan §3.1.1). Returned by
   [Runtime.invoke_generate]. Distinct from [invoke_result] because the
   generate path does not run the ReAct loop, so the shape exposes
   continuation/token accounting instead of an iteration count. *)
type generate_result = {
  text          : string;
  finish_reason : finish_reason;
  continuations : int;
  total_tokens  : int option;
  session_id    : string;
  elapsed       : float;
}
[@@deriving yojson]

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
(* Intentionally no [@@deriving yojson]: the on_update function field
   cannot be serialised to JSON. The runtime/FFI paths use the in-memory
   representation; JSON is not used for tool_descriptor transport. *)


(* Tool-calling protocol mode (PAR-k38, T0.5 stub).
   - `Native:     the provider's wire protocol carries structured tool calls
                   (OpenAI functions / Anthropic tool_use). Preferred when
                   available — no parsing risk.
   - `Synthesized:the provider does not natively support tool calls, so the
                   runtime injects tool descriptors into the prompt and
                   parses synthesised JSON tool calls back out of the
                   model's text response (see lib/core/tool_prompt.ml).
                   Slower and slightly less reliable than `Native.
   - `Json_mode:  a forced structured-output mode — model returns raw JSON
                   only; runtime handles tool-call synthesis downstream.
                   Reserved for providers that emit JSON but no tool metadata.

   T3.1 wires this into model_config / llm_service. T0.5 only declares the
   shape so later tasks do not touch types.ml. *)
type tool_mode = [
  | `Native
  | `Synthesized
  | `Json_mode
  | `Auto  (* PAR-k38 capability detection: consult supports_native_tools_fn *)
]
[@@deriving yojson]

type tool_binding = {
  descriptor : tool_descriptor;
   handler : Yojson.Safe.t -> cancellation_token -> handler_result;
}

(* Skill system — typed abstraction over reusable instruction bundles.
   Mirrors tool_descriptor pattern. NO [@@deriving yojson] on the binding
   (function field), same as tool_binding.
   Revised 2026-06-24 after Oracle architectural review (see Revision Log
   in docs/v0.5.2-ROADMAP.md A.0). *)
type tool_filter =
  | All_tools
  | Only of string list       (* allowlist *)
  | Except of string list     (* denylist *)

type skill_trigger =
  | Auto                                                (* always load desc; LLM judges *)
  | Manual                                              (* never auto-load; explicit invoke only *)
  | Keyword of { keywords : string list;
                 llm_confirm : bool }                   (* false = deterministic activate-on-match;
                                                           true = filter then LLM judges (2-stage) *)

(* Effect returned by skill activation. Runtime applies per-invoke, discards after.
   Pure: reads runtime state, returns overlay. Does NOT mutate runtime directly. *)
type skill_effect = {
  system_prompt_override : string option;
  tool_filter_overlay    : tool_filter;
  (* Composition rule (INTERSECTION): when multiple skills activate simultaneously,
     effective filter = intersection of all `Only` filters
                       ∪ (universe − union of all `Except` filters).
     `All_tools` is identity element. Fails safe (most restrictive wins). *)
}

type skill_descriptor = {
  schema_version : int;                              (* required frontmatter field: 1 for v0.5.2.
                                                        Loader rejects unknown versions with clear
                                                        error pointing to MIGRATION.md. *)
  id : string;                                       (* lowercase-hyphen, matches dir name *)
  name : string;                                     (* display name *)
  description : string;                              (* ≤1024 chars; L1 metadata always resident *)
  system_prompt_override : string option;            (* OpenAI instructions pattern *)
  tool_filter : tool_filter;                         (* typed — better than all 5 competitors *)
  trigger : skill_trigger;                           (* ADT, not bool flags *)
  expected_output : Yojson.Safe.t option;            (* STOLEN FROM CREWAI — typed success criteria.
                                                        Forward-looking: informational-only in v0.5.2
                                                        (no LLM judge consumer yet); v0.5.3+ will add
                                                        judge that reads this field. STRATEGY §3
                                                        differentiation: only framework with typed
                                                        success criteria. *)
  body_path : string;                                (* L2 lazy-loaded content (markdown body) *)
}

type skill_binding = {
  descriptor : skill_descriptor;
  activate   : unit -> skill_effect
}

type middleware_hook = {
  name : string;
  on_before_llm : (conversation -> conversation option) option;
  on_after_llm : (llm_response -> llm_response option) option;
  on_before_tool : (tool_call -> tool_call option) option;
  on_after_tool : (tool_call * handler_result -> handler_result option) option;
  (* PAR-6ad (GH#16): [on_error] now receives the conversation so per-call
     state (e.g. retry attempt count) can be isolated across concurrent
     [Runtime.invoke] calls on the same agent. *)
  on_error : (conversation -> error_category -> handler_result option) option;
}

type context_strategy =
  | Truncate_oldest of { keep_system : bool; min_messages : int }
  | Summarize of { max_tokens : int; summary_model : model_config option }
  | Sliding_window of { max_messages : int; max_tokens : int }
[@@deriving yojson]

(* PAR-p70: Why the compression was skipped. Typed polymorphic variant so
   downstream consumers pattern-match instead of grepping string logs.
   - `Below_threshold f: ratio r did not reach the configured threshold.
     [f] is the current ratio (for telemetry / dashboards).
   - `Cooldown_active n: would compress but N more messages needed.
     [n] is messages remaining before cooldown expires.
   - `No_window_size: threshold set but no resolver could determine
     the context window size (tier-1 table miss + tier-2 capability
     unset + tier-3 override None).
   - `No_strategy: threshold set but agent.context_strategy = None
     AND no auto-default strategy available. *)
type context_compression_skip_reason =
  [ `Below_threshold of float
  | `Cooldown_active of int
  | `No_window_size
  | `No_strategy ]
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

type on_max_tokens_behavior = Retry | Continue | Return_partial

(* Long-output generation mode (plan §2.1.1).
   - [on_max_tokens = None] means Auto: the engine resolves the policy
     from effective tool set (tool-less -> Continue, otherwise Return_partial).
   - [on_max_tokens = Some p] is an explicit override.
   - [max_continuation_chunks = None] means Auto: unbounded for tool-less
     agents, 3 for tool-bearing. [Some n] is an explicit cap.
   This typed option approach replaces the previous non-option fields
   (breaking change in 0.x per SemVer §4). Sentinel values are forbidden
   by the type-safety red line. *)
type cache_strategy =
  | No_caching
  | With_cache_of of cache_ttl
[@@deriving yojson]

type zone_tag = Zone_stable | Zone_volatile
[@@deriving yojson]

type system_prompt = {
  sp_raw : string;
  sp_zone : zone_tag;
}
[@@deriving yojson]

let stable_prompt s : system_prompt = { sp_raw = s; sp_zone = Zone_stable }
let volatile_prompt s : system_prompt = { sp_raw = s; sp_zone = Zone_volatile }
let prompt_text (sp : system_prompt) = sp.sp_raw
let zone_of (sp : system_prompt) = sp.sp_zone

type agent_config = {
  id : string;
  system_prompt : system_prompt;
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
  on_max_tokens : on_max_tokens_behavior option;
  max_continuation_chunks : int option;
  (* PAR-19b: per-tool timeout enforced at the engine layer.
     When [Some seconds], each tool handler call is wrapped in
     Cancellation.with_timeout, so the timeout cannot be silently bypassed
     by middleware composition (GH#17 fix). The legacy
     [tool_descriptor.timeout] field is still respected by individual tool
     implementations that consult it; this field is the engine-level
     authoritative cutoff. *)
  tool_timeout : float option;
  (* PAR-p70: Auto context compression by window ratio.
     - [context_compression_threshold] When Some r (0.0–1.0), auto-fires
       compression when estimate_tokens(conv) / context_window ≥ r.
       Default Some 0.8 in make_agent. None = disabled (manual context_strategy only).
     - [compression_cooldown_messages] Min iterations between auto-compressions.
       Prevents LLM-summarize thrash. Default Some 6. None = no cooldown.
     - [context_window_override] User-supplied context window size (tier-3 resolver).
       None = fall through to llm.context_window_fn then static table. *)
  context_compression_threshold : float option;
  compression_cooldown_messages : int option;
  context_window_override : int option;
  cache_strategy : cache_strategy;
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
  | Provider_fallback_attempted of { from_provider : string; to_provider : string }
  | Llm_response_truncated of { task_id : Task_id.t; model : string; finish_reason : finish_reason }
  | Generate_continuation of { task_id : Task_id.t; chunk_index : int; chars_added : int }
  (* Fired by the long-output generate path ([Runtime.invoke_generate])
     after each successful Continue chunk so callers can track progress
     on long artifacts (PRDs / mockups / plans). [chunk_index] is 0-based
     for the continuation chunks (the initial response is not a continuation). *)
  | Context_compressed of {
      trigger : float;              (* threshold that fired *)
      tokens_before : int;
      tokens_after : int;
      messages_before : int;
      messages_after : int;
      strategy_used : context_strategy;
      elapsed_ms : int;
    }
   | Context_compression_skipped of {
       reason : context_compression_skip_reason;
     }
   | Cache_write of {
       tokens_written : int;
       ttl : cache_ttl;
     }
   | Cache_read of {
       tokens_read : int;
       total_prompt_tokens : int;
     }
   | Cache_strategy_skipped of {
       reason : cache_skip_reason;
     }
   | Cache_breakpoint_dropped of {
       location : breakpoint_location;
       reason : drop_reason;
     }
   | Cache_invalidated_by_skill of {
       skill_id : string;
       before_tool_count : int;
       after_tool_count : int;
       estimated_wasted_tokens : int;
     }
   [@@deriving yojson]

 and cache_skip_reason =
   [ `Volatile_system
   | `Volatile_builtins of string list
   | `Unsupported_provider
   | `No_strategy ]

 and breakpoint_location =
   [ `System | `Tool of int | `Message of int * int ]

 and drop_reason =
   | Over_budget
   | Unsupported_by_provider
   | Lower_priority_than_dropped

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
  | Openai of { api_key : string; base_url : string option; organization : string option; embedding_model : string option; prompt_cache_key : string option }
  | Anthropic of { api_key : string; base_url : string option }
  | Ollama of { base_url : string }
  | Custom of {
      base_url : string;
      headers : (string * string) list;
      request_format : [ `Openai_compatible | `Anthropic_compatible ];
    }
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* Provider registry + fallback policy (T0.5 stubs)                         *)
(*                                                                          *)
(* These are DECLARATIONS ONLY. Semantics filled in by:                     *)
(*   - provider_config -> Wave 3 / T6a A.1 (provider registry)              *)
(*   - fallback_policy -> Wave 4 / T6c A.3 (provider fallback)              *)
(* T0.5 just pre-populates so T6a/T6c do not need to edit this file.        *)
(* -------------------------------------------------------------------------- *)

(* Named entry in the provider registry. [is_default] is optional in JSON
   (option type so [@@deriving yojson] decodes a missing field as None);
   T6a A.1 will enforce the "exactly one default" invariant at registration
   time, not at the type level. *)
type provider_config = {
  id : string;
  provider : llm_provider_config;
  is_default : bool option;
  extras : (string * Yojson.Safe.t) list;
}
[@@deriving yojson]

(* Fallback ordering across providers. T6c A.3 will wire this into the LLM
   call path; T0.5 only declares the shape so later tasks do not touch types.ml. *)
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

let default_bash_confirm_config = {
  default_policy = `Always;
  patterns = [];
}

(* -------------------------------------------------------------------------- *)
(* Runtime config                                                        *)
(* -------------------------------------------------------------------------- *)

(* `_runtime_config_base` exists so we can reuse the auto-derived yojson
   codecs while still letting `bash_confirm` be optional on decode. *)
type _runtime_config_base = {
  persistence : [ `Sqlite of string ];
  event_bus : event_bus_config;
  default_quota : resource_quota;
  shutdown : shutdown_config;
  llm_providers : (string * llm_provider_config) list;
  eval_limits : eval_limits;
  parallel_tool_execution : bool;
}
[@@deriving yojson { strict = false }]

type runtime_config = {
  persistence : [ `Sqlite of string ];
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

(* Override the derived decoder so that `bash_confirm` is optional:
   configs that omit it (pre-T13, including the Python FFI and
   `~/.par/config.json`) decode successfully with the safe default. *)
let runtime_config_of_yojson (j : Yojson.Safe.t) :
    (runtime_config, string) result =
  let open Yojson.Safe.Util in
  let bash_confirm =
    match member "bash_confirm" j with
    | `Null -> default_bash_confirm_config
    | v ->
      (match bash_confirm_config_of_yojson v with
       | Ok cfg -> cfg
       | Error _ -> default_bash_confirm_config)
  in
  let event_retention_seconds =
    match member "event_retention_seconds" j with
    | `Float f -> f
    | `Int i -> float_of_int i
    | _ -> 604800.0
  in
  match _runtime_config_base_of_yojson j with
  | Ok base ->
    Ok {
      persistence = base.persistence;
      event_bus = base.event_bus;
      default_quota = base.default_quota;
      shutdown = base.shutdown;
      llm_providers = base.llm_providers;
      eval_limits = base.eval_limits;
      parallel_tool_execution = base.parallel_tool_execution;
      bash_confirm;
      event_retention_seconds;
    }
  | Error e -> Error e

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
  (* PAR-k38: provider capability declaration.
     When [Some true], the provider transports tool calls natively (OpenAI
     functions / Anthropic tool_use). When [Some false], the provider does
     NOT accept the [tools] request parameter — the engine must inject tool
     descriptors into the system prompt and parse synthesised tool calls
     out of the model's text response (see [Tool_prompt]). [None] is
     equivalent to [Some true] for backwards compatibility — every provider
     PAR ships with today sends native tools, so the safe default is
     "native". Future providers that don't support [tools] should set this
     to [Some false] at construction time. *)
  supports_native_tools_fn : (unit -> bool) option;
  (* PAR-p70: Provider-declared context window size for the current model.
     When Some f, called by Context_manager.resolve_context_window as tier-2
     resolver (tier-1 = static table, tier-3 = user override). None = unknown,
     fall through to static table. Mirrors the supports_native_tools_fn capability
     pattern. *)
  context_window_fn : (unit -> int) option;
  cache_control_fn : (unit -> cache_control_capability) option;
}

and cache_control_capability = {
  supported_ttls : cache_ttl list;
  max_breakpoints : int;
}

type embedding_service = {
  embed_fn : string list -> (float array list, error_category) result;
  close_fn : unit -> unit;
}

(* -------------------------------------------------------------------------- *)
(* Concurrent hashtbl                                                    *)
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
(* Middleware stack                                                     *)
(* -------------------------------------------------------------------------- *)

type middleware_stack = middleware_hook list

let compose_middleware hooks = hooks

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

type workflow_result = {
  outputs : (string * Yojson.Safe.t) list;
  status : [ `Success | `Partial | `Failed ];
  elapsed : float;
  metadata : (string * string) list;
}
[@@deriving yojson]

(* -------------------------------------------------------------------------- *)
(* Workflow checkpoint and run tracking                                  *)
(* -------------------------------------------------------------------------- *)

type workflow_checkpoint = {
  workflow_id : string;
  step_path : int list;
  variables : (string * Yojson.Safe.t) list;
  step_results : Yojson.Safe.t list;
  allowed_roles : string list option;
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
  save_events_fn : event_envelope list -> (unit, error_category) result;
  load_events_fn : Task_id.t -> (event list, error_category) result;
  load_events_by_session_fn : string -> (event list, error_category) result;
  load_sessions_fn : int -> (session_summary list, error_category) result;
  save_task_state_fn : task_state -> (unit, error_category) result;
  load_task_state_fn : Task_id.t -> (task_state option, error_category) result;
  save_workflow_state_fn : Workflow_run_id.t -> workflow_status -> workflow_checkpoint option -> (unit, error_category) result;
  load_workflow_state_fn : Workflow_run_id.t -> (workflow_checkpoint option, error_category) result;
  load_all_suspended_workflows_fn : unit -> ((Workflow_run_id.t * workflow_status) list, error_category) result;
  save_workflow_def_fn : string -> Yojson.Safe.t -> (unit, error_category) result;
  load_all_workflow_defs_fn : unit -> ((string * Yojson.Safe.t) list, error_category) result;
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

type workflow_def = {
  id : string;
  name : string;
  version : int;
  steps : workflow_step;
  variables : (string * Yojson.Safe.t) list;
  failure_policy : failure_policy;
  parallel_limit : int;
  timeout : float;
}
[@@deriving yojson]

type workflow = {
  def : workflow_def;
  on_complete : (workflow_result -> unit) option;
}

type health_status = {
  runtime_alive : bool;
  last_llm_call_at : float option;
  last_llm_call_status : [ `Success | `Error of error_category | `Never_called ];
  persistence_ok : bool;
} [@@deriving yojson]
