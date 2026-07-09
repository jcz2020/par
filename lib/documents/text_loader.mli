(** Text loader (.txt). Produces one [Document.t] per file with
    standard metadata (file_path, file_name, file_size, file_type="text/plain"). *)

val make : Workspace.workspace -> string ->
  (unit -> Document.t list, Document.load_error) result
