(* pdf_spike.ml — camlpdf text extraction probe
   Purpose: Validate camlpdf API for PDF text extraction before v0.7.0 Wave 2.
   This is a SPIKE, not production code. Findings documented in
   docs/plans/v0.7.0-pdf-spike-notes.md *)

(* Extract strings from a TJ array (Pdf.pdfobject).
   TJ arrays contain strings and kerning adjustments (numbers).
   We extract just the strings. *)
let extract_strings_from_tj (obj : Pdf.pdfobject) : string list =
  match obj with
  | Pdf.Array items ->
    List.filter_map (fun item ->
      match item with
      | Pdf.String s -> Some s
      | _ -> None  (* Skip kerning adjustments (Real/Integer) *)
    ) items
  | Pdf.String s -> [s]
  | _ -> []

(* Look up font extractors from the page resources dictionary.
   Returns a list of (font_name, text_extractor) pairs. *)
let build_font_extractors (pdf : Pdf.t) (resources : Pdf.pdfobject)
    : (string * Pdftext.text_extractor) list =
  match Pdf.lookup_direct pdf "/Font" resources with
  | Some (Pdf.Dictionary fonts) ->
    List.filter_map (fun (name, font_obj) ->
      try
        let extractor = Pdftext.text_extractor_of_font pdf font_obj in
        Some (name, extractor)
      with exn ->
        Printf.eprintf "  [WARN] Failed to build extractor for font %s: %s\n"
          name (Printexc.to_string exn);
        None
    ) fonts
  | Some _ ->
    Printf.eprintf "  [WARN] /Font is not a dictionary\n";
    []
  | None ->
    Printf.eprintf "  [WARN] No /Font entry in resources\n";
    []

(* Extract text from a single page *)
let extract_page_text (pdf : Pdf.t) (page_num : int) (page : Pdfpage.t)
    : string =
  Printf.eprintf "\n=== Page %d ===\n" page_num;
  Printf.eprintf "  Resources type: %s\n"
    (match page.resources with
     | Pdf.Dictionary _ -> "Dictionary"
     | Pdf.Indirect n -> Printf.sprintf "Indirect(%d)" n
     | _ -> "Other");
  Printf.eprintf "  Content streams: %d\n" (List.length page.content);

  (* Build font extractors from page resources *)
  let font_extractors = build_font_extractors pdf page.resources in
  Printf.eprintf "  Fonts found: %d\n" (List.length font_extractors);
  List.iter (fun (name, _) ->
    Printf.eprintf "    - %s\n" name
  ) font_extractors;

  (* Parse the content stream into operators *)
  let ops =
    try
      Pdfops.parse_operators pdf page.resources page.content
    with exn ->
      Printf.eprintf "  [ERROR] Failed to parse operators: %s\n"
        (Printexc.to_string exn);
      []
  in
  Printf.eprintf "  Operators parsed: %d\n" (List.length ops);

  (* Walk operators, tracking current font, collecting text *)
  let text_buffer = Buffer.create 1024 in
  let current_font = ref "" in
  let current_extractor : Pdftext.text_extractor option ref = ref None in

  List.iter (fun op ->
    match op with
    | Pdfops.Op_Tf (font_name, _size) ->
      current_font := font_name;
      current_extractor := (try
        Some (List.assoc font_name font_extractors)
      with Not_found ->
        Printf.eprintf "  [WARN] Font %s not found in resources\n" font_name;
        None)
    | Pdfops.Op_Tj raw_string ->
      (match !current_extractor with
       | Some ext ->
         let codepoints = Pdftext.codepoints_of_text ext raw_string in
         let utf8 = Pdftext.utf8_of_codepoints codepoints in
         Buffer.add_string text_buffer utf8
       | None ->
         Printf.eprintf "  [WARN] No extractor for font %s, skipping Tj\n"
           !current_font)
    | Pdfops.Op_TJ tj_obj ->
      let strings = extract_strings_from_tj tj_obj in
      List.iter (fun raw_string ->
        match !current_extractor with
        | Some ext ->
          let codepoints = Pdftext.codepoints_of_text ext raw_string in
          let utf8 = Pdftext.utf8_of_codepoints codepoints in
          Buffer.add_string text_buffer utf8
        | None ->
          Printf.eprintf "  [WARN] No extractor for font %s, skipping TJ\n"
            !current_font
      ) strings
    | Pdfops.Op_Td (_, dy) ->
      (* Add newline on significant vertical moves *)
      if dy < -10.0 then Buffer.add_char text_buffer '\n'
    | Pdfops.Op_TD (_, dy) ->
      if dy < -10.0 then Buffer.add_char text_buffer '\n'
    | Pdfops.Op_' _ ->
      (* T' operator = move to next line and show text *)
      Buffer.add_char text_buffer '\n'
    | _ -> ()
  ) ops;

  let text = Buffer.contents text_buffer in
  Printf.eprintf "  Characters extracted: %d\n" (String.length text);
  if String.length text > 0 then begin
    let sample_len = min 200 (String.length text) in
    Printf.eprintf "  Sample (first %d chars):\n" sample_len;
    Printf.eprintf "    \"%s\"\n" (String.sub text 0 sample_len)
  end else
    Printf.eprintf "  [WARN] No text extracted from this page!\n";
  text

(* Main *)
let () =
  let pdf_path = "/tmp/opencode/sample.pdf" in
  Printf.eprintf "=== camlpdf PDF Text Extraction Spike ===\n";
  Printf.eprintf "Input: %s\n" pdf_path;

  (* Load the PDF *)
  let pdf =
    try
      Pdfread.pdf_of_file None None pdf_path
    with exn ->
      Printf.eprintf "[FATAL] Failed to load PDF: %s\n"
        (Printexc.to_string exn);
      exit 1
  in
  Printf.eprintf "PDF loaded successfully.\n";

  (* Get page count *)
  let page_count = Pdfpage.endpage pdf in
  Printf.eprintf "Total pages: %d\n" page_count;

  (* Get pages *)
  let pages = Pdfpage.pages_of_pagetree pdf in
  Printf.eprintf "Pages extracted from page tree: %d\n" (List.length pages);

  (* Extract text from each page *)
  let page_texts = List.mapi (fun i page ->
    extract_page_text pdf (i + 1) page
  ) pages in

  (* Summary *)
  let total_chars = List.fold_left (fun acc t -> acc + String.length t) 0 page_texts in
  Printf.eprintf "\n=== Summary ===\n";
  Printf.eprintf "Pages processed: %d\n" (List.length page_texts);
  Printf.eprintf "Total characters extracted: %d\n" total_chars;
  Printf.eprintf "Average chars per page: %d\n"
    (if List.length page_texts > 0 then total_chars / List.length page_texts else 0);

  (* Print full extracted text to stdout for verification *)
  Printf.printf "=== Extracted Text ===\n";
  List.iteri (fun i text ->
    Printf.printf "\n--- Page %d ---\n" (i + 1);
    Printf.printf "%s\n" text
  ) page_texts;

  Printf.eprintf "\n=== Spike Complete ===\n";
  if total_chars > 0 then
    Printf.eprintf "GATE: PASS — camlpdf extracted %d chars of legible text.\n" total_chars
  else
    Printf.eprintf "GATE: FAIL — No text extracted. Consider deferring PDF to v0.7.1.\n"
