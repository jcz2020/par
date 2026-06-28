(* Tool-prompt rendering and synthesized-call parsing.
   PAR-k38 (T0.5). Pure module — no engine/provider wiring. *)

open Types

(* -------------------------------------------------------------------------- *)
(* Renderer                                                                  *)
(* -------------------------------------------------------------------------- *)

let render_descriptor td =
  let schema_str = Yojson.Safe.pretty_to_string td.input_schema in
  Printf.sprintf "### %s\nDescription: %s\nSchema: %s"
    td.name td.description schema_str

let descriptors_to_prompt_text tools =
  match tools with
  | [] ->
    "## Available Tools\n\n\
     You have access to the following tools. To use a tool, respond with a \
     JSON block:\n\n\
     ```json\n\
     {\"tool_calls\": [{\"name\": \"tool_name\", \"arguments\": {}}]}\n\
     ```\n"
  | _ ->
    let header =
      "## Available Tools\n\n\
       You have access to the following tools. To use a tool, respond with a \
       JSON block:\n\n\
       ```json\n\
       {\"tool_calls\": [{\"name\": \"tool_name\", \"arguments\": {...}}]}\n\
       ```\n"
    in
    let body = String.concat "\n\n" (List.map render_descriptor tools) in
    header ^ "\n\n" ^ body ^ "\n"

(* -------------------------------------------------------------------------- *)
(* Parser                                                                    *)
(* -------------------------------------------------------------------------- *)

(* Empty id — the engine layer (T3.1) assigns a real id when accepting a call. *)
let empty_id = ""

(* String-aware extraction of the first balanced {...} or [...] substring.
   Reused (adapted) from lib/core/json_extract.ml — we keep the behaviour but
   inline it here so this module has no dependency on Json_extract, matching
   the "pure module" constraint of T0.5. *)
type scan_state = {
  mutable depth : int;
  mutable in_string : bool;
  mutable escaped : bool;
}

let scan_to_close s start_char end_char start_idx =
  if start_idx >= String.length s then None
  else if s.[start_idx] <> start_char then None
  else
    let state = { depth = 1; in_string = false; escaped = false } in
    let len = String.length s in
    let rec loop i =
      if i >= len then None
      else if state.depth = 0 then Some (i - 1)
      else
        let c = s.[i] in
        if state.in_string then
          if state.escaped then begin
            state.escaped <- false;
            loop (i + 1)
          end
          else if c = '\\' then begin
            state.escaped <- true;
            loop (i + 1)
          end
          else if c = '"' then begin
            state.in_string <- false;
            loop (i + 1)
          end
          else loop (i + 1)
        else
          if c = '"' then begin
            state.in_string <- true;
            loop (i + 1)
          end
          else if c = start_char then begin
            state.depth <- state.depth + 1;
            loop (i + 1)
          end
          else if c = end_char then begin
            state.depth <- state.depth - 1;
            loop (i + 1)
          end
          else loop (i + 1)
    in
    loop (start_idx + 1)

let find_balanced_block s =
  let len = String.length s in
  let rec scan i =
    if i >= len then None
    else
      let c = s.[i] in
      if c = '{' then
        match scan_to_close s '{' '}' i with
        | Some close_idx -> Some (i, close_idx)
        | None -> scan (i + 1)
      else if c = '[' then
        match scan_to_close s '[' ']' i with
        | Some close_idx -> Some (i, close_idx)
        | None -> scan (i + 1)
      else scan (i + 1)
  in
  scan 0

(* Strip a single ```...``` fence (with or without language tag) if the input
   starts with one. Fence stripping happens before balanced-block search so
   that braces inside the body are not confused with braces inside the fence
   markers. *)
let strip_leading_fence s =
  let s = String.trim s in
  let len = String.length s in
  if len < 6 || String.sub s 0 3 <> "```" then s
  else
    match String.index_from_opt s 3 '\n' with
    | None -> s
    | Some newline_idx ->
      let body_start = newline_idx + 1 in
      let rec find_close from =
        if from + 2 >= len then None
        else if String.sub s from 3 = "```" then Some from
        else find_close (from + 1)
      in
      match find_close body_start with
      | None -> s
      | Some close_idx ->
        String.trim (String.sub s body_start (close_idx - body_start))

let extract_json text =
  let stripped = strip_leading_fence text in
  match Yojson.Safe.from_string stripped with
  | json -> Ok json
  | exception Yojson.Json_error _ ->
    (match find_balanced_block stripped with
     | None -> Error "no JSON object/array found in text"
     | Some (lo, hi) ->
       let substr = String.sub stripped lo (hi - lo + 1) in
       match Yojson.Safe.from_string substr with
       | json -> Ok json
       | exception Yojson.Json_error _ -> Error "balanced block not valid JSON")

let tool_call_of_assoc assoc =
  let open Yojson.Safe.Util in
  match assoc with
  | `Assoc _ -> (
      match member "name" assoc with
      | `String name -> (
          let arguments =
            match member "arguments" assoc with
            | `Null -> `Assoc []
            | v -> v
          in
          Some { id = empty_id; name; arguments })
      | _ -> None)
  | _ -> None

let tool_calls_of_json json =
  let open Yojson.Safe.Util in
  match member "tool_calls" json with
  | `List items ->
    let rec collect acc = function
      | [] -> List.rev acc
      | item :: rest ->
        match tool_call_of_assoc item with
        | Some tc -> collect (tc :: acc) rest
        | None -> collect acc rest
    in
    Ok (collect [] items)
  | `Null -> Ok []
  | _ -> Error "tool_calls: expected array"

let parse_tool_calls_from_text text =
  match extract_json text with
  | Ok json ->
    (match tool_calls_of_json json with
     | Ok calls -> calls
     | Error msg ->
       Logs.warn (fun m ->
         m "Tool_prompt.parse_tool_calls_from_text: %s — returning []" msg);
       [])
  | Error msg ->
    Logs.warn (fun m ->
      m "Tool_prompt.parse_tool_calls_from_text: %s — returning []" msg);
    []