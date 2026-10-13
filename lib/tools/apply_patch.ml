type diff_line =
  | Context of string
  | Added   of string
  | Removed of string

type hunk = {
  old_start  : int;
  old_count  : int;
  new_start  : int;
  new_count  : int;
  lines      : diff_line list;
}

type file_patch = {
  old_path   : string;
  new_path   : string;
  hunks      : hunk list;
  is_binary  : bool;
  is_new     : bool;
  is_deleted : bool;
}

type patch_ast = file_patch list

type parse_error = {
  message  : string;
  line_num : int;
}

type parse_result = (patch_ast, parse_error) result

type apply_error =
  | Context_mismatch of {
      file     : string;
      hunk_idx : int;
      expected : string;
      got      : string option;
      declared : int;
    }
  | File_not_found of string
  | File_already_exists of string

type apply_report = {
  files_changed : int;
  hunks_applied : int;
  insertions    : int;
  deletions     : int;
  skipped_binary : string list;
}

type apply_result = {
  report  : apply_report;
  staged  : (string * string) list;
}

let starts_with_prefix s prefix =
  let sl = String.length s and pl = String.length prefix in
  sl >= pl && String.sub s 0 pl = prefix

let strip_timestamp path =
  match String.index_opt path '\t' with
  | Some i -> String.sub path 0 i
  | None   -> path

let parse_file_path line prefix =
  let pl = String.length prefix in
  let rest = String.sub line pl (String.length line - pl) |> strip_timestamp |> String.trim in
  if rest = "/dev/null" then ""
  else if String.length rest >= 2 && rest.[0] = '"' && rest.[String.length rest - 1] = '"' then
    String.sub rest 1 (String.length rest - 2)
  else if String.length rest >= 2 && rest.[0] = 'a' && rest.[1] = '/' then
    String.sub rest 2 (String.length rest - 2)
  else if String.length rest >= 2 && rest.[0] = 'b' && rest.[1] = '/' then
    String.sub rest 2 (String.length rest - 2)
  else rest

let split_lines text =
  if text = "" then []
  else
    match List.rev (String.split_on_char '\n' text) with
    | "" :: rest -> List.rev rest
    | parts      -> List.rev parts

let parse_hunk_header line =
  try
    let i = ref 0 in
    let s = line in
    let len = String.length s in
    while !i < len && s.[!i] <> '-' do incr i done;
    if !i >= len then None
    else begin
      incr i;
      let os = ref "" in
      while !i < len && s.[!i] >= '0' && s.[!i] <= '9' do
        os := !os ^ String.make 1 s.[!i]; incr i
      done;
      let oc = ref "1" in
      if !i < len && s.[!i] = ',' then begin
        incr i; oc := "";
        while !i < len && s.[!i] >= '0' && s.[!i] <= '9' do
          oc := !oc ^ String.make 1 s.[!i]; incr i
        done
      end;
      while !i < len && s.[!i] <> '+' do incr i done;
      if !i >= len then None
      else begin
        incr i;
        let ns = ref "" in
        while !i < len && s.[!i] >= '0' && s.[!i] <= '9' do
          ns := !ns ^ String.make 1 s.[!i]; incr i
        done;
        let nc = ref "1" in
        if !i < len && s.[!i] = ',' then begin
          incr i; nc := "";
          while !i < len && s.[!i] >= '0' && s.[!i] <= '9' do
            nc := !nc ^ String.make 1 s.[!i]; incr i
          done
        end;
        if !os = "" || !ns = "" then None
        else
          Some (int_of_string !os, int_of_string !oc,
                int_of_string !ns, int_of_string !nc)
      end
    end
  with _ -> None

let parse_diff text : parse_result =
  let raw_lines = split_lines text in
  let lines = List.filter (fun s -> s <> "\\ No newline at end of file") raw_lines in
  if lines = [] then
    Error { message = "Empty patch: no diff content found"; line_num = 0 }
  else
    let len = List.length lines in
    let result_files = ref [] in
    let parse_err = ref None in
    let i = ref 0 in
    while !i < len && !parse_err = None do
      let line = List.nth lines !i in
      if starts_with_prefix line "Binary files " then begin
        let rest = String.sub line 13 (String.length line - 13) in
        let path = (match String.index_opt rest ' ' with
          | Some j -> String.sub rest 0 j
          | None -> rest) in
        let path = if String.length path >= 2 && path.[0] = 'a' && path.[1] = '/'
          then String.sub path 2 (String.length path - 2) else path in
        result_files := {
          old_path = path; new_path = path;
          hunks = []; is_binary = true; is_new = false; is_deleted = false;
        } :: !result_files;
        incr i
      end else if starts_with_prefix line "--- " then begin
        if !i + 1 >= len then
          parse_err := Some { message = "Missing '+++ ' after '--- '"; line_num = !i + 2 }
        else begin
          let next = List.nth lines (!i + 1) in
          if not (starts_with_prefix next "+++ ") then
            parse_err := Some { message = "Expected '+++ ' after '--- '"; line_num = !i + 2 }
          else begin
            let old_path = parse_file_path line "--- " in
            let new_path = parse_file_path next "+++ " in
            let is_new = old_path = "" in
            let is_deleted = new_path = "" in
            let actual_path = if new_path <> "" then new_path else old_path in
            let hunks = ref [] in
            let is_binary = ref false in
            i := !i + 2;
            let file_done = ref false in
            while !i < len && not !file_done && !parse_err = None do
              let hline = List.nth lines !i in
              if starts_with_prefix hline "--- " then
                file_done := true
              else if starts_with_prefix hline "Binary files" ||
                      starts_with_prefix hline "GIT binary patch" then begin
                is_binary := true;
                incr i;
                while !i < len && not (starts_with_prefix (List.nth lines !i) "--- ") do
                  incr i
                done;
                file_done := true
              end else if starts_with_prefix hline "@@" then begin
                match parse_hunk_header hline with
                | None ->
                  parse_err := Some {
                    message = Printf.sprintf "Malformed hunk header: %s" hline;
                    line_num = !i + 1
                  }
                | Some (os, oc, ns, nc) ->
                  incr i;
                  let hunk_lines = ref [] in
                  let hunk_done = ref false in
                  while !i < len && not !hunk_done do
                    let dl = List.nth lines !i in
                    if String.length dl > 0 &&
                       (dl.[0] = ' ' || dl.[0] = '+' || dl.[0] = '-') then begin
                      let kind =
                        if dl.[0] = '+' then Added (String.sub dl 1 (String.length dl - 1))
                        else if dl.[0] = '-' then Removed (String.sub dl 1 (String.length dl - 1))
                        else Context (String.sub dl 1 (String.length dl - 1))
                      in
                      hunk_lines := kind :: !hunk_lines;
                      incr i
                    end else
                      hunk_done := true
                  done;
                  hunks := { old_start = os; old_count = oc;
                             new_start = ns; new_count = nc;
                             lines = List.rev !hunk_lines } :: !hunks
              end else
                incr i
            done;
            if !parse_err = None then
              result_files := {
                old_path; new_path = actual_path;
                hunks = List.rev !hunks;
                is_binary = !is_binary; is_new; is_deleted;
              } :: !result_files
          end
        end
      end else
        incr i
    done;
    match !parse_err with
    | Some e -> Error e
    | None   -> Ok (List.rev !result_files)

let find_hunk_start file_lines hunk =
  let total = List.length file_lines in
  let declared = hunk.old_start in
  let context_lines =
    List.filter_map (function
      | Context s | Removed s -> Some s
      | Added _ -> None
    ) hunk.lines
  in
  if context_lines = [] then
    if declared >= 1 && declared <= total + 1 then Ok declared
    else Ok 1
  else
    let ctx_len = List.length context_lines in
    let match_at pos =
      if pos < 1 || pos - 1 + ctx_len > total then false
      else
        let ok = ref true in
        let idx = ref 0 in
        while !ok && !idx < ctx_len do
          if List.nth context_lines !idx <> List.nth file_lines (pos - 1 + !idx) then
            ok := false;
          incr idx
        done;
        !ok
    in
    if match_at declared then Ok declared
    else
      let max_offset = 60 in
      let found = ref None in
      let offset = ref 1 in
      while !found = None && !offset <= max_offset do
        if match_at (declared + !offset) then
          found := Some (declared + !offset)
        else if match_at (declared - !offset) then
          found := Some (declared - !offset);
        incr offset
      done;
      match !found with
      | Some pos -> Ok pos
      | None ->
        Error (Context_mismatch {
          file = ""; hunk_idx = 0;
          expected = List.hd context_lines;
          got = (if declared >= 1 && declared <= total
                 then Some (List.nth file_lines (declared - 1))
                 else None);
          declared;
        })

let apply_single_hunk file_lines hunk =
  match find_hunk_start file_lines hunk with
  | Error e -> Error e
  | Ok start ->
    let pos = ref (start - 1) in
    let result = ref [] in
    let total = List.length file_lines in
    let err = ref None in
    List.iter (fun line ->
      if !err = None then
        match line with
        | Context expected ->
          if !pos < total && List.nth file_lines !pos = expected then begin
            result := expected :: !result;
            incr pos
          end else
            err := Some (Context_mismatch {
              file = ""; hunk_idx = 0; expected;
              got = (if !pos < total then Some (List.nth file_lines !pos) else None);
              declared = hunk.old_start;
            })
        | Removed expected ->
          if !pos < total && List.nth file_lines !pos = expected then
            incr pos
          else
            err := Some (Context_mismatch {
              file = ""; hunk_idx = 0; expected;
              got = (if !pos < total then Some (List.nth file_lines !pos) else None);
              declared = hunk.old_start;
            })
        | Added content ->
          result := content :: !result
    ) hunk.lines;
    match !err with
    | Some e -> Error e
    | None ->
      let remaining = ref [] in
      for k = !pos to total - 1 do
        remaining := List.nth file_lines k :: !remaining
      done;
      Ok (List.rev !result @ List.rev !remaining)

let apply_hunks file_lines hunks =
  let current = ref file_lines in
  let applied = ref 0 in
  let ins = ref 0 in
  let del = ref 0 in
  let err = ref None in
  let idx = ref 0 in
  List.iter (fun hunk ->
    if !err = None then begin
      (match apply_single_hunk !current hunk with
       | Ok new_lines ->
         current := new_lines;
         incr applied;
         List.iter (function
           | Added _ -> incr ins
           | Removed _ -> incr del
           | _ -> ()
         ) hunk.lines
       | Error (Context_mismatch r) ->
         err := Some (Context_mismatch { r with hunk_idx = !idx })
       | Error e -> err := Some e);
      incr idx
    end
  ) hunks;
  match !err with
  | Some e -> Error e
  | None   -> Ok (!current, !applied, !ins, !del)

let apply
    ~(read_file : string -> string option)
    ~(file_exists : string -> bool)
    (patches : patch_ast) : (apply_result, apply_error) result =
  let binary_skipped = ref [] in
  let file_data : (string * string list * file_patch) list ref = ref [] in
  let stop = ref false in
  let stop_err = ref None in
  List.iter (fun fp ->
    if not !stop then begin
      let path = if fp.new_path <> "" then fp.new_path else fp.old_path in
      if fp.is_binary then
        binary_skipped := path :: !binary_skipped
      else if fp.is_new then begin
        if file_exists path then begin
          stop := true;
          stop_err := Some (File_already_exists path)
        end else
          file_data := (path, [], fp) :: !file_data
      end else begin
        match read_file path with
        | None ->
          stop := true;
          stop_err := Some (File_not_found path)
        | Some content ->
          file_data := (path, split_lines content, fp) :: !file_data
      end
    end
  ) patches;
  if !stop then
    Error (match !stop_err with Some e -> e | None -> assert false)
  else begin
    let results : (string * string) list ref = ref [] in
    let total_hunks = ref 0 in
    let total_ins = ref 0 in
    let total_del = ref 0 in
    let apply_ok = ref true in
    let apply_err = ref None in
    List.iter (fun (path, orig_lines, fp) ->
      if !apply_ok then begin
        if fp.hunks = [] then
          results := (path, String.concat "\n" orig_lines) :: !results
        else begin
          match apply_hunks orig_lines fp.hunks with
          | Ok (new_lines, applied, ins, del) ->
            total_hunks := !total_hunks + applied;
            total_ins := !total_ins + ins;
            total_del := !total_del + del;
            results := (path, String.concat "\n" new_lines) :: !results
          | Error (Context_mismatch r) ->
            apply_ok := false;
            apply_err := Some (Context_mismatch { r with file = path })
          | Error e ->
            apply_ok := false;
            apply_err := Some e
        end
      end
    ) (List.rev !file_data);
    if not !apply_ok then
      Error (match !apply_err with Some e -> e | None -> assert false)
    else begin
      let n_files =
        List.length !results +
        List.length (List.filter (fun fp -> fp.is_deleted && not fp.is_binary) patches)
      in
      Ok {
        report = {
          files_changed = n_files;
          hunks_applied = !total_hunks;
          insertions = !total_ins;
          deletions = !total_del;
          skipped_binary = List.rev !binary_skipped;
        };
        staged = !results;
      }
    end
  end

let write_results ~(write_file : string -> string -> unit) results =
  List.iter (fun (path, content) -> write_file path content) results

let string_of_apply_error = function
  | Context_mismatch { file; hunk_idx; expected; got; declared } ->
    let got_s = match got with Some s -> Printf.sprintf "'%s'" s | None -> "end of file" in
    Printf.sprintf
      "%s Context mismatch in '%s' at hunk %d (declared line %d): \
       expected '%s', got %s. \
       The file may have changed. Read the file first, then generate a fresh patch."
      Tool_error.patch_marker file (hunk_idx + 1) declared expected got_s
  | File_not_found path ->
    Printf.sprintf
      "%s File not found: '%s'. \
       Check the path in your --- header matches an existing file."
      Tool_error.patch_marker path
  | File_already_exists path ->
    Printf.sprintf
      "%s File already exists: '%s'. \
       Cannot create a new file that already exists. \
       Use a modification patch (--- a/path) instead."
      Tool_error.patch_marker path

let metadata_code_of_error = function
  | Context_mismatch _ -> "patch_context_mismatch"
  | File_not_found _   -> "patch_file_not_found"
  | File_already_exists _ -> "patch_file_already_exists"
