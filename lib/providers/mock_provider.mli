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
  scripted_response list ->
  llm_service * call_history
(** Create a mock LLM service and its shared call history.
    - [delay] — optional simulated latency in seconds
    - [usage] — usage stats included in every response (default: 10/20/30)
    - [model_name] — model string in responses (default: "mock-llm")
    - [responses] — scripted sequence; empty list yields a default Text "mock"
    Returns ([llm_service], [call_history]) for injection and assertion. *)
