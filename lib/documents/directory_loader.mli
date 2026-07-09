(** Directory loader — recursively loads all files in a directory tree,
    dispatching by extension to the appropriate loader.

    Usage:
    {[
      let docs = Directory_loader.load ws ~map:Directory_loader.default_map "src/"
      |> Result.get_ok
    ]}

    Unknown extensions are skipped with a [Logs.warn]. Errors in individual
    files are logged and skipped (does not abort the whole scan). *)

type loader_fn = Workspace.workspace -> string -> (unit -> Document.t list, Document.load_error) result

type extension_map = (string * loader_fn) list

val load :
  Workspace.workspace ->
  ?map:extension_map ->
  string ->
  (Document.t list, Document.load_error) result

val default_map : extension_map
