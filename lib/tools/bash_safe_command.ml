(* NOTE: deliberately NOT `open Types` — that brings in `handler_result.Error`
   (a record constructor) which shadows stdlib's `Result.Error` of `'e`,
   causing the `Error (Invalid_input "...")` calls below to fail type-checking.
   We use fully-qualified `Types.Invalid_input` / `Types.Permission_denied` instead. *)

type sandboxed_path = Path of string

let absolute_sensitive_prefixes = ["/etc"; "/var"; "/proc"; "/sys"; "/dev"]

let home_sensitive_suffixes = ["/.ssh"; "/.aws"; "/.gnupg"]

let sensitive_prefixes () =
  let abs = absolute_sensitive_prefixes in
  match Sys.getenv_opt "HOME" with
  | None | Some "" -> abs
  | Some home ->
    let home =
      if String.length home > 0 && home.[String.length home - 1] = '/'
      then String.sub home 0 (String.length home - 1)
      else home
    in
    abs @ List.map (fun s -> home ^ s) home_sensitive_suffixes

let has_parent_component s =
  List.exists (fun part -> part = "..") (String.split_on_char '/' s)

let sandboxed_path_of_string s =
  if has_parent_component s then
    Error (Types.Invalid_input "path contains ..")
  else if String.length s > 0 && s.[0] = '/' then
    Error (Types.Invalid_input "absolute path not allowed; must be CWD-relative")
  else if String.contains s ':' then
    Error (Types.Invalid_input "path contains :")
  else
    let joined = Filename.concat (Sys.getcwd ()) s in
    if List.exists (fun p -> String.starts_with ~prefix:p joined) (sensitive_prefixes ()) then
      Error (Types.Permission_denied joined)
    else
      Ok (Path s)

let sandboxed_path_to_string (Path s) = s

let sandboxed_path_cwd () = Path (Sys.getcwd ())

type command =
  | Exec of {
      argv : string list;
      cwd : sandboxed_path;
      env : (string * string) list;
      timeout : float;
    }
  | Pipeline of command list
  | No_op

let make_exec ~argv ?(cwd = sandboxed_path_cwd ()) ?(env = []) ?(timeout = 30.0) () =
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
      ("cwd", `String (sandboxed_path_to_string cwd));
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
