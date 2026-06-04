(* Tool Registry — Handler lookup table keyed by tool name *)

type handler_fn = Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result

type t = (string, handler_fn) Hashtbl.t

let create () = Hashtbl.create 16

let register (tbl : t) (desc : Types.tool_descriptor) h =
  if Hashtbl.mem tbl desc.name then
    Error (`Duplicate_tool desc.name)
  else begin
    Hashtbl.replace tbl desc.name h;
    Ok ()
  end

let replace (tbl : t) name h =
  Hashtbl.replace tbl name h

let resolve tbl tool_name =
  Hashtbl.find_opt tbl tool_name

let find_descriptor (tools : Types.tool_descriptor list) tool_name =
  List.find_opt (fun (d : Types.tool_descriptor) -> d.name = tool_name) tools

let names tbl =
  Hashtbl.fold (fun n _ acc -> n :: acc) tbl []
  |> List.sort String.compare
