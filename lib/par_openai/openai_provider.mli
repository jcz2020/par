open Types

type t

val create : llm_provider_config -> (t, error_category) result

val complete :
  t -> model_config -> conversation ->
  (llm_response, error_category) result Eio.Fiber.t

val stream :
  t -> model_config -> conversation -> stream_config ->
  (llm_response_chunk -> unit Eio.Fiber.t) ->
  (stream_complete, error_category) result Eio.Fiber.t

val close : t -> unit Eio.Fiber.t

val set_network : t -> Eio.Net.t -> unit
