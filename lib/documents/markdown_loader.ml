(* Document Loaders Framework — Markdown loader (.md) *)

let split_frontmatter (content : string) : string option * string =
  let prefix = "---\n" in
  let prefix_len = String.length prefix in
  if String.length content > prefix_len && String.sub content 0 prefix_len = prefix
  then begin
    let rec find_close i =
      if i + prefix_len > String.length content then None
      else if String.sub content i prefix_len = prefix then Some i
      else find_close (i + 1)
    in
    match find_close prefix_len with
    | None -> (None, content)
    | Some close_idx ->
      let fm_raw = String.sub content prefix_len (close_idx - prefix_len) in
      let body_start = close_idx + prefix_len in
      let body =
        if body_start < String.length content
        then String.sub content body_start (String.length content - body_start)
        else ""
      in
      (Some fm_raw, body)
  end
  else (None, content)

let yaml_value_to_yojson (v : Yaml.value) : Yojson.Safe.t =
  let rec to_yojson = function
    | `Null -> `Null
    | `Bool b -> `Bool b
    | `Float f -> `Float f
    | `String s -> `String s
    | `O xs -> `Assoc (List.map (fun (k, v') -> (k, to_yojson v')) xs)
    | `A xs -> `List (List.map to_yojson xs)
  in
  to_yojson v

let merge_frontmatter (meta : (string, Yojson.Safe.t) Hashtbl.t) (fm_raw : string) : unit =
  match Yaml.of_string fm_raw with
  | Ok (`O kvs) ->
    List.iter (fun (k, v) ->
      Document.Meta.add meta k (yaml_value_to_yojson v)
    ) kvs
  | _ -> ()

let markdown_to_plain_text (md : string) : string =
  let doc = Omd.of_string md in
  let html = Omd.to_html doc in
  let soup = Soup.parse html in
  let text_parts = Soup.trimmed_texts soup in
  String.concat "\n" text_parts

let make workspace path =
  Logs.info (fun m -> m "Markdown_loader: loading %s" path);
  match Workspace.admit workspace path with
  | Error e ->
    Logs.warn (fun m -> m "Markdown_loader: workspace rejected %s" path);
    Error (Document.Workspace_rejected e)
  | Ok sandboxed ->
    let full_path = Workspace.to_string sandboxed in
    if not (Sys.file_exists full_path) then begin
      Logs.warn (fun m -> m "Markdown_loader: file not found %s" path);
      Error (Document.File_not_found path)
    end
    else
      Ok (fun () ->
        let fh = open_in full_path in
        Fun.protect
          (fun () ->
            let raw = really_input_string fh (in_channel_length fh) in
            let (fm_opt, body) = split_frontmatter raw in
            let content = markdown_to_plain_text body in
            let metadata = Document.Meta.empty () in
            (match fm_opt with Some fm -> merge_frontmatter metadata fm | None -> ());
            Document.Meta.add_string metadata "file_path" full_path;
            Document.Meta.add_string metadata "file_name" (Filename.basename full_path);
            Document.Meta.add_int metadata "file_size" (String.length raw);
            Document.Meta.add_string metadata "file_type" "text/markdown";
            [ Document.{ content; metadata; source = path } ])
          ~finally:(fun () -> close_in fh))
