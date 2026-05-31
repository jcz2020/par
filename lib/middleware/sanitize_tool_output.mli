type sanitize_action =
  [ `Replace of string
  | `Tag
  | `Block ]

type sanitize_config = {
  patterns : string list;
  action : sanitize_action;
}

val default_config : sanitize_config

val sanitize_tool_output :
  ?config:sanitize_config ->
  unit ->
  Types.middleware_hook
