open Types

type call_record = {
  model : model_config;
  tools : tool_descriptor list;
  conversation : conversation;
  timestamp : float;
}

type call_history = {
  mutable complete_calls : call_record list;
  mutable stream_calls : call_record list;
  mutable close_calls : int;
}

type scripted_response =
  | Text of string
  | With_tool_calls of { text : string option; calls : tool_call list }
  | Error of error_category

val create_history : unit -> call_history
(** Create an empty call history (useful for pre-allocating). *)

val call_count : call_history -> int
(** Total number of complete + stream calls recorded. *)

val last_complete_call : call_history -> call_record option
(** Most recent complete call, if any. *)

val nth_complete_call : call_history -> int -> call_record option
(** Nth complete call (0-indexed from most recent). *)

val last_stream_call : call_history -> call_record option
(** Most recent stream call, if any. *)

val nth_stream_call : call_history -> int -> call_record option
(** Nth stream call (0-indexed from most recent). *)

val create :
  ?delay:float option ->
  ?usage:usage_stats ->
  ?model_name:string ->
  ?structured_response:Yojson.Safe.t ->
  scripted_response list ->
  llm_service * call_history
(** Create a mock LLM service and its shared call history.
    - [delay] — optional simulated latency in seconds
    - [usage] — usage stats included in every response (default: 10/20/30)
    - [model_name] — model string in responses (default: "mock-llm")
    - [structured_response] — when set, [complete_structured_fn] returns this
      JSON verbatim (wrapped as [llm_response.text]). When unset, the mock
      synthesizes a minimal valid object from the request schema's
      top-level [properties] (string→"", integer→0, etc.).
    - [responses] — scripted sequence; empty list yields a default Text "mock"
    Returns ([llm_service], [call_history]) for injection and assertion.

    The returned [llm_service.complete_structured_fn] is always [Some _],
    enabling deterministic structured-output testing without real LLM calls. *)

(** {1 Embedding Service Mock} *)

type embed_call_record = {
  inputs : string list;
  timestamp : float;
}

type embed_call_history = {
  mutable embed_calls : embed_call_record list;
}

val create_embed_history : unit -> embed_call_history

val embed_call_count : embed_call_history -> int

val last_embed_call : embed_call_history -> embed_call_record option

val nth_embed_call : embed_call_history -> int -> embed_call_record option

val mock_embed_service : unit -> embedding_service * embed_call_history
(** Create a mock embedding service that returns deterministic float arrays
    (hash-based) and records every call for assertion in tests. *)
