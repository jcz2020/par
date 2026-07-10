let make ws path =
  match Workspace.admit ws path with
  | Error e -> Error (Document.Workspace_rejected e)
  | Ok sandboxed ->
    Logs.info (fun m -> m "Html_loader: admitted path %s" path);
    let full_path = Workspace.to_string sandboxed in
    if not (Sys.file_exists full_path) then begin
      Logs.warn (fun m -> m "Html_loader: file not found %s" path);
      Error (Document.File_not_found path)
    end
    else
      let loader () =
        let fh = open_in full_path in
        Fun.protect
          ~finally:(fun () -> close_in fh)
          (fun () ->
            let file_size = in_channel_length fh in
            let html = really_input_string fh file_size in
            let soup = Soup.parse html in
            List.iter (fun tag -> Soup.iter Soup.delete (Soup.select tag soup))
              ["script"; "style"; "nav"; "footer"];
            let text_parts = Soup.trimmed_texts soup in
            let cleaned_text = String.concat " " text_parts in
            let meta = Document.Meta.empty () in
            Document.Meta.add_string meta "file_path" full_path;
            Document.Meta.add_string meta "file_name" (Filename.basename full_path);
            Document.Meta.add_int meta "file_size" file_size;
            Document.Meta.add_string meta "file_type" "text/html";
            [ Document.{ content = cleaned_text; metadata = meta; source = path } ])
      in
      Ok loader
