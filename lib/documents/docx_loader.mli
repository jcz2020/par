(** Word document loader (.docx). Produces one [Document.t] per file by
    reading the OOXML ZIP container, extracting [word/document.xml], and
    parsing it with [Xmlm] to recover plain text from [<w:t>] text runs.

    Standard metadata is attached: file_path, file_name, file_size (the
    real on-disk file size, not the extracted text length), and
    file_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document".

    Extraction limitations (formatting, tables, images — see
    [docs/sdk/document_loaders.md]): only visible text from [<w:t>]
    elements is extracted. Paragraphs, tabs, and breaks are honored. *)

val make : Workspace.workspace -> string ->
  (unit -> Document.t list, Document.load_error) result
