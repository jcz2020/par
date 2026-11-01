open Types

type t

val create : llm_provider_config -> (t, error_category) result

val complete :
  t -> model_config -> tool_descriptor list -> conversation ->
  (llm_response, error_category) result

val embed :
  t -> string list -> (float array list, error_category) result

val complete_structured :
  t -> model_config -> tool_descriptor list -> conversation -> Yojson.Safe.t ->
  (llm_response, error_category) result

val stream :
  t -> model_config -> tool_descriptor list -> conversation -> stream_config ->
  (llm_response_chunk -> unit) ->
  (stream_complete, error_category) result

val build_message_json : message -> Yojson.Safe.t

val build_request_body :
  model_config:model_config ->
  tools:tool_descriptor list ->
  conversation:conversation ->
  stream:bool ->
  ?response_schema:Yojson.Safe.t ->
  unit ->
  string
(** Serialise a request body. Exposed for unit testing: the thinking parameter
    and the temperature/top_p omission are wire-format contracts. *)

val parse_llm_response : Yojson.Safe.t -> (llm_response, error_category) result
(** Parse a Messages API response. Exposed for unit testing: thinking and
    redacted_thinking blocks must survive into [llm_response.reasoning]. *)

val check_thinking : model_config -> (unit, error_category) result
(** Anthropic's extended-thinking limits: the budget must be at least 1024 and
    smaller than max_tokens. Exposed so the rule is testable without a
    network. *)

val close : t -> unit

val set_network : t -> [ `Generic] Eio.Net.ty Eio.Net.t -> unit

(** Dispatch one Anthropic SSE event to the callback. The refs accumulate
    state across events: [usage] totals, [finish] reason, [chunks] count, and
    [current_tc_id] (id of the in-progress tool_use block, used as a fallback
    key when a later input_json_delta does not echo the id). Exposed for unit
    testing; production callers go through [stream]. *)
val process_stream_event :
  (string * string) ->
  (llm_response_chunk -> unit) ->
  usage_stats ref ->
  finish_reason ref ->
  int ref ->
  string ref ->
  unit

