let make ws path =
  match Workspace.admit ws path with
  | Error e -> Error (Document.Workspace_rejected e)
  | Ok sandboxed ->
    Logs.info (fun m -> m "Html_loader: admitted path %s" path);
    let full_path = Workspace.to_string sandboxed in
    let loader () =
      let fh = open_in full_path in
      let html = really_input_string fh (in_channel_length fh) in
      close_in fh;
      let soup = Soup.parse html in
      List.iter (fun tag -> Soup.iter Soup.delete (Soup.select tag soup))
        ["script"; "style"; "nav"; "footer"];
      let text_parts = Soup.trimmed_texts soup in
      let cleaned_text = String.concat " " text_parts in
      let file_size = String.length cleaned_text in
      let meta = Document.Meta.empty () in
      Document.Meta.add_string meta "file_path" full_path;
      Document.Meta.add_string meta "file_name" (Filename.basename full_path);
      Document.Meta.add_int meta "file_size" file_size;
      Document.Meta.add_string meta "file_type" "text/html";
      [ Document.{ content = cleaned_text; metadata = meta; source = path } ]
    in
    Ok loader
