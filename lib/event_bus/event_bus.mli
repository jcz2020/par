open Types

type subscription = string

type t

val create : event_bus_config -> t

val publish : t -> event -> unit

val subscribe : t -> (event_envelope -> unit) -> subscription

val unsubscribe : t -> subscription -> unit

val start_dispatcher : t -> Eio.Switch.t -> unit

val get_dead_letters : t -> dead_letter_entry list

val dlq_entries : t -> event list

val push_to_dlq : t -> event_envelope -> string -> error_category -> unit

val to_service : t -> Types.event_bus_service

val set_session_id : t -> string -> unit
