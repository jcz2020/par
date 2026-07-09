type memory_error =
  | Not_found
  | Invalid_scope
  | FTS5_unavailable of string
  | Database_error of string

let to_string = function
  | Not_found -> "memory entry not found"
  | Invalid_scope -> "invalid or missing scope"
  | FTS5_unavailable msg -> Printf.sprintf "FTS5 unavailable: %s" msg
  | Database_error msg -> Printf.sprintf "database error: %s" msg
