(* Document Loaders Framework — Text loader (.txt) *)

let make workspace path =
  Logs.info (fun m -> m "Text_loader: loading %s" path);
  match Workspace.admit workspace path with
  | Error e ->
    Logs.warn (fun m -> m "Text_loader: workspace rejected %s" path);
    Error (Document.Workspace_rejected e)
  | Ok sandboxed ->
    let full_path = Workspace.to_string sandboxed in
    if not (Sys.file_exists full_path) then begin
      Logs.warn (fun m -> m "Text_loader: file not found %s" path);
      Error (Document.File_not_found path)
    end
    else
      Ok (fun () ->
        let fh = open_in full_path in
        Fun.protect
          (fun () ->
            let len = in_channel_length fh in
            let content = really_input_string fh len in
            let metadata = Document.Meta.empty () in
            Document.Meta.add_string metadata "file_path" full_path;
            Document.Meta.add_string metadata "file_name" (Filename.basename full_path);
            Document.Meta.add_int metadata "file_size" (String.length content);
            Document.Meta.add_string metadata "file_type" "text/plain";
            [ Document.{ content; metadata; source = path } ])
          ~finally:(fun () -> close_in fh))
