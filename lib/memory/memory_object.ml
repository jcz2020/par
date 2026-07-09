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

let to_yojson (m : memory_object) : Yojson.Safe.t =
  `Assoc [
    ("id", `String m.id);
    ("content", `String m.content);
    ("summary", match m.summary with None -> `Null | Some s -> `String s);
    ("scope", match m.scope with None -> `Null | Some s -> `String s);
    ("metadata", `Assoc m.metadata);
    ("categories", `List (List.map (fun s -> `String s) m.categories));
    ("created_at", `Float m.created_at);
    ("updated_at", `Float m.updated_at);
    ("source", `String m.source);
  ]

let of_yojson (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let get k = List.assoc_opt k fields in
    let get_string k = match get k with Some (`String s) -> Some s | _ -> None in
    let get_float k = match get k with Some (`Float f) -> Some f | Some (`Int i) -> Some (float_of_int i) | _ -> None in
    (match get_string "id", get_string "content", get_float "created_at",
            get_float "updated_at", get_string "source" with
     | Some id, Some content, Some created_at, Some updated_at, Some source ->
       let summary = get_string "summary" in
       let scope = get_string "scope" in
       let metadata = match get "metadata" with
         | Some (`Assoc xs) -> xs
         | _ -> []
       in
       let categories = match get "categories" with
         | Some (`List xs) ->
           List.filter_map (function `String s -> Some s | _ -> None) xs
         | _ -> []
       in
       Ok { id; content; summary; scope; metadata; categories;
            created_at; updated_at; source }
     | _ -> Error "memory_object: missing required fields")
  | _ -> Error "memory_object: expected JSON object"
