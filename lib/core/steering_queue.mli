type t

val create : ?capacity:int -> unit -> t

val enqueue : t -> string -> unit

val drain_all : t -> string list

val has_items : t -> bool

val count : t -> int

val close : t -> unit
