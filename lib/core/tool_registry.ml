(* §Tool Registry — Handler lookup table keyed by tool name *)

type handler_fn = Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result

type t = (string, handler_fn) Hashtbl.t

let create () = Hashtbl.create 16

let register tbl desc h =
  match Types.tool_descriptor_to_yojson desc with
  | `Assoc fields ->
    (match List.assoc_opt "name" fields with
     | Some (`String n) -> Hashtbl.replace tbl n h
     | _ -> ())
  | _ -> ()

let resolve tbl tool_name =
  Hashtbl.find_opt tbl tool_name

let find_descriptor (tools : Types.tool_descriptor list) tool_name =
  List.find_opt (fun (d : Types.tool_descriptor) ->
    match Types.tool_descriptor_to_yojson d with
    | `Assoc fields ->
      (match List.assoc_opt "name" fields with
       | Some (`String n) -> n = tool_name
       | _ -> false)
    | _ -> false
  ) tools

let names tbl =
  Hashtbl.fold (fun n _ acc -> n :: acc) tbl []
  |> List.sort String.compare
