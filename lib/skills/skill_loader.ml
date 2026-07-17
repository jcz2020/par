(* lib/skills/skill_loader.ml — Filesystem skill discovery + YAML frontmatter parser.
   No external YAML dependency: the skill.md frontmatter is a flat key-value subset
   that we parse manually (~80 lines). *)

type tool_filter = Types.tool_filter =
  | All_tools
  | Only of string list
  | Except of string list

type skill_trigger = Types.skill_trigger =
  | Auto
  | Manual
  | Keyword of { keywords : string list; llm_confirm : bool }

(* Result helpers — Types has its own Error constructor that shadows Result.Error *)
let (result_ok : 'a -> ('a, 'b) result) = fun x -> Result.Ok x
let (result_err : 'b -> ('a, 'b) result) = fun x -> Result.Error x

(* --- Cache for mtime-based rescanning --- *)
let cached_user_mtime = ref 0.0
let cached_project_mtime = ref 0.0

(* --- Path helpers --- *)
let default_user_skills_dir () =
  match Sys.getenv_opt "HOME" with
  | Some home -> Filename.concat (Filename.concat home ".par") "skills"
  | None -> Filename.concat (Filename.concat (Sys.getcwd ()) ".par") "skills"

let default_project_skills_dir () =
  Filename.concat (Filename.concat (Sys.getcwd ()) ".par") "skills"

(* --- Minimal YAML frontmatter parser ---
    Format: text between two --- lines, each line is "key: value".
    Values can be: null, bare string, [item1, item2], "quoted string".
    Supports YAML block scalars: | (literal), > (folded), with -, + chomping. --- *)

let strip s = String.trim s

let split_on c s =
  let len = String.length s in
  let rec find i =
    if i >= len then None
    else if s.[i] = c then Some i
    else find (i + 1)
  in
  match find 0 with
  | None -> [s]
  | Some idx -> [String.sub s 0 idx; String.sub s (idx + 1) (len - idx - 1)]

(* Parse a YAML list literal: "[a, b, c]" or "[]" → string list *)
let parse_yaml_list s =
  let s = strip s in
  let len = String.length s in
  if len < 2 then []
  else if s.[0] <> '[' || s.[len - 1] <> ']' then []
  else
    let inner = String.sub s 1 (len - 2) in
    if String.length inner = 0 then []
    else
      inner
      |> String.split_on_char ','
      |> List.map (fun x ->
          let x = strip x in
          (* strip quotes *)
          let xlen = String.length x in
          if xlen >= 2 && x.[0] = '"' && x.[xlen - 1] = '"' then
            String.sub x 1 (xlen - 2)
          else x)

(* --- Block scalar support (YAML | and > indicators) --- *)

let is_block_scalar_indicator v =
  match v with
  | "|" | ">" | "|-" | ">-" | "|+" | ">+" -> true
  | _ -> false

let leading_spaces line =
  let n = ref 0 in
  while !n < String.length line && line.[!n] = ' ' do incr n done;
  !n

let rec take_block_lines lines =
  match lines with
  | [] -> ([], [])
  | line :: rest ->
    let s = strip line in
    if s = "" then begin
      let block, remaining = take_block_lines rest in
      (line :: block, remaining)
    end else if String.length line > 0 && line.[0] = ' ' then begin
      let block, remaining = take_block_lines rest in
      (line :: block, remaining)
    end else
      ([], lines)

let render_block_scalar indicator lines =
  let style = if String.contains indicator '|' then `Literal else `Folded in
  let chomp =
    if String.contains indicator '-' then `Strip
    else if String.contains indicator '+' then `Keep
    else `Clip
  in
  let min_indent =
    List.fold_left (fun acc line ->
      let s = strip line in
      if s = "" then acc
      else let ind = leading_spaces line in min acc ind
    ) max_int lines
  in
  let min_indent = if min_indent = max_int then 0 else min_indent in
  let dedented = List.map (fun line ->
    let s = strip line in
    if s = "" then ""
    else
      let ind = leading_spaces line in
      let drop = min ind min_indent in
      String.sub line drop (String.length line - drop)
  ) lines in
  let joined =
    match style with
    | `Literal -> String.concat "\n" dedented
    | `Folded ->
      List.fold_left (fun acc line ->
        let s = strip line in
        match acc, s with
        | "", _ -> s
        | prev, "" -> prev ^ "\n"
        | prev, _ -> prev ^ " " ^ s
      ) "" dedented
  in
  let trim_trailing s =
    let len = String.length s in
    let n = ref (len - 1) in
    while !n >= 0 && (s.[!n] = ' ' || s.[!n] = '\n' || s.[!n] = '\r' || s.[!n] = '\t') do
      decr n
    done;
    String.sub s 0 (!n + 1)
  in
  let content = match chomp with
    | `Strip -> trim_trailing joined
    | `Clip -> trim_trailing joined ^ "\n"
    | `Keep -> joined
  in
  content

(* Parse frontmatter text into (key, raw_value) association list.
   Supports YAML block scalars (| > |- >- |+ >+). *)
let parse_frontmatter_text text =
  let lines = String.split_on_char '\n' text in
  let rec parse acc = function
    | [] -> List.rev acc
    | line :: rest ->
      let stripped = strip line in
      if stripped = "" || stripped.[0] = '#' then
        parse acc rest
      else
        match split_on ':' stripped with
        | [key; value] ->
          let k = strip key in
          let v = strip value in
          if k = "" then parse acc rest
          else if is_block_scalar_indicator v then begin
            let block_lines, remaining = take_block_lines rest in
            let block_value = render_block_scalar v block_lines in
            parse ((k, block_value) :: acc) remaining
          end else
            parse ((k, v) :: acc) rest
        | _ -> parse acc rest
  in
  parse [] lines

(* Parse tool_filter from raw value string *)
let parse_tool_filter s =
  let s = strip s in
  if s = "All" || s = "All_tools" || s = "" then result_ok All_tools
  else if String.length s >= 5 && String.sub s 0 5 = "Only " then
    let rest = strip (String.sub s 5 (String.length s - 5)) in
    result_ok (Only (parse_yaml_list rest))
  else if String.length s >= 7 && String.sub s 0 7 = "Except " then
    let rest = strip (String.sub s 7 (String.length s - 7)) in
    result_ok (Except (parse_yaml_list rest))
  else if String.length s >= 4 && String.sub s 0 4 = "Only" then
    let rest = strip (String.sub s 4 (String.length s - 4)) in
    result_ok (Only (parse_yaml_list rest))
  else if String.length s >= 6 && String.sub s 0 6 = "Except" then
    let rest = strip (String.sub s 6 (String.length s - 6)) in
    result_ok (Except (parse_yaml_list rest))
  else result_err (Printf.sprintf "Invalid tool_filter: %s" s)

(* Parse skill_trigger from raw value string *)
let parse_trigger s =
  let s = strip s in
  if s = "Auto" || s = "auto" then result_ok Auto
  else if s = "Manual" || s = "manual" then result_ok Manual
  else if String.length s >= 7 && String.sub s 0 7 = "Keyword" then
    let rest = strip (String.sub s 7 (String.length s - 7)) in
    let bracket_close =
      try Some (String.index rest ']')
      with Not_found -> None
    in
    (match bracket_close with
     | None ->
       result_ok (Keyword { keywords = parse_yaml_list rest; llm_confirm = true })
     | Some idx ->
       let list_str = String.sub rest 0 (idx + 1) in
       let keywords = parse_yaml_list list_str in
       let after = strip (String.sub rest (idx + 1) (String.length rest - idx - 1)) in
       let llm_confirm =
         if after = "deterministic" || after = "no-confirm" || after = "false" then false
         else true
       in
       result_ok (Keyword { keywords; llm_confirm }))
  else result_err (Printf.sprintf "Invalid trigger: %s" s)

(* Parse a nullable value: "null" → None, other → Some string *)
let parse_nullable s =
  let stripped = strip s in
  if stripped = "null" || stripped = "None" || stripped = "" then None
  else
    let len = String.length stripped in
    if len >= 2 && stripped.[0] = '"' && stripped.[len - 1] = '"' then
      Some (String.sub stripped 1 (len - 2))
    else Some s

(* Parse expected_output: null → None, other → parse as JSON *)
let parse_expected_output s =
  let s = strip s in
  if s = "null" || s = "None" || s = "" then Ok None
  else
    try Ok (Some (Yojson.Safe.from_string s))
    with Yojson.Json_error msg -> Error (Printf.sprintf "Invalid JSON for expected_output: %s" msg)

let lookup key alist =
  try Some (List.assoc key alist)
  with Not_found -> None

(* Parse a complete skill.md file path into skill_descriptor *)
let parse_skill_file ~path : (Types.skill_descriptor, string) result =
  match
    try Ok (Stdlib.open_in path)
    with Sys_error msg -> Error (Printf.sprintf "Cannot open %s: %s" path msg)
  with
  | Error e -> Error e
  | Ok ic ->
    let content = really_input_string ic (in_channel_length ic) in
    close_in ic;
    (* Split frontmatter from body: first --- ... second ---.
       Don't strip lines — indentation is needed for block scalar parsing. *)
    let lines = String.split_on_char '\n' content in
    let rec extract_frontmatter acc state = function
      | [] -> (List.rev acc, None)
      | line :: rest ->
        (match state with
         | `Before ->
           if strip line = "---" then extract_frontmatter acc `In_frontmatter rest
           else extract_frontmatter acc `Before rest
         | `In_frontmatter ->
           if strip line = "---" then (List.rev acc, Some rest)
           else extract_frontmatter (line :: acc) `In_frontmatter rest)
    in
    let frontmatter_lines, _body = extract_frontmatter [] `Before lines in
    let fm = parse_frontmatter_text (String.concat "\n" frontmatter_lines) in
    (* Required fields *)
    let schema_version =
      match lookup "schema_version" fm with
      | None -> Error "Missing required field: schema_version"
      | Some v ->
        (try Ok (int_of_string (strip v))
         with Failure _ -> Error (Printf.sprintf "Invalid schema_version: %s" v))
    in
    let id = match lookup "id" fm with
      | None -> Error "Missing required field: id"
      | Some v -> Ok (strip v)
    in
    let name = match lookup "name" fm with
      | None -> Error "Missing required field: name"
      | Some v -> Ok (strip v)
    in
    let description = match lookup "description" fm with
      | None -> Error "Missing required field: description"
      | Some v -> Ok (strip v)
    in
    match schema_version, id, name, description with
    | Error e, _, _, _ | _, Error e, _, _ | _, _, Error e, _ | _, _, _, Error e -> Error e
    | Ok sv, Ok id_v, Ok name_v, Ok desc_v ->
      (* Validate schema_version *)
      if sv <> 1 then
        Error (Printf.sprintf "Unsupported schema_version %d (expected 1). See MIGRATION.md." sv)
      else
        (* Validate description length *)
        if String.length desc_v > 1024 then
          Error (Printf.sprintf "description exceeds 1024 chars (%d)" (String.length desc_v))
        else
          let system_prompt_override = parse_nullable (Option.value (lookup "system_prompt_override" fm) ~default:"null") in
          let tool_filter =
            match lookup "tool_filter" fm with
            | None -> All_tools
            | Some v ->
              (match parse_tool_filter v with
               | Ok tf -> tf
               | Error _ -> All_tools)  (* default on parse error *)
          in
          let trigger =
            match lookup "trigger" fm with
            | None -> Auto  (* default *)
            | Some v ->
              (match parse_trigger v with
               | Ok t -> t
               | Error _ -> Auto)  (* default on parse error *)
          in
          let expected_output =
            match lookup "expected_output" fm with
            | None -> None
            | Some v ->
              (match parse_expected_output v with
               | Ok eo -> eo
               | Error _ -> None)
          in
      Result.Ok {
        schema_version = sv;
          id = id_v;
          name = name_v;
          description = desc_v;
          system_prompt_override = Option.map (fun s -> Types.Stable_prompt s) system_prompt_override;
          tool_filter;
          trigger;
          expected_output;
          body_path = path;
        }

(* --- Filesystem discovery --- *)
let scan_skills_dir dir =
  try
    let entries = Sys.readdir dir in
    Array.to_list entries
    |> List.filter (fun entry ->
         let full = Filename.concat dir entry in
         Sys.is_directory full)
    |> List.filter_map (fun entry ->
         let skill_md = Filename.concat (Filename.concat dir entry) "skill.md" in
         if Sys.file_exists skill_md then
           match parse_skill_file ~path:skill_md with
           | Ok desc -> Some desc
           | Error e ->
             Logs.warn (fun m -> m "Skill_loader: skipping %s: %s" skill_md e);
             None
         else None)
  with Sys_error _ -> []  (* directory doesn't exist *)

let discover ?(user_dir : string option) ?(project_dir : string option) () : Types.skill_descriptor list =
  let open Types in
  let udir = Option.value user_dir ~default:(default_user_skills_dir ()) in
  let pdir = Option.value project_dir ~default:(default_project_skills_dir ()) in
  let user_skills = scan_skills_dir udir in
  let project_skills = scan_skills_dir pdir in
  (* Precedence: project > user. Deduplicate by id. *)
  let project_ids = List.map (fun (s : Types.skill_descriptor) -> s.id) project_skills in
  let user_skills_filtered = List.filter (fun (s : Types.skill_descriptor) -> not (List.mem s.id project_ids)) user_skills in
  project_skills @ user_skills_filtered

let dir_mtime dir =
  try Unix.stat dir |> fun st -> st.Unix.st_mtime
  with Unix.Unix_error _ | Sys_error _ -> 0.0

let mtime_scan_needed ?(user_dir : string option) ?(project_dir : string option) () : bool =
  let udir = Option.value user_dir ~default:(default_user_skills_dir ()) in
  let pdir = Option.value project_dir ~default:(default_project_skills_dir ()) in
  let u_mtime = dir_mtime udir in
  let p_mtime = dir_mtime pdir in
  u_mtime <> !cached_user_mtime || p_mtime <> !cached_project_mtime

let update_mtime_cache ?(user_dir : string option) ?(project_dir : string option) () =
  let udir = Option.value user_dir ~default:(default_user_skills_dir ()) in
  let pdir = Option.value project_dir ~default:(default_project_skills_dir ()) in
  cached_user_mtime := dir_mtime udir;
  cached_project_mtime := dir_mtime pdir

let force_reload () =
  cached_user_mtime := 0.0;
  cached_project_mtime := 0.0
