(* Document Loaders Framework — core types *)

type t = {
  content : string;
  metadata : (string, Yojson.Safe.t) Hashtbl.t;
  source : string;
}

module Meta = struct
  let empty () = Hashtbl.create 16

  let singleton key value =
    let h = Hashtbl.create 1 in
    Hashtbl.replace h key value;
    h

  let add = Hashtbl.replace

  let add_string h k v = Hashtbl.replace h k (`String v)

  let add_int h k v = Hashtbl.replace h k (`Int v)

  let to_yojson h =
    `Assoc (Hashtbl.fold (fun k v acc -> (k, v) :: acc) h [])

  let of_yojson = function
    | `Assoc xs ->
      let h = Hashtbl.create (List.length xs) in
      List.iter (fun (k, v) -> Hashtbl.replace h k v) xs;
      h
    | _ -> Hashtbl.create 0
end

type load_error =
  | File_not_found of string
  | Permission_denied of string
  | Unsupported_format of string
  | Extraction_failed of string * string
  | Workspace_rejected of Types.error_category

let string_of_error_category (e : Types.error_category) = match e with
  | Types.Timeout -> "timeout"
  | Types.Invalid_input s -> Printf.sprintf "invalid input: %s" s
  | Types.External_failure s -> Printf.sprintf "external failure: %s" s
  | Types.Rate_limited -> "rate limited"
  | Types.Permission_denied s -> Printf.sprintf "permission denied: %s" s
  | Types.Internal s -> Printf.sprintf "internal error: %s" s
  | Types.Embedding_unsupported -> "embedding unsupported"

let load_error_to_string = function
  | File_not_found path ->
    Printf.sprintf "File not found: %s" path
  | Permission_denied path ->
    Printf.sprintf "Permission denied: %s" path
  | Unsupported_format fmt ->
    Printf.sprintf "Unsupported format: %s" fmt
  | Extraction_failed (msg, exn_str) ->
    Printf.sprintf "Extraction failed: %s (%s)" msg exn_str
  | Workspace_rejected cat ->
    Printf.sprintf "Workspace rejected: %s" (string_of_error_category cat)

module type LOADER = sig
  val lazy_load : unit -> t Seq.t
  val load : unit -> t list
end
