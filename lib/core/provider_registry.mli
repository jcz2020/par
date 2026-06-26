open Types

(* Thread-safe registry of named LLM providers. *)
type t

val create : unit -> t
(** Empty registry with no default. *)

val register : t -> id:string -> llm_service -> (unit, [> `Duplicate of string]) result
(** Add a provider under [id]. First registered becomes the default if no
    default is set yet. Returns [`Duplicate id] if [id] already present. *)

val list_ids : t -> string list
(** Registered provider ids, sorted. *)

val set_default : t -> id:string -> (unit, [> `Unknown of string]) result
(** Mark an already-registered provider as the default. *)

val get_default : t -> (llm_service, [> `No_default]) result
(** The currently-default provider's service. *)

val get : t -> id:string -> (llm_service, [> `Unknown of string]) result
(** Look up a provider by id. *)

val default_id : t -> string option
(** Current default id (or None). *)
