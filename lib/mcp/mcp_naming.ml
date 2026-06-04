(* lib/mcp/mcp_naming.ml *)

let is_alphanum c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')

let sanitize s =
  if s = "" then "_"
  else
    String.map (fun c ->
      match c with
      | ':' | '.' | '/' | '\\' -> '_'
      | c when is_alphanum c || c = '_' || c = '-' -> c
      | _ -> '_'
    ) s

let validate_server_name s =
  let len = String.length s in
  if len = 0 then
    Result.Error (Types.Invalid_input "server name must not be empty")
  else if len > 32 then
    Result.Error (Types.Invalid_input
      (Printf.sprintf "server name must be <=32 chars (got %d)" len))
  else if not (String.for_all (fun c ->
    is_alphanum c || c = '_' || c = '-'
  ) s) then
    Result.Error (Types.Invalid_input
      (Printf.sprintf "server name must contain only [a-zA-Z0-9_-]: %S" s))
  else
    Ok ()

let mangle_tool_name ~style ~server_name ~tool_name =
  let s = sanitize server_name in
  let t = sanitize tool_name in
  let prefix = match style with
    | Mcp_types.Hierarchical -> Printf.sprintf "mcp__%s__" s
    | Mcp_types.Flat         -> Printf.sprintf "%s_" s
  in
  let full = prefix ^ t in
  let len = String.length full in
  if len > 60 then (
    if len >= 50 then
      Logs.warn (fun m ->
        m "MCP tool name exceeds 60 chars and will be truncated: %s (len=%d)"
          full len);
    String.sub full 0 60
  ) else if len >= 50 then (
    Logs.warn (fun m -> m "MCP tool name is long (%d chars): %s" len full);
    full
  ) else full

let display_title ~server_name ~tool_name =
  if server_name = "" || tool_name = "" then ""
  else Printf.sprintf "%s.%s" server_name tool_name

let detect_collisions ~existing ~to_add =
  let existing_set = Hashtbl.create (List.length existing) in
  List.iter (fun n -> Hashtbl.add existing_set n ()) existing;
  List.filter (fun n -> Hashtbl.mem existing_set n) to_add
