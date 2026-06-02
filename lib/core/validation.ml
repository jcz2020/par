(** Lightweight JSON Schema subset validator.

    Supports a useful subset of JSON Schema keywords sufficient for validating
    LLM tool-call arguments:
    - [type] : "string" | "integer" | "number" | "boolean" | "null" | "array" | "object"
    - [required] : list of required property names
    - [properties] : per-property subschemas (1 level of nesting)
    - [enum] : list of allowed values (structural equality)
    - [minimum] / [maximum] : numeric bounds
    - [minLength] / [maxLength] : length bounds for strings and arrays

    Unknown keywords are ignored (forward compatibility). All access is total
    (no exceptions raised for missing or mistyped schema fields).
*)

type validation_error = { path : string list; reason : string }

let string_of_validation_error e =
  let path_str = match e.path with
    | [] -> ""
    | _ -> "/" ^ String.concat "/" e.path
  in
  Printf.sprintf "at %s: %s" path_str e.reason

(* -------------------------------------------------------------------------- *)
(* Result.bind                                                                *)
(* -------------------------------------------------------------------------- *)

let ( >>= ) x f = match x with
  | Ok v -> f v
  | Error e -> Error e

(* -------------------------------------------------------------------------- *)
(* Safe JSON accessors                                                       *)
(* -------------------------------------------------------------------------- *)

let json_to_list = function `List l -> Some l | _ -> None

let json_to_assoc = function `Assoc l -> Some l | _ -> None

let json_to_string = function `String s -> Some s | _ -> None

let json_to_int = function `Int i -> Some i | _ -> None

let json_to_float = function
  | `Float f -> Some f
  | `Int i -> Some (Float.of_int i)
  | _ -> None

(* -------------------------------------------------------------------------- *)
(* Type checking                                                             *)
(* -------------------------------------------------------------------------- *)

let check_type expected actual =
  let actual_kind = match actual with
    | `String _ -> "string"
    | `Int _ -> "integer"
    | `Float f when Float.is_integer f -> "number"
    | `Float _ -> "number"
    | `Bool _ -> "boolean"
    | `Null -> "null"
    | `List _ -> "array"
    | `Assoc _ -> "object"
    | `Intlit _ -> "integer"
    | `Floatlit _ -> "number"
    | `Stringlit _ -> "string"
  in
  if actual_kind = expected then Ok ()
  else Error (Printf.sprintf "expected %s, got %s" expected actual_kind)

(* -------------------------------------------------------------------------- *)
(* Numeric and length predicates                                             *)
(* -------------------------------------------------------------------------- *)

let numeric_value = function
  | `Int i -> Float.of_int i
  | `Float f -> f
  | _ -> 0.0

let container_length = function
  | `String s -> String.length s
  | `List l -> List.length l
  | _ -> 0

let check_minimum v min_v =
  if numeric_value v >= min_v then Ok ()
  else Error (Printf.sprintf "value below minimum %g" min_v)

let check_maximum v max_v =
  if numeric_value v <= max_v then Ok ()
  else Error (Printf.sprintf "value above maximum %g" max_v)

let check_min_length v min_l =
  let len = container_length v in
  if len >= min_l then Ok ()
  else Error (Printf.sprintf "length %d below minLength %d" len min_l)

let check_max_length v max_l =
  let len = container_length v in
  if len <= max_l then Ok ()
  else Error (Printf.sprintf "length %d above maxLength %d" len max_l)

(* -------------------------------------------------------------------------- *)
(* Per-value validation against a subschema                                 *)
(* -------------------------------------------------------------------------- *)

let rec validate_value schema value path =
  (match json_to_string (member_opt schema "type") with
   | None -> Ok ()
   | Some t ->
     (match check_type t value with
      | Ok () -> Ok ()
      | Error reason -> Error { path; reason }))
  >>= fun () ->
  (match json_to_list (member_opt schema "enum") with
   | None | Some [] -> Ok ()
   | Some allowed ->
     if List.mem value allowed then Ok ()
     else Error { path; reason = "value not in enum" })
  >>= fun () ->
  (match json_to_float (member_opt schema "minimum") with
   | None -> Ok ()
   | Some m ->
     (match check_minimum value m with
      | Ok () -> Ok ()
      | Error reason -> Error { path; reason }))
  >>= fun () ->
  (match json_to_float (member_opt schema "maximum") with
   | None -> Ok ()
   | Some m ->
     (match check_maximum value m with
      | Ok () -> Ok ()
      | Error reason -> Error { path; reason }))
  >>= fun () ->
  (match json_to_int (member_opt schema "minLength") with
   | None -> Ok ()
   | Some m ->
     (match check_min_length value m with
      | Ok () -> Ok ()
      | Error reason -> Error { path; reason }))
  >>= fun () ->
  (match json_to_int (member_opt schema "maxLength") with
   | None -> Ok ()
   | Some m ->
     (match check_max_length value m with
      | Ok () -> Ok ()
      | Error reason -> Error { path; reason }))

and member_opt json key =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

(* -------------------------------------------------------------------------- *)
(* Top-level entry points                                                   *)
(* -------------------------------------------------------------------------- *)

(** [validate_tool_input schema value] validates [value] against [schema].
    Returns [Ok ()] on success, or [Error validation_error] describing the
    first violation found. The error category wrapper is provided by
    [validate_tool_input_result] below. *)
let validate_tool_input schema value =
  let path = [] in
  validate_value schema value path
  >>= fun () ->
  (match json_to_assoc value with
   | None -> Ok ()
   | Some fields ->
     let required = match json_to_list (member_opt schema "required") with
       | Some l -> List.filter_map json_to_string l
       | None -> []
     in
     let present = List.map fst fields in
     let missing = List.filter (fun r -> not (List.mem r present)) required in
     if missing = [] then Ok ()
     else Error {
       path = ["required"];
       reason = Printf.sprintf "missing required fields: %s"
         (String.concat ", " missing)
     })
  >>= fun () ->
  (match json_to_assoc value with
   | None -> Ok ()
   | Some fields ->
     let properties = match json_to_assoc (member_opt schema "properties") with
       | Some l -> l
       | None -> []
     in
     List.fold_left (fun acc (k, v) ->
       acc >>= fun () ->
       match List.assoc_opt k properties with
       | None -> Ok ()
       | Some subschema -> validate_value subschema v [k]
     ) (Ok ()) fields)

(** [validate_tool_input_result schema value] is the engine-facing entry
    point. It converts the internal [validation_error] into a
    [Types.error_category] of variant [Invalid_input]. *)
let validate_tool_input_result schema value =
  match validate_tool_input schema value with
  | Ok () -> Ok ()
  | Error e -> Result.Error (Types.Invalid_input (string_of_validation_error e))
