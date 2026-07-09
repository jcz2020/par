(* Document Loaders Framework — CSV loader (.csv) *)

let make workspace path =
  Logs.info (fun m -> m "Csv_loader: loading %s" path);
  match Workspace.admit workspace path with
  | Error e ->
    Logs.warn (fun m -> m "Csv_loader: workspace rejected %s" path);
    Error (Document.Workspace_rejected e)
  | Ok sandboxed ->
    let full_path = Workspace.to_string sandboxed in
    if not (Sys.file_exists full_path) then begin
      Logs.warn (fun m -> m "Csv_loader: file not found %s" path);
      Error (Document.File_not_found path)
    end
    else
      Ok (fun () ->
        let rows = Csv.load full_path in
        let file_size = (Unix.stat full_path).Unix.st_size in
        let file_name = Filename.basename full_path in
        match rows with
        | [] -> []
        | header :: data ->
          List.mapi (fun i row ->
            let buf = Buffer.create 256 in
            let metadata = Document.Meta.empty () in
            Document.Meta.add_int metadata "row_index" (i + 1);
            (try List.iter2 (fun col value ->
              Buffer.add_string buf col;
              Buffer.add_string buf ": ";
              Buffer.add_string buf value;
              Buffer.add_char buf '\n';
              Document.Meta.add_string metadata col value
            ) header row with Invalid_argument _ ->
              (* row has different length than header — best effort *)
              List.iteri (fun j value ->
                let col = try List.nth header j with _ -> Printf.sprintf "col_%d" j in
                Buffer.add_string buf col;
                Buffer.add_string buf ": ";
                Buffer.add_string buf value;
                Buffer.add_char buf '\n';
                Document.Meta.add_string metadata col value
              ) row);
            Document.Meta.add_string metadata "file_path" full_path;
            Document.Meta.add_string metadata "file_name" file_name;
            Document.Meta.add_int metadata "file_size" file_size;
            Document.Meta.add_string metadata "file_type" "text/csv";
            Document.{
              content = Buffer.contents buf;
              metadata;
              source = path;
            }
          ) data)
