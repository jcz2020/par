type t = {
  db : Sqlite3.db;
  mutex : Eio.Mutex.t;
  dimension : int;
  embedding : Memory_service.embedding_fn option;
}

val create :
  ?dimension:int ->
  ?embedding_fn:Memory_service.embedding_fn ->
  string ->
  (t, Memory_error.memory_error) result

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
  ?mode:Memory_service.search_mode ->
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

val make_service :
  ?dimension:int ->
  ?embedding_fn:Memory_service.embedding_fn ->
  string ->
  (Memory_service.memory_service, Memory_error.memory_error) result
