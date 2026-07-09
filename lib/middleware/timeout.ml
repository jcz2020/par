open Types

(* PAR-19b (GH#17): the timeout middleware was a no-op because the
   [middleware_hook.on_before_tool] contract fires only once before the
   tool call and cannot enforce a deadline around the actual handler
   execution. The authoritative fix lives in
   [Par.Types.agent_config.tool_timeout], which the engine enforces via
   [Cancellation.with_timeout] inside [Engine.execute_tool].

   This module is preserved only for backward compatibility with existing
   user code: it emits a [Deprecation.warn_once] signal on first use and
   returns a no-op hook so programs still type-check. *)

let timeout_middleware ~default_timeout:_ =
  Deprecation.warn_once
    ~since:"v0.6.4"
    ~removed_in:"v0.8"
    ~migration:
      "use agent_config.tool_timeout via Runtime.make_agent ~tool_timeout:<seconds>"
    ~fn_name:"Timeout.timeout_middleware" ();
  {
    name = "timeout";
    on_before_tool = Some (fun _call -> None);
    on_error = None;
    on_before_llm = None;
    on_after_llm = None;
    on_after_tool = None;
  }