(** Lightweight JSON Schema subset validator (UX-5a).

    See [Validation] for the implementation. *)

type validation_error = { path : string list; reason : string }

val string_of_validation_error : validation_error -> string

val validate_tool_input :
  Yojson.Safe.t ->
  Yojson.Safe.t ->
  (unit, validation_error) result

val validate_tool_input_result :
  Yojson.Safe.t ->
  Yojson.Safe.t ->
  (unit, Types.error_category) result

val validate_runtime_config :
  Types.runtime_config ->
  (unit, string) result

val validate_runtime_config_result :
  Types.runtime_config ->
  (unit, Types.error_category) result
