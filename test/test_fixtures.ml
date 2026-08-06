(* test/test_fixtures.ml — shared helpers for portable test fixtures.
   Used by loader tests (text/csv/markdown/html/pdf/docx/directory) and
   the e2e test to avoid hardcoding developer-machine paths and to keep
   each test file's setup boilerplate to one line. *)

(* [create_temp_dir ~prefix] makes a fresh, private (0o700) directory
   under the system temp dir and registers an at_exit cleanup that walks
   and unlinks the tree in pure OCaml (no shell-out). Idempotent on
   EEXIST so PID-recycle collisions in containerized CI do not crash
   module load. *)
let create_temp_dir ~prefix =
  let dir =
    Filename.get_temp_dir_name () ^ "/par_test_" ^ prefix ^ "_"
    ^ string_of_int (Unix.getpid ())
  in
  (try Unix.mkdir dir 0o700
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let rec rm_tree path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> rm_tree (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path
    end else Unix.unlink path
  in
  at_exit (fun () -> (try rm_tree dir with _ -> ()));
  dir

(* [fixtures_dir_or_skip ()] returns the path from $PAR_FIXTURES_DIR, or
   prints a SKIP reason and exits 0 if the variable is unset or points
   at a missing directory. Single-bind pattern — callers must not
   re-read the env var. *)
let fixtures_dir_or_skip () =
  match Sys.getenv_opt "PAR_FIXTURES_DIR" with
  | None ->
    print_endline "[SKIP] Set PAR_FIXTURES_DIR to enable (binary fixture not auto-generated)";
    exit 0
  | Some d when not (Sys.file_exists d) ->
    print_endline ("[SKIP] PAR_FIXTURES_DIR=" ^ d ^ " does not exist");
    exit 0
  | Some d -> d
