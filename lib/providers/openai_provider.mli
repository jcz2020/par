open Types

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

val set_network : t -> [ `Generic] Eio.Net.ty Eio.Net.t -> unit

(** Parse a single OpenAI streaming chunk (one entry from the `data:` lines of
    the SSE stream). Returns the optional text delta, the list of tool-call
    chunks (start and/or delta), the optional finish reason, and the optional
    usage update. Exposed for unit testing; production callers go through
    [stream]. *)
val parse_stream_delta : Yojson.Safe.t ->
  (llm_response_chunk option * llm_response_chunk list *
   finish_reason option * usage_stats option)
