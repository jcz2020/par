(** Shared bash tool descriptor — used by both [builtin_tools] (stub) and
    [Runtime.install_bash_tool] (real handler). Single source of truth
    prevents schema drift. *)
val bash_tool_descriptor : Types.tool_descriptor

val builtin_tools :
  switch:Eio.Switch.t ->
  net:'a Eio.Net.t ->
  workspace:Workspace.workspace ->
  Types.tool_binding list
