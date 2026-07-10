(* Document Loaders Framework — Directory loader (extension dispatch) *)

type loader_fn = Workspace.workspace -> string -> (unit -> Document.t list, Document.load_error) result

type extension_map = (string * loader_fn) list

let dispatch_by_extension (path : string) (map : extension_map) : loader_fn option =
  let ext = Filename.extension path in
  try Some (List.assoc ext map) with Not_found -> None

let default_map : extension_map = [
  ".txt", Text_loader.make;
  ".md", Markdown_loader.make;
  ".html", Html_loader.make;
  ".htm", Html_loader.make;
  ".csv", Csv_loader.make;
  ".pdf", Pdf_loader.make;
]

let load
    (workspace : Workspace.workspace)
    ?(map : extension_map = default_map)
    (dir : string)
  : (Document.t list, Document.load_error) result =
  let load_one path =
    match dispatch_by_extension path map with
    | None ->
      Logs.warn (fun m -> m "Directory_loader: no loader for %s, skipping" path);
      Ok []
    | Some fn ->
      (match fn workspace path with
       | Error e ->
         Logs.warn (fun m -> m "Directory_loader: skipping %s: %s" path (Document.load_error_to_string e));
         Ok []
       | Ok thunk ->
         (match thunk () with
          | exception exn ->
            Logs.warn (fun m -> m "Directory_loader: extraction failed for %s: %s" path (Printexc.to_string exn));
            Ok []
          | docs -> Ok docs))
  in
  let rec scan d acc visited =
    try
      let canon = Unix.realpath d in
      if List.mem canon visited then acc
      else if Sys.is_directory d then begin
        let visited' = canon :: visited in
        let entries = Sys.readdir d in
        Array.fold_left
          (fun acc' entry ->
            let full = Filename.concat d entry in
            scan full acc' visited')
          acc
          entries
      end else if Sys.file_exists d then begin
        match load_one d with
        | Ok docs -> acc @ docs
        | Error _ -> acc
      end else acc
    with Unix.Unix_error _ ->
      Logs.warn (fun m -> m "Directory_loader: cannot resolve %s, skipping" d);
      acc
  in
  match Workspace.admit workspace dir with
  | Error e -> Error (Document.Workspace_rejected e)
  | Ok sandboxed ->
    let abs_dir = Workspace.to_string sandboxed in
    if not (Sys.is_directory abs_dir) then
      Error (Document.File_not_found dir)
    else
      Ok (scan abs_dir [] [])
