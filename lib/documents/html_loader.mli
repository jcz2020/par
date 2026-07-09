val make :
  Workspace.workspace ->
  string ->
  (unit -> Document.t list, Document.load_error) result
