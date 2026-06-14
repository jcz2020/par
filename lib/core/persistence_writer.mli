open Types

type t

val create :
  ?capacity:int ->
  ?flush_interval:float ->
  ?overflow_fn:(event_envelope -> unit) ->
  (event_envelope list -> (unit, error_category) result) ->
  t

val push : t -> event_envelope -> unit

val start_drain_fiber : t -> Eio.Switch.t -> unit

val flush_sync : t -> unit
