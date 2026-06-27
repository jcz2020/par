open Types

type activate_fn = unit -> skill_effect

type t = (string, skill_binding) Hashtbl.t

let create () = Hashtbl.create 16

let register (tbl : t) (binding : skill_binding) =
  if Hashtbl.mem tbl binding.descriptor.id then
    Result.Error (`Duplicate_skill binding.descriptor.id)
  else begin
    Hashtbl.replace tbl binding.descriptor.id binding;
    Result.Ok ()
  end

let replace (tbl : t) id (h : activate_fn) =
  match Hashtbl.find_opt tbl id with
  | Some binding ->
    Hashtbl.replace tbl id { binding with activate = h }
  | None -> ()

let resolve tbl skill_id =
  match Hashtbl.find_opt tbl skill_id with
  | Some binding -> Some binding.activate
  | None -> None

let find_descriptor (skills : skill_descriptor list) skill_id =
  List.find_opt (fun (d : skill_descriptor) -> d.id = skill_id) skills

let remove tbl skill_id =
  if Hashtbl.mem tbl skill_id then begin
    Hashtbl.remove tbl skill_id;
    Result.Ok ()
  end
  else Result.Error (`Not_found skill_id)

let list tbl =
  Hashtbl.fold (fun k _ acc -> k :: acc) tbl []
  |> List.sort String.compare

let list_descriptors tbl =
  Hashtbl.fold (fun _ binding acc -> binding.descriptor :: acc) tbl []
  |> List.sort (fun (a : skill_descriptor) (b : skill_descriptor) ->
       String.compare a.id b.id)
