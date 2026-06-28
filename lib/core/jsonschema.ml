let assoc_remove key assoc =
  List.filter (fun (k, _) -> not (String.equal k key)) assoc

let assoc_find ~default key assoc =
  match List.assoc_opt key assoc with
  | Some v -> v
  | None -> default

let property_keys_of = function
  | `Assoc pairs -> List.map fst pairs
  | _ -> []

let existing_required_keys = function
  | `List items ->
    List.filter_map
      (function `String s -> Some s | _ -> None)
      items
  | _ -> []

let union_required existing_keys property_keys =
  let seen = Hashtbl.create 16 in
  let ordered = ref [] in
  let push k =
    if not (Hashtbl.mem seen k) then begin
      Hashtbl.add seen k ();
      ordered := k :: !ordered
    end
  in
  List.iter push property_keys;
  List.iter push existing_keys;
  List.rev !ordered

let to_strict_object_schema (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc pairs ->
    let is_object_schema =
      match List.assoc_opt "type" pairs with
      | Some (`String "object") -> true
      | _ -> false
    in
    if not is_object_schema then json
    else begin
      let properties = assoc_find ~default:`Null "properties" pairs in
      let required = assoc_find ~default:`Null "required" pairs in
      let property_keys = property_keys_of properties in
      let existing_keys = existing_required_keys required in
      let merged_keys = union_required existing_keys property_keys in
      let pairs =
        ("additionalProperties", `Bool false) :: assoc_remove "additionalProperties" pairs
      in
      let pairs =
        ("required", `List (List.map (fun k -> `String k) merged_keys))
        :: assoc_remove "required" pairs
      in
      `Assoc pairs
    end
  | _ -> json
