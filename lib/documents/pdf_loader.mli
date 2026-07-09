(** PDF loader using camlpdf simple text-stream extraction.

    LIMITATIONS (v0.7.0 - scope compromise per ROADMAP section 2 #9):
    - No layout preservation: multi-column PDFs produce interleaved text
    - No OCR: scanned/image-only PDFs extract nothing
    - Tables and complex layouts may produce poor output
    - Trigger for layout-aware extraction: downstream failure rate >20% or v0.8

    For each page, produces one [Document.t] with metadata["page"] = page number. *)

val make : Workspace.workspace -> string ->
  (unit -> Document.t list, Document.load_error) result
