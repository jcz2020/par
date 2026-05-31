open Types

type sanitize_action =
  [ `Replace of string
  | `Tag
  | `Block ]

type sanitize_config = {
  patterns : string list;
  action : sanitize_action;
}

let default_config : sanitize_config = {
  patterns = [
    "ignore previous";
    "ignore all previous";
    "you are now";
    "system:";
    "new instructions";
    "disregard";
  ];
  action = `Replace "[SANITIZED]";
}

let has_injection_pattern text pattern =
  let lower_text = String.lowercase_ascii text in
  let lower_pat = String.lowercase_ascii pattern in
  try
    ignore (Str.search_forward (Str.regexp_string lower_pat) lower_text 0);
    true
  with Not_found -> false

let contains_injection (patterns : string list) (text : string) : bool =
  List.exists (fun pat -> has_injection_pattern text pat) patterns

let apply_action (patterns : string list) (action : sanitize_action) (text : string)
    : string option =
  match action with
  | `Block -> None
  | `Tag ->
    if contains_injection patterns text then
      Some "[SANITIZED-OUTPUT: prompt injection detected and removed]"
    else Some text
  | `Replace replacement ->
    let result = List.fold_left (fun acc pat ->
      let re = Str.regexp_case_fold (Str.quote pat) in
      Str.global_replace re replacement acc
    ) text patterns in
    Some result

let rec sanitize_json (patterns : string list) (action : sanitize_action)
    (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `String s ->
    (match apply_action patterns action s with
     | Some s' -> `String s'
     | None -> `String "[SANITIZED: blocked by injection filter]")
  | `List items -> `List (List.map (sanitize_json patterns action) items)
  | `Assoc pairs ->
    `Assoc (List.map (fun (k, v) -> (k, sanitize_json patterns action v)) pairs)
  | other -> other

let sanitize_tool_output ?(config = default_config) () : middleware_hook =
  {
    name = "sanitize_tool_output";

    on_before_llm = None;
    on_after_llm = None;
    on_before_tool = None;

    on_after_tool = Some (fun (_call, result) ->
      match result with
      | Success json ->
        let cleaned = sanitize_json config.patterns config.action json in
        if cleaned = json then None
        else Some (Success cleaned)
      | Error err ->
        (match apply_action config.patterns config.action err.message with
         | None ->
           Some (Error { err with
             message = "[SANITIZED: error message blocked by injection filter]" })
         | Some cleaned_msg ->
           if cleaned_msg = err.message then None
           else Some (Error { err with message = cleaned_msg }))
    );

    on_error = None;
  }
