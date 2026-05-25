open Types

type subscription = string

type t

val create : event_bus_config -> t

val publish : t -> event -> unit Eio.Fiber.t

val subscribe : t -> (event -> unit Eio.Fiber.t) -> subscription

val unsubscribe : t -> subscription -> unit

val start_dispatcher : t -> Eio.Switch.t -> unit

val get_dead_letters : t -> dead_letter_entry list
