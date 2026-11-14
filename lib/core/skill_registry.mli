type activate_fn = unit -> Types.skill_effect

type t

val create : unit -> t

val register :
  t -> Types.skill_binding ->
  (unit, [ `Duplicate_skill of string ]) result

val replace : t -> string -> activate_fn -> unit
(** Replace an existing activate_fn by skill id. *)

val replace_binding :
  t -> Types.skill_binding ->
  (unit, [ `Not_found of string ]) result
(** Replace the whole binding (descriptor and activate_fn) for an existing
    skill id. Unlike {!replace}, a rewritten descriptor's frontmatter (prompt
    override, tool filter, trigger) takes effect too. *)

val resolve : t -> string -> activate_fn option

val find_descriptor :
  Types.skill_descriptor list -> string -> Types.skill_descriptor option

val remove : t -> string -> (unit, [ `Not_found of string ]) result

val list : t -> string list

val list_descriptors : t -> Types.skill_descriptor list
(** Return all skill descriptors sorted by id. *)
