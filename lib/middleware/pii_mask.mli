val default_patterns : string list

val pii_mask :
  ?patterns:string list ->
  ?replacement:string ->
  unit ->
  Types.middleware_hook
