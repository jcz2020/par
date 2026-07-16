(* Document Loaders Framework — Word document loader (.docx) *)

(* WordprocessingML namespace URI. Declared by the [xmlns:w] attribute on the
   root [<w:document>] element of every word/document.xml. Xmlm resolves the
   declared prefix automatically, so element names arrive as (uri, local). *)
let word_ns =
  "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

let docx_mime =
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

(* Streaming-scan word/document.xml and accumulate visible text.

   Visible text lives in [<w:t>] children of [<w:r>] (text runs). We capture
   character [Data] only when the innermost open element is a [<w:t>] in the
   word namespace, so field instructions ([<w:instrText>]) and deleted-text
   markers ([<w:delText>]) are excluded. Structural elements map to whitespace:
   [<w:p>] → newline (emitted on close so trailing text is never lost),
   [<w:tab>] → tab, [<w:br>] → newline. A stack of (in_word_ns, local) pairs
   tracks element nesting because [El_end] carries no name. *)
let extract_text (xml : string) : string =
  let input = Xmlm.make_input (`String (0, xml)) in
  let buf = Buffer.create 4096 in
  let stack = Stack.create () in
  let rec loop () =
    if Xmlm.eoi input then ()
    else
      match Xmlm.input input with
      | `Dtd _ -> loop ()
      | `El_start ((uri, local), _) ->
        Stack.push (uri = word_ns, local) stack;
        if uri = word_ns then begin
          match local with
          | "tab" -> Buffer.add_char buf '\t'
          | "br" -> Buffer.add_char buf '\n'
          | _ -> ()
        end;
        loop ()
      | `El_end ->
        let (in_word, local) = Stack.pop stack in
        if in_word && local = "p" then Buffer.add_char buf '\n';
        loop ()
      | `Data s ->
        if not (Stack.is_empty stack) then begin
          let (in_word, local) = Stack.top stack in
          if in_word && local = "t" then Buffer.add_string buf s
        end;
        loop ()
  in
  loop ();
  Buffer.contents buf

let make workspace path =
  Logs.info (fun m -> m "Docx_loader: loading %s" path);
  match Workspace.admit workspace path with
  | Error e ->
    Logs.warn (fun m -> m "Docx_loader: workspace rejected %s" path);
    Error (Document.Workspace_rejected e)
  | Ok sandboxed ->
    let full_path = Workspace.to_string sandboxed in
    if not (Sys.file_exists full_path) then begin
      Logs.warn (fun m -> m "Docx_loader: file not found %s" path);
      Error (Document.File_not_found path)
    end
    else
      Ok (fun () ->
        let stat = Unix.stat full_path in
        let file_size = stat.Unix.st_size in
        let file_name = Filename.basename full_path in
        let read_xml =
          try
            let zf = Zip.open_in full_path in
            Fun.protect
              (fun () ->
                match
                  (try Some (Zip.find_entry zf "word/document.xml") with
                   Not_found -> None)
                with
                | None -> Error "word/document.xml not found in archive"
                | Some entry -> Ok (Zip.read_entry zf entry))
              ~finally:(fun () -> Zip.close_in zf)
          with exn -> Error (Printexc.to_string exn)
        in
        match read_xml with
        | Error msg ->
          Logs.warn (fun m -> m "Docx_loader: extraction failed for %s: %s" path msg);
          []
        | Ok xml ->
          (try
             let content = extract_text xml in
             let metadata = Document.Meta.empty () in
             Document.Meta.add_string metadata "file_path" full_path;
             Document.Meta.add_string metadata "file_name" file_name;
             Document.Meta.add_int metadata "file_size" file_size;
             Document.Meta.add_string metadata "file_type" docx_mime;
             [ Document.{ content; metadata; source = path } ]
           with exn ->
             Logs.warn (fun m ->
               m "Docx_loader: XML parse failed for %s: %s" path (Printexc.to_string exn));
             []))
