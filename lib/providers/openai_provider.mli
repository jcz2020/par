open Types

type t

val create : llm_provider_config -> (t, error_category) result

val complete :
  t -> model_config -> tool_descriptor list -> conversation ->
  (llm_response, error_category) result

val embed :
  t -> string list -> (float array list, error_category) result

(** Parse an OpenAI /embeddings response body. Exposed for unit testing. *)
val parse_embeddings_response : Yojson.Safe.t -> (float array list, error_category) result

val complete_structured :
  t -> model_config -> tool_descriptor list -> conversation ->
  Yojson.Safe.t ->
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

(** Normalize a JSON Schema for OpenAI strict mode. OpenAI strict mode silently
    forces: (1) `additionalProperties:false` on every object subschema,
    (2) all properties into the `required` array, (3) `const:X` → `enum:[X]`.
    This function applies the same transformations locally so the user can see
    what is being sent via the second return value (list of transformation
    descriptions). Returns `(normalized_schema, transformations)` where the
    list is empty when no changes were needed.

    Local to OpenAI — Anthropic strict mode does not rewrite schemas the same
    way. See Oracle D5 / v0.4.8 WU-3. *)
val normalize_for_openai_strict : Yojson.Safe.t -> Yojson.Safe.t * string list
