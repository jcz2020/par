open Types

(* Default PII detection patterns.
   Uses Str-compatible syntax (POSIX ERE subset).
   Each pattern is a plain OCaml string with Str escaping. *)

let default_patterns = [
  (* Email addresses *)
  "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z][a-zA-Z]+";
  (* Phone numbers: XXX-XXX-XXXX / XXX.XXX.XXXX / XXXXXXXXXX *)
  "[0-9][0-9][0-9][-.]?[0-9][0-9][0-9][-.]?[0-9][0-9][0-9][0-9]";
  (* SSN: XXX-XX-XXXX *)
  "[0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]";
  (* Credit card: XXXX-XXXX-XXXX-XXXX or XXXX XXXX XXXX XXXX *)
  "[0-9][0-9][0-9][0-9][- ]?[0-9][0-9][0-9][0-9][- ]?[0-9][0-9][0-9][0-9][- ]?[0-9][0-9][0-9][0-9]";
]

(* Replace all PII matches in a string *)
let mask_string (patterns : string list) (replacement : string) (text : string) : string =
  List.fold_left (fun acc pattern ->
    Str.global_replace (Str.regexp pattern) replacement acc
  ) text patterns

(* Recursively mask PII in all string values within a JSON structure *)
let rec mask_json (patterns : string list) (replacement : string) (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `String s -> `String (mask_string patterns replacement s)
  | `List items -> `List (List.map (mask_json patterns replacement) items)
  | `Assoc pairs ->
    `Assoc (List.map (fun (k, v) ->
      (k, mask_json patterns replacement v)
    ) pairs)
  | other -> other

let pii_mask ?(patterns = default_patterns) ?(replacement = "[REDACTED]") () : middleware_hook =
  let mask_text = mask_string patterns replacement in
  let mask_json_val = mask_json patterns replacement in
  {
    name = "pii_mask";

    (* Scan all message content for PII before sending to LLM *)
    on_before_llm = Some (fun conv ->
      let mask_message msg =
        let content = match msg.content with
          | Some text -> Some (mask_text text)
          | None -> None
        in
        { msg with content }
      in
      Some { conv with messages = List.map mask_message conv.messages }
    );

    (* Mask PII in LLM response text (LLM may echo back PII) *)
    on_after_llm = Some (fun resp ->
      match resp.text with
      | Some text ->
        let masked = mask_text text in
        if masked = text then None
        else Some { resp with text = Some masked }
      | None -> None
    );

    (* Mask PII in tool call arguments *)
    on_before_tool = Some (fun call ->
      let masked = mask_json_val call.arguments in
      if masked = call.arguments then None
      else Some { call with arguments = masked }
    );

    (* Mask PII in tool results *)
    on_after_tool = Some (fun (_, result) ->
      let masked_result = match result with
        | Success json ->
          let masked = mask_json_val json in
          if masked = json then result
          else Success masked
        | Error e ->
          let masked_msg = mask_text e.message in
          if masked_msg = e.message then result
          else Error { e with message = masked_msg }
      in
      if masked_result = result then None
      else Some masked_result
    );

    on_error = None;
  }
