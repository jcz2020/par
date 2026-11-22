open Types

exception Stream_cancelled_by_token

type t = cancellation_token

val create_token : Eio.Switch.t -> cancellation_token

val is_cancelled : cancellation_token -> bool

val check_cancel : cancellation_token -> unit

val request_cancel : cancellation_token -> cancel_reason -> unit

val register_cancel_hook :
  cancellation_token -> (unit -> unit) -> (unit -> unit)
(** Register a best-effort shutdown hook (e.g. socket shutdown) and return its
    unregister function. Hooks run inside [request_cancel]. *)

val reason : cancellation_token -> cancel_reason option

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
