(** Hierarchical Navigable Small World graph for approximate nearest neighbor
    search. Pure OCaml implementation — no C extensions or external dependencies.

    Based on: Malkov & Yashunin, "Efficient and robust approximate nearest
    neighbor search using Hierarchical Navigable Small World graphs" (TPAMI 2020).

    @since 0.7.5 *)

type t

type distance_metric = [`Cosine | `L2]

val create :
  dimension:int ->
  ?m:int ->
  ?ef_construction:int ->
  ?ef_search:int ->
  ?distance_metric:distance_metric ->
  unit -> (t, Types.error_category) result

val insert : t -> id:string -> float array -> (unit, Types.error_category) result

val search : t -> query:float array -> k:int -> (string * float) list

val delete : t -> id:string -> (unit, Types.error_category) result

val size : t -> int

val save : t -> path:string -> (unit, Types.error_category) result

val load : path:string -> (t, Types.error_category) result

val close : t -> unit
