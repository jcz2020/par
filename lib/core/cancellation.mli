open Types

type t = cancellation_token

val create_token : Eio.Switch.t -> cancellation_token

val is_cancelled : cancellation_token -> bool

val check_cancel : cancellation_token -> unit

val request_cancel : cancellation_token -> unit

val with_timeout :
  float ->
  cancellation_token ->
  (cancellation_token -> 'a) ->
  ('a, [> `Timeout | `Cancelled ]) result

val cancellable_handler :
  cancellation_token ->
  float ->
  (Yojson.Safe.t -> handler_result) ->
  (Yojson.Safe.t -> handler_result)
