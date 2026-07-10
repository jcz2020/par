(** Directory loader — recursively loads all files in a directory tree,
    dispatching by extension to the appropriate loader.

    Usage:
    {[
      let docs = Directory_loader.load ws "src/"
      |> Result.get_ok
    ]}

    The default extension map covers [.txt], [.md], [.html], [.csv], [.pdf].
    Unknown extensions are skipped with a [Logs.warn]. Errors in individual
    files are logged and skipped (does not abort the whole scan).
    Circular symlinks are detected and skipped. *)

type loader_fn = Workspace.workspace -> string -> (unit -> Document.t list, Document.load_error) result

type extension_map = (string * loader_fn) list

val load :
  Workspace.workspace ->
  ?map:extension_map ->
  string ->
  (Document.t list, Document.load_error) result

val default_map : extension_map
