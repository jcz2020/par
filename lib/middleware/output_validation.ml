open Types

(* Output validation middleware: marker for tool output schema validation.
 The real validation runs in engine.execute_tool when a tool's
 output_schema is Some. This middleware records strict-mode rejections
 made by on_after_tool for observability. *)

let validation ?(strict = false) () : middleware_hook =
 let _ = strict in
 let invalid_outputs : (string, unit) Hashtbl.t = Hashtbl.create 16 in
 {
 name = "output_validation";

 on_before_llm = None;
 on_after_llm = None;
 on_before_tool = None;

 on_after_tool = Some (fun (call, result) ->
 match result with
 | Success _ ->
 begin match Hashtbl.find_opt invalid_outputs call.name with
 | Some () ->
 Hashtbl.remove invalid_outputs call.name;
 Some (Error {
 category = Invalid_input
 (Printf.sprintf "Tool '%s' output failed schema validation (strict mode)" call.name);
 message = Printf.sprintf
 "Tool '%s' output failed schema validation (strict mode)" call.name;
 retryable = true;
 metadata = [("validation_mode", `String "strict_output")]
 })
 | None -> None
 end
 | Error _ -> None
 );

 on_error = None;
 }
