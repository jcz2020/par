(* NOTE: deliberately NOT `open Types` — that brings in `handler_result.Error`
   (a record constructor) which shadows stdlib's `Result.Error` of `'e`,
   causing the `Error (Invalid_input "...")` calls below to fail type-checking.
   We use fully-qualified `Types.Invalid_input` / `Types.Permission_denied` instead.

   Wave 3: the [sandboxed_path] type, its validators
   ([sandboxed_path_of_string] / [sandboxed_path_cwd] /
   [sandboxed_path_to_string]), and the [sensitive_prefixes] list have all
   migrated to the [Workspace] module. This file no longer reads [$HOME] or
   [Sys.getcwd] for any security primitive — [Workspace] is the sole
   authority for path admission. The [Exec.cwd] field now references
   [Workspace.sandboxed_path]. *)

type command =
  | Exec of {
      argv : string list;
      cwd : Workspace.sandboxed_path;
      env : (string * string) list;
      timeout : float;
    }
  | Pipeline of command list
  | No_op

let make_exec ~argv ~cwd ?(env = []) ?(timeout = 30.0) () =
  if timeout <= 0.0 then
    invalid_arg "timeout must be > 0"
  else if timeout > 600.0 then
    invalid_arg "timeout exceeds 600s cap"
  else
    Exec { argv; cwd; env; timeout }

let make_pipeline cmds = Pipeline cmds

type risk = Low | Medium | High | Critical

let danger_basenames =
  [ "rm"; "dd"; "mkfs"; "fdisk"; "shutdown"; "reboot"
  ; "chmod"; "chown"; "wipefs"; "mount"; "umount" ]

let classify_argv argv =
  match argv with
  | [] -> Low
  | prog :: _ ->
    let base = Filename.basename prog in
    if List.mem base danger_basenames then High else Low

let assess_risk = function
  | No_op -> Low
  | Exec { argv; timeout; _ } ->
    if timeout > 120.0 then Medium
    else if List.mem "sudo" argv || List.mem "su -" argv then Medium
    else classify_argv argv
  | Pipeline _ -> Medium

let risk_to_string = function
  | Low -> "Low"
  | Medium -> "Medium"
  | High -> "High"
  | Critical -> "Critical"

let max_argv_length = 4096

let validate_argv argv =
  match argv with
  | [] -> Error (Types.Invalid_input "empty argv")
  | _ ->
    let has_nul = List.exists (fun s -> String.contains s '\000') argv in
    if has_nul then
      Error (Types.Invalid_input "NUL byte in argv")
    else if List.length argv > max_argv_length then
      Error (Types.Invalid_input "argv too long")
    else
      Ok ()

let argv_of_command = function
  | Exec { argv; _ } -> argv
  | Pipeline _ -> []
  | No_op -> []

let env_of_command = function
  | Exec { env; _ } -> env
  | Pipeline _ -> []
  | No_op -> []

let rec command_to_string = function
  | No_op -> "<no_op>"
  | Exec { argv; _ } -> String.concat " " argv
  | Pipeline cmds ->
    String.concat " | " (List.map command_to_string cmds)

let rec command_to_yojson cmd : Yojson.Safe.t =
  let argv_json = `List (List.map (fun s -> `String s) (argv_of_command cmd)) in
  let env_json =
    `List
      (List.map
         (fun (k, v) -> `Assoc [("key", `String k); ("value", `String v)])
         (env_of_command cmd))
  in
  let risk_str = risk_to_string (assess_risk cmd) in
  match cmd with
  | No_op ->
    `Assoc [
      ("kind", `String "no_op");
      ("argv", argv_json);
      ("env", env_json);
      ("risk", `String risk_str);
    ]
  | Exec { argv; cwd; env; timeout } ->
    let _ = argv in
    let _ = env in
    `Assoc [
      ("kind", `String "exec");
      ("argv", argv_json);
      ("cwd", `String (Workspace.to_string cwd));
      ("env", env_json);
      ("timeout", `Float timeout);
      ("risk", `String risk_str);
    ]
  | Pipeline cmds ->
    `Assoc [
      ("kind", `String "pipeline");
      ("commands", `List (List.map command_to_yojson cmds));
      ("risk", `String risk_str);
    ]
