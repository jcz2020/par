open Types

(** Long-output pure generation mode (plan §3.1.3).

    Skips the ReAct loop. For long text artifacts (PRDs, HTML mockups, plans,
    documentation) where no tool calls are needed. Auto-continues on
    [Max_tokens] truncation until the model emits [Stop], the
    [total_timeout] fires, or the per-call [max_output_tokens] budget is
    repeatedly hit with no progress.

    Decoupled from [Engine.run_agent] — Continue logic is independent.
    The returned [conversation] includes every message produced (system +
    user + assistant turns + Continue feedback turns) so callers
    ([Runtime.invoke_generate]) can save and resume it. *)

val run :
  ?session_id:string ->
  agent:agent_config ->
  message:string ->
  ?max_output_tokens:int ->
  ?total_timeout:float ->
  ?on_tool_event:(event -> unit) ->
  ?on_chunk:(llm_response_chunk -> unit) ->
  cancellation_token:cancellation_token ->
  llm:llm_service ->
  unit ->
  (generate_result * conversation, error_category * conversation) result
