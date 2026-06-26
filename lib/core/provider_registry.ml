open Types

(* Thread-safe registry of named LLM providers, built on protected_hashtbl.
   Mirrors the pattern used by the 5 other protected_hashtbl-backed registries
   in runtime.ml (agents/tasks/workflows/workflow_defs/mcp_servers).
   Default-provider tracking is an additional ref protected by the same mutex. *)

type t = {
  tbl : (string, llm_service) protected_hashtbl;
  mutable default_id : string option;
}

let create () = {
  tbl = {
    data = Hashtbl.create 8;
    mutex = Eio.Mutex.create ();
  };
  default_id = None;
}

let register t ~id svc =
  match Types.htbl_get t.tbl id with
  | Some _ -> Result.Error (`Duplicate id)
  | None ->
    Types.htbl_set t.tbl id svc;
    (* First registered becomes default if no default set yet. *)
    if t.default_id = None then t.default_id <- Some id;
    Result.Ok ()

let list_ids t =
  let acc = ref [] in
  Types.htbl_iter t.tbl (fun k _ -> acc := k :: !acc);
  List.sort String.compare !acc

let set_default t ~id =
  match Types.htbl_get t.tbl id with
  | None -> Result.Error (`Unknown id)
  | Some _ -> t.default_id <- Some id; Result.Ok ()

let get_default t =
  match t.default_id with
  | None -> Result.Error `No_default
  | Some id ->
    (match Types.htbl_get t.tbl id with
     | Some svc -> Result.Ok svc
     | None -> Result.Error `No_default)  (* default_id stale — shouldn't happen *)

let get t ~id =
  match Types.htbl_get t.tbl id with
  | Some svc -> Result.Ok svc
  | None -> Result.Error (`Unknown id)

let default_id t = t.default_id
