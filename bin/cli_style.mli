type style =
  | Bold
  | Dim
  | Cyan
  | Green
  | Red
  | BoldCyan

val supports_color : unit -> bool
val styled : style -> string -> string

val bold : string -> string
val dim : string -> string
val cyan : string -> string
val green : string -> string
val red : string -> string
val bold_cyan : string -> string
