open Types

type document = {
  id : string;
  content : string;
  metadata : Yojson.Safe.t option;
}

type search_result = {
  doc : document;
  score : float;
}

type t

val create :
  db_path:string ->
  vec_extension_path:string ->
  dimension:int ->
  unit ->
  (t, error_category) result

val add : t -> (document * float array) list -> (unit, error_category) result

val search :
  t -> query:float array -> k:int ->
  (search_result list, error_category) result

val delete : t -> ids:string list -> (unit, error_category) result

val close : t -> unit
