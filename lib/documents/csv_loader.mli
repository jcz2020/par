(** CSV loader (.csv).

    Each data row (excluding header) produces one [Document.t]:
    - [content]: key-value lines formatted as ["col: val\n", ...]
    - [metadata]: each column name → its value (as `String), plus
      [row_index], [file_path], [file_name], [file_size], [file_type="text/csv"]
    - [source]: the input file path *)

val make : Workspace.workspace -> string ->
  (unit -> Document.t list, Document.load_error) result
