val builtin_tools :
  switch:Eio.Switch.t ->
  net:'a Eio.Net.t ->
  workspace:Workspace.workspace ->
  Types.tool_binding list
