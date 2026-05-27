open Par_core.Types

(* Input/output JSON validation middleware.
   - strict = false (default): fix invalid inputs where possible
   - strict = true: reject invalid inputs with errors *)

let validation ?(strict = false) () : middleware_hook =
  (* Track tool calls whose arguments were invalid, so on_after_tool
     can produce a proper Error result. *)
  let invalid_args : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  {
    name = "validation";

    on_before_llm = None;

    (* Validate LLM response has either text or tool_calls *)
    on_after_llm = Some (fun resp ->
      match (resp.text, resp.tool_calls) with
      | None, None | None, Some [] ->
        if strict then begin
          Logs.warn (fun m ->
            m "Validation: LLM response missing both text and tool_calls");
        end;
        None
      | _ -> None
    );

    (* Validate tool arguments are a JSON object (Assoc).
       In strict mode, mark invalid calls for on_after_tool to reject.
       In lenient mode, replace with empty object. *)
    on_before_tool = Some (fun call ->
      match call.arguments with
      | `Assoc _ -> None
      | _ ->
        Hashtbl.replace invalid_args call.id ();
        if strict then
          (* Replace args so tool doesn't crash, on_after_tool will
             override the result with an error. *)
          Some { call with arguments = `Assoc [] }
        else begin
          Logs.warn (fun m ->
            m "Validation: tool '%s' args not a JSON object, fixing" call.name);
          Some { call with arguments = `Assoc [] }
        end
    );

    (* If the tool call had invalid arguments, return an error result *)
    on_after_tool = Some (fun (call, result) ->
      if Hashtbl.mem invalid_args call.id then begin
        Hashtbl.remove invalid_args call.id;
        Some (Error {
          category = Invalid_input "Tool arguments must be a JSON object";
          message = Printf.sprintf
            "Tool '%s' received non-object arguments" call.name;
          retryable = false;
          metadata = [];
        })
      end else
        (* Validate tool result shape *)
        (match result with
         | Success `Null -> None (* null is OK *)
         | Success _ -> None
         | Error _ -> None)
    );

    on_error = None;
  }
