open Types

let timeout_middleware ~default_timeout = {
  name = "timeout";
  on_before_tool = Some (fun call ->
    (* timeout is enforced at handler level via cancellable_handler — this is informational *)
    None
  );
  on_error = Some (fun err ->
    (match err with
     | Timeout -> Some (Error {
         category = Timeout;
         message = "Operation timed out";
         retryable = true;
         metadata = [];
       })
     | _ -> None)
  );
  on_before_llm = None;
  on_after_llm = None;
  on_after_tool = None;
}
