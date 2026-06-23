open Types

let timeout_middleware ~default_timeout:_ = {
  name = "timeout";
  on_before_tool = Some (fun _call ->
    None
  );
  on_error = None;
  on_before_llm = None;
  on_after_llm = None;
  on_after_tool = None;
}
