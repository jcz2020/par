let extract_strings_from_tj (obj : Pdf.pdfobject) : string list =
  match obj with
  | Pdf.Array items ->
    List.filter_map (fun item ->
      match item with
      | Pdf.String s -> Some s
      | _ -> None
    ) items
  | Pdf.String s -> [s]
  | _ -> []

let build_font_extractors (pdf : Pdf.t) (resources : Pdf.pdfobject)
    : (string * Pdftext.text_extractor) list =
  match Pdf.lookup_direct pdf "/Font" resources with
  | Some (Pdf.Dictionary fonts) ->
    List.filter_map (fun (name, font_obj) ->
      try
        let extractor = Pdftext.text_extractor_of_font pdf font_obj in
        Some (name, extractor)
      with exn ->
        Logs.warn (fun m ->
          m "Pdf_loader: font extractor failed for %s: %s"
            name (Printexc.to_string exn));
        None
    ) fonts
  | Some _ ->
    Logs.warn (fun m -> m "Pdf_loader: /Font is not a dictionary");
    []
  | None ->
    Logs.warn (fun m -> m "Pdf_loader: no /Font entry in resources");
    []

let extract_page_text (pdf : Pdf.t) (page : Pdfpage.t) : string =
  let font_extractors = build_font_extractors pdf page.resources in
  let ops =
    try Pdfops.parse_operators pdf page.resources page.content
    with exn ->
      Logs.warn (fun m ->
        m "Pdf_loader: operator parse failed: %s" (Printexc.to_string exn));
      []
  in
  let buf = Buffer.create 1024 in
  let cur_ext = ref None in
  List.iter (fun op ->
    match op with
    | Pdfops.Op_Tf (name, _) ->
      cur_ext := (try Some (List.assoc name font_extractors)
                  with Not_found ->
                    Logs.warn (fun m ->
                      m "Pdf_loader: font %s not in resources" name);
                    None)
    | Pdfops.Op_Tj s ->
      (match !cur_ext with
       | Some ext ->
         Buffer.add_string buf
           (Pdftext.utf8_of_codepoints (Pdftext.codepoints_of_text ext s))
       | None -> ())
    | Pdfops.Op_TJ obj ->
      let strings = extract_strings_from_tj obj in
      List.iter (fun s ->
        match !cur_ext with
        | Some ext ->
          Buffer.add_string buf
            (Pdftext.utf8_of_codepoints (Pdftext.codepoints_of_text ext s))
        | None -> ()
      ) strings
    | Pdfops.Op_Td (_, dy) ->
      if dy < -10.0 then Buffer.add_char buf '\n'
    | Pdfops.Op_TD (_, dy) ->
      if dy < -10.0 then Buffer.add_char buf '\n'
    | Pdfops.Op_' _ ->
      Buffer.add_char buf '\n'
    | _ -> ()
  ) ops;
  Buffer.contents buf

let make workspace path =
  Logs.info (fun m -> m "Pdf_loader: loading %s" path);
  match Workspace.admit workspace path with
  | Error e ->
    Logs.warn (fun m -> m "Pdf_loader: workspace rejected %s" path);
    Error (Document.Workspace_rejected e)
  | Ok sandboxed ->
    let full_path = Workspace.to_string sandboxed in
    if not (Sys.file_exists full_path) then begin
      Logs.warn (fun m -> m "Pdf_loader: file not found %s" path);
      Error (Document.File_not_found path)
    end
    else
      Ok (fun () ->
        let pdf =
          try Pdfread.pdf_of_file None None full_path
          with exn ->
            failwith (Document.load_error_to_string
              (Document.Extraction_failed
                ("PDF load failed", Printexc.to_string exn)))
        in
        let pages = Pdfpage.pages_of_pagetree pdf in
        let file_name = Filename.basename full_path in
        let stat = Unix.stat full_path in
        let file_size = stat.Unix.st_size in
        List.mapi (fun i page ->
          let content = extract_page_text pdf page in
          let metadata = Document.Meta.empty () in
          Document.Meta.add_int metadata "page" (i + 1);
          Document.Meta.add_string metadata "file_path" full_path;
          Document.Meta.add_string metadata "file_name" file_name;
          Document.Meta.add_int metadata "file_size" file_size;
          Document.Meta.add_string metadata "file_type" "application/pdf";
          Document.{ content; metadata; source = path }
        ) pages
      )
