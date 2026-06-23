type activate_fn = Types.runtime -> Types.skill_effect

type t

val create : unit -> t

val register :
  t -> Types.skill_binding ->
  (unit, [ `Duplicate_skill of string ]) result

val replace : t -> string -> activate_fn -> unit
(** Replace an existing activate_fn by skill id. *)

val resolve : t -> string -> activate_fn option

val find_descriptor :
  Types.skill_descriptor list -> string -> Types.skill_descriptor option

val remove : t -> string -> (unit, [ `Not_found of string ]) result

val list : t -> string list

val list_descriptors : t -> Types.skill_descriptor list
(** Return all skill descriptors sorted by id. *)
