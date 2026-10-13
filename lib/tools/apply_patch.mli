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

val parse_diff : string -> parse_result

val split_lines : string -> string list

val apply :
  read_file:(string -> string option) ->
  file_exists:(string -> bool) ->
  patch_ast ->
  (apply_result, apply_error) result

val write_results :
  write_file:(string -> string -> unit) ->
  (string * string) list ->
  unit

val string_of_apply_error : apply_error -> string

val metadata_code_of_error : apply_error -> string
