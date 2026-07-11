(* Implementation of lenient JSON extraction for LLM free-form text. *)

open Yojson.Safe

let try_parse s =
  try Ok (from_string s)
  with Yojson.Json_error _ -> Error "invalid JSON"

(* Strip a single leading ```...``` markdown fence block. The fence opener
   may carry a language hint (```json, ```JSON, ```yaml, etc.) — we still
   strip the fence but later parse attempts will reject non-JSON content. *)
let strip_markdown_fences s =
  let len = String.length s in
  if len < 6 then s
  else if not (String.sub s 0 3 = "```") then s
  else
    match String.index_from_opt s 3 '\n' with
    | None -> s
    | Some newline_idx ->
      let body_start = newline_idx + 1 in
      let rec find_close from =
        if from >= len then None
        else if String.sub s from 3 = "```" then Some from
        else find_close (from + 1)
      in
      match find_close body_start with
      | None -> s
      | Some close_idx ->
        String.sub s body_start (close_idx - body_start)

(* String-aware JSON tokenizer state.

   Tracks nested depth of object/array braces, whether the cursor is
   inside a string literal, and whether the next character is escaped.
   Used to find the closing brace of the outermost container. *)
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

let strip_think_tags s =
  let re_think = Str.regexp "<think>\\([\000-\255]*\\)</think>" in
  let re_reasoning = Str.regexp "<reasoning>\\([\000-\255]*\\)</reasoning>" in
  Str.global_replace re_reasoning "" (Str.global_replace re_think "" s)

let extract_json_from_text s =
  let s = strip_think_tags s in
  let s = String.trim s in
  let s = strip_markdown_fences s in
  let s = String.trim s in
  match try_parse s with
  | Ok json -> Ok json
  | Error _ ->
    match find_balanced_block s with
    | None -> Error "no valid JSON found"
    | Some (lo, hi) ->
      let substr = String.sub s lo (hi - lo + 1) in
      match try_parse substr with
      | Ok json -> Ok json
      | Error _ -> Error "no valid JSON found"
