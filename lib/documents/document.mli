(** Document Loaders Framework core types.

    A [Document.t] is the unit produced by loaders. It mirrors the shape of
    [Vector_store.document] for seamless handoff to the RAG pipeline:

    - [content] is the extracted plain text
    - [metadata] holds source-derived fields (file_path, page, file_size, ...)
    - [source] is the URI or filesystem path the document came from

    See ROADMAP v0.7.0 §2 for design rationale. *)

(** The loaded document record. *)
type t = {
  content : string;
  metadata : (string, Yojson.Safe.t) Hashtbl.t;
  source : string;
}

(** Convenience helpers for metadata construction. *)
module Meta : sig
  val empty : unit -> (string, Yojson.Safe.t) Hashtbl.t
  val singleton : string -> Yojson.Safe.t -> (string, Yojson.Safe.t) Hashtbl.t
  val add : (string, Yojson.Safe.t) Hashtbl.t -> string -> Yojson.Safe.t -> unit
  val add_string : (string, Yojson.Safe.t) Hashtbl.t -> string -> string -> unit
  val add_int : (string, Yojson.Safe.t) Hashtbl.t -> string -> int -> unit
  val to_yojson : (string, Yojson.Safe.t) Hashtbl.t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (string, Yojson.Safe.t) Hashtbl.t
end

(** Errors that loaders can return. *)
type load_error =
  | File_not_found of string
  | Permission_denied of string
  | Unsupported_format of string
  | Extraction_failed of string * string  (** (message, exn printed) *)
  | Workspace_rejected of Types.error_category

val load_error_to_string : load_error -> string
