type memory_object = {
  id : string;
  content : string;
  summary : string option;
  scope : string option;
  metadata : (string * Yojson.Safe.t) list;
  categories : string list;
  created_at : float;
  updated_at : float;
  source : string;
}

val to_yojson : memory_object -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (memory_object, string) result
