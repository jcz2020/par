(* Mustache-style template rendering — variable substitution only ({{var}}) *)

type render_context = {
  agent_id : string;
  runtime_id : string;
  user_variables : (string * Yojson.Safe.t) list;
  available_tools : string list;
}

val render :
  template:string ->
  variables:(string * Yojson.Safe.t) list ->
  required:string list ->
  context:render_context ->
  (string, Types.error_category) result

val effective_system_prompt :
  Types.agent_config ->
  runtime_id:string ->
  (string, Types.error_category) result
