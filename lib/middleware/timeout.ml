open Types

(* PAR-19b (GH#17): the timeout middleware was a no-op because the
   [middleware_hook.on_before_tool] contract fires only once before the
   tool call and cannot enforce a deadline around the actual handler
   execution. The authoritative fix lives in
   [Par.Types.agent_config.tool_timeout], which the engine enforces via
   [Cancellation.with_timeout] inside [Engine.execute_tool].

   This module is preserved only for backward compatibility with
   existing user code: it emits a deprecation warning on first use and
   returns a no-op hook so programs still type-check. *)

let _warned = ref false

let timeout_middleware ~default_timeout:_ =
  if not !_warned then begin
    _warned := true;
    Logs.warn (fun m ->
      m "Timeout.timeout_middleware is deprecated (PAR-19b); use agent_config.tool_timeout via Runtime.make_agent ~tool_timeout:<seconds> instead. The legacy middleware cannot enforce timeouts from inside the middleware_hook contract.")
  end;
  {
    name = "timeout";
    on_before_tool = Some (fun _call -> None);
    on_error = None;
    on_before_llm = None;
    on_after_llm = None;
    on_after_tool = None;
  }