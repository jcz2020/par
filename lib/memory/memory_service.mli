(** Lightweight embedding function type.
    Callers wrap [Types.embedding_service.embed_fn] into this form. *)
type embedding_fn = string list -> (float array list, string) result

(** Search mode for memory retrieval. *)
type search_mode =
  | Keyword_only  (** FTS5 keyword search only *)
  | Vector_only   (** Embedding vector KNN search only *)
  | Hybrid        (** Keyword + vector with RRF fusion *)
  | Auto          (** Smart default: Hybrid if embedding available, else Keyword_only *)

module type MEMORY_SERVICE = sig
  type t

  val create : string -> (t, Memory_error.memory_error) result

  val add :
    t ->
    content:string ->
    ?summary:string ->
    ?scope:string ->
    ?metadata:(string * Yojson.Safe.t) list ->
    ?categories:string list ->
    ?source:string ->
    unit ->
    (Memory_object.memory_object, Memory_error.memory_error) result

  val search :
    t ->
    ?mode:search_mode ->
    ?scope:string ->
    ?limit:int ->
    string ->
    (Memory_object.memory_object list, Memory_error.memory_error) result

  val update :
    t ->
    Memory_object.memory_object ->
    (Memory_object.memory_object, Memory_error.memory_error) result

  val delete :
    t ->
    string ->
    (unit, Memory_error.memory_error) result

  val list_all :
    t ->
    ?scope:string ->
    ?limit:int ->
    unit ->
    (Memory_object.memory_object list, Memory_error.memory_error) result

  val close : t -> unit

  val render_index :
    t ->
    ?max_entries:int ->
    ?scope:string ->
    unit ->
    string
end

type memory_service = {
  add_fn :
    content:string ->
    ?summary:string ->
    ?scope:string ->
    ?metadata:(string * Yojson.Safe.t) list ->
    ?categories:string list ->
    ?source:string ->
    unit ->
    (Memory_object.memory_object, Memory_error.memory_error) result;
  search_fn :
    ?mode:search_mode ->
    ?scope:string ->
    ?limit:int ->
    string ->
    (Memory_object.memory_object list, Memory_error.memory_error) result;
  update_fn :
    Memory_object.memory_object ->
    (Memory_object.memory_object, Memory_error.memory_error) result;
  delete_fn :
    string ->
    (unit, Memory_error.memory_error) result;
  list_all_fn :
    ?scope:string ->
    ?limit:int ->
    unit ->
    (Memory_object.memory_object list, Memory_error.memory_error) result;
  close_fn : unit -> unit;
  render_index_fn :
    ?max_entries:int ->
    ?scope:string ->
    unit ->
    string;
}
