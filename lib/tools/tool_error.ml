(* lib/tools/tool_error.ml — Wave 2A
   Single source of truth for shared error markers. Tool descriptions TEACH
   these markers and rejection formatters EMIT them — both reference these
   constants so they can never drift apart. *)

let workspace_marker = "[workspace]"
let bash_policy_marker = "[bash-policy]"
let cancelled_marker = "[cancelled]"

let instructive ~marker ~why ~remedy : string =
  Printf.sprintf "%s %s %s" marker why remedy

(** [workspace_rejection_message ~path ~num_roots e] returns (message, metadata_code)
    for the given workspace admission error. [path] is echoed verbatim from the
    model's input. [num_roots] is [List.length ws.roots]. *)
let workspace_rejection_message ~path ~num_roots (e : Types.error_category)
  : string * string =
  match e with
  | Types.Invalid_input msg when
      (try ignore (Str.search_forward (Str.regexp_string "..") msg 0); true
       with Not_found -> false) ->
    ( Printf.sprintf "%s Path rejected: '%s' contains '..' \
         (path traversal is not allowed). \
         Use a clean relative path like 'src/main.ml', \
         or an absolute path under the workspace root."
        workspace_marker path,
      "workspace_parent_traversal" )
  | Types.Invalid_input msg when String.contains msg ':' ->
    ( Printf.sprintf "%s Path rejected: '%s' contains ':' \
         (reserved/ambiguous in tool arguments). \
         Use a path without ':'."
        workspace_marker path,
      "workspace_colon" )
  | Types.Invalid_input _ ->
    (* absolute-outside or other Invalid_input from admit *)
    ( Printf.sprintf "%s Path rejected: '%s' is an absolute path \
         outside the workspace (%d root(s)). \
         Use a relative path like 'src/main.ml' \
         (resolved against the workspace root) \
         or an absolute path under a workspace root."
        workspace_marker path num_roots,
      "workspace_absolute_outside" )
  | Types.Permission_denied _ ->
    ( Printf.sprintf "%s Path rejected: '%s' matches a protected location. \
         Choose a path outside protected system areas."
        workspace_marker path,
      "workspace_protected_location" )
  | _other ->
    ( Printf.sprintf "%s Path validation failed: %s" workspace_marker path,
      "workspace_unknown" )
