open Types

exception Resource_limit of string

let default_limits = { max_depth = 10; max_node_visits = 1000 }

type eval_context = (string * Yojson.Safe.t) list

let visit_count = ref 0

let reset_visit () = visit_count := 0

let check_limit limits =
  incr visit_count;
  if !visit_count > limits.max_node_visits then
    raise (Resource_limit "Expression evaluator: max node visits exceeded")

let rec eval limits ctx expr depth =
  check_limit limits;
  if depth > limits.max_depth then
    raise (Resource_limit "Expression evaluator: max depth exceeded");
  match expr with
  | Literal v -> v
  | Variable path ->
    let parts = String.split_on_char '.' path in
    resolve_path ctx parts
  | Equals (a, b) ->
    let va = eval limits ctx a (depth + 1) in
    let vb = eval limits ctx b (depth + 1) in
    json_bool (Yojson.Safe.equal va vb)
  | Not_equals (a, b) ->
    let va = eval limits ctx a (depth + 1) in
    let vb = eval limits ctx b (depth + 1) in
    json_bool (not (Yojson.Safe.equal va vb))
  | Greater_than (a, b) ->
    let va = eval limits ctx a (depth + 1) in
    let vb = eval limits ctx b (depth + 1) in
    json_bool (compare_json_numbers va vb > 0)
  | Less_than (a, b) ->
    let va = eval limits ctx a (depth + 1) in
    let vb = eval limits ctx b (depth + 1) in
    json_bool (compare_json_numbers va vb < 0)
  | And (a, b) ->
    let va = eval limits ctx a (depth + 1) in
    let vb = eval limits ctx b (depth + 1) in
    json_bool (to_bool va && to_bool vb)
  | Or (a, b) ->
    let va = eval limits ctx a (depth + 1) in
    let vb = eval limits ctx b (depth + 1) in
    json_bool (to_bool va || to_bool vb)
  | Not a ->
    let va = eval limits ctx a (depth + 1) in
    json_bool (not (to_bool va))
  | Contains (a, b) ->
    let va = eval limits ctx a (depth + 1) in
    let vb = eval limits ctx b (depth + 1) in
    json_bool (json_contains va vb)
  | Has_key (a, key) ->
    let va = eval limits ctx a (depth + 1) in
    json_bool (json_has_key va key)
  | Is_empty a ->
    let va = eval limits ctx a (depth + 1) in
    json_bool (json_is_empty va)
  | Matches (a, pattern) ->
    let va = eval limits ctx a (depth + 1) in
    json_bool (json_matches va pattern)

and resolve_path ctx = function
  | [] -> `Null
  | [ key ] ->
    (match List.assoc_opt key ctx with
     | Some v -> v
     | None -> `Null)
  | key :: rest ->
    (match List.assoc_opt key ctx with
     | Some (`Assoc fields) -> resolve_path (List.map (fun (k, v) -> (k, v)) fields) rest
     | Some (`List items) ->
       (match rest with
        | [ idx ] ->
          (match int_of_string_opt idx with
           | Some i when i >= 0 && i < List.length items -> List.nth items i
           | _ -> `Null)
        | _ -> `Null)
     | _ -> `Null)

and json_bool b = `Bool b

and to_bool = function
  | `Bool b -> b
  | `Int n -> n <> 0
  | `Float f -> f <> 0.0
  | `String s -> s <> ""
  | `List l -> l <> []
  | `Null -> false
  | _ -> true

and compare_json_numbers a b =
  let to_float = function
    | `Int n -> Float.of_int n
    | `Float f -> f
    | `String s -> (match float_of_string_opt s with Some f -> f | None -> 0.0)
    | _ -> 0.0
  in
  Float.compare (to_float a) (to_float b)

and json_contains container element =
  match container with
  | `List items -> List.exists (fun i -> Yojson.Safe.equal i element) items
  | `String s ->
    (match element with
     | `String sub -> String.contains s (String.get sub 0)
     | _ -> false)
  | _ -> false

and json_has_key json key =
  match json with
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> false

and json_is_empty = function
  | `Null -> true
  | `List [] -> true
  | `String "" -> true
  | `Assoc [] -> true
  | _ -> false

and json_matches json pattern =
  match json with
  | `String s ->
    let re = Str.regexp pattern in
    Str.string_match re s 0
  | _ -> false

let evaluate ?(limits = default_limits) ctx expr =
  reset_visit ();
  try
    let result = eval limits ctx expr 0 in
    Ok result
  with
  | Resource_limit msg -> Result.Error (Internal msg)
  | Failure msg -> Result.Error (Invalid_input msg)

let evaluate_to_bool ?(limits = default_limits) ctx expr =
  match evaluate ~limits ctx expr with
  | Ok v -> Ok (to_bool v)
  | Error e -> Error e
