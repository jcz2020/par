(* Tool Registry — Handler lookup table keyed by tool name *)

type handler_fn = Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result

type tool_layer = Always | Searchable

type entry = {
  descriptor : Types.tool_descriptor;
  handler : handler_fn;
  layer : tool_layer;
}

type t = (string, entry) Hashtbl.t

let create () = Hashtbl.create 16

let register (tbl : t) (desc : Types.tool_descriptor) h =
  if Hashtbl.mem tbl desc.name then
    Error (`Duplicate_tool desc.name)
  else begin
    Hashtbl.replace tbl desc.name { descriptor = desc; handler = h; layer = Always };
    Ok ()
  end

let register_searchable (tbl : t) (desc : Types.tool_descriptor) h =
  if Hashtbl.mem tbl desc.name then
    Error (`Duplicate_tool desc.name)
  else begin
    Hashtbl.replace tbl desc.name { descriptor = desc; handler = h; layer = Searchable };
    Ok ()
  end

let replace (tbl : t) name h =
  match Hashtbl.find_opt tbl name with
  | Some entry -> Hashtbl.replace tbl name { entry with handler = h }
  | None -> Hashtbl.replace tbl name { descriptor = { name; description = ""; input_schema = `Assoc []; output_schema = None; permission = Types.Allow; timeout = None; concurrency_limit = None; on_update = None; cache_control = None }; handler = h; layer = Always }

let unregister (tbl : t) name =
  if Hashtbl.mem tbl name then begin
    Hashtbl.remove tbl name;
    Ok ()
  end else
    Error (`Tool_not_found name)

let resolve tbl tool_name =
  match Hashtbl.find_opt tbl tool_name with
  | Some entry -> Some entry.handler
  | None -> None

let set_layer tbl name layer =
  match Hashtbl.find_opt tbl name with
  | Some entry -> Hashtbl.replace tbl name { entry with layer }
  | None -> ()

let searchable_descriptors tbl =
  Hashtbl.fold (fun _name entry acc ->
    match entry.layer with
    | Searchable -> entry.descriptor :: acc
    | Always -> acc
  ) tbl []
  |> List.sort (fun (a : Types.tool_descriptor) (b : Types.tool_descriptor) ->
    String.compare a.name b.name)

let layer_of tbl name =
  match Hashtbl.find_opt tbl name with
  | Some entry -> entry.layer
  | None -> Always

let find_descriptor (tools : Types.tool_descriptor list) tool_name =
  List.find_opt (fun (d : Types.tool_descriptor) -> d.name = tool_name) tools

let names tbl =
  Hashtbl.fold (fun n _ acc -> n :: acc) tbl []
  |> List.sort String.compare

let copy_all ~src ~dst =
  Hashtbl.iter (fun name entry -> Hashtbl.replace dst name entry) src
