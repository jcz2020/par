(* Skill Registry — Skill binding lookup table keyed by skill id.
   Mirrors Tool_registry pattern exactly. *)

type activate_fn = Types.runtime -> Types.skill_effect

type t = (string, activate_fn) Hashtbl.t

let create () = Hashtbl.create 16

let register (tbl : t) (binding : Types.skill_binding) =
  if Hashtbl.mem tbl binding.descriptor.Types.id then
    Error (`Duplicate_skill binding.descriptor.Types.id)
  else begin
    Hashtbl.replace tbl binding.descriptor.Types.id binding.activate;
    Ok ()
  end

let replace (tbl : t) id h =
  Hashtbl.replace tbl id h

let resolve tbl skill_id =
  Hashtbl.find_opt tbl skill_id

let find_descriptor (skills : Types.skill_descriptor list) skill_id =
  List.find_opt (fun (d : Types.skill_descriptor) -> d.id = skill_id) skills

let remove tbl skill_id =
  if Hashtbl.mem tbl skill_id then begin
    Hashtbl.remove tbl skill_id;
    Ok ()
  end
  else Error (`Not_found skill_id)

let list tbl =
  Hashtbl.fold (fun n _ acc -> n :: acc) tbl []
  |> List.sort String.compare
