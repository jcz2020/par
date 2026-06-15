open Types

let logging = {
  name = "logging";
  on_before_llm = Some (fun conv ->
    Logs.info (fun m -> m "LLM request: %d messages" (List.length conv.messages));
    None
  );
  on_after_llm = Some (fun resp ->
    Logs.info (fun m -> m "LLM response: finish_reason=%s model=%s"
      (match resp.finish_reason with Stop -> "stop" | Tool_calls -> "tool_calls"
       | Max_tokens -> "max_tokens" | Content_filter -> "content_filter")
      resp.model);
    None
  );
  on_before_tool = Some (fun call ->
    Logs.info (fun m -> m "Tool call: %s(%s)" call.name (Yojson.Safe.to_string call.arguments));
    None
  );
  on_after_tool = Some (fun (call, result) ->
    (match result with
     | Success _ -> Logs.info (fun m -> m "Tool success: %s" call.name)
     | Error e -> Logs.warn (fun m -> m "Tool error: %s — %s" call.name e.message)
     | Handoff _ -> Logs.info (fun m -> m "Tool handoff signaled"));
    None
  );
  on_error = Some (fun _err ->
    Logs.err (fun m -> m "Error: %s" (Printexc.to_string (Failure "error")));
    None
  );
}
