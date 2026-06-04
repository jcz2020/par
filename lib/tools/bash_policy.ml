(* lib/tools/bash_policy.ml — v0.3.1
   Trust boundary for the bash tool. Decides allow / modify / reject.
   Pure data + pure functions. No IO, no processes, no exceptions. *)

open Types
open Bash_safe_command

(* OCaml limitation: module types declared in the .mli are not in scope
   of the .ml. We redeclare POLICY here so the policy implementations
   can reference it. The .mli remains the public contract. *)
module type POLICY = sig
  val name : string
  val filter :
    command -> (command, Types.error_category) result
  val max_cpu_seconds : float
  val max_memory_kb : int
  val allow_network : bool
  val allow_write : bool
end

(* -------------------------------------------------------------------------- *)
(* sanitize_env                                                              *)
(* -------------------------------------------------------------------------- *)

(* Always kept, regardless of pattern match. *)
let always_keep = [
  "PATH"; "HOME"; "LANG"; "LC_ALL"; "TZ"; "USER"; "LOGNAME";
  "SHELL"; "TMPDIR"; "PWD"; "OLDPWD";
]

(* Exact-match always-stripped, regardless of value. *)
let always_strip_exact = [
  "AWS_ACCESS_KEY_ID"; "AWS_SECRET_ACCESS_KEY"; "AWS_SESSION_TOKEN";
  "AWS_PROFILE"; "AWS_REGION"; "AWS_DEFAULT_REGION";
  "AZURE_CLIENT_ID"; "AZURE_CLIENT_SECRET"; "AZURE_TENANT_ID";
  "AZURE_SUBSCRIPTION_ID"; "AZURE_FEDERATED_TOKEN_FILE";
  "GCP_PROJECT"; "GCP_SERVICE_ACCOUNT";
  "GOOGLE_APPLICATION_CREDENTIALS";
  "OPENAI_API_KEY";
  "ANTHROPIC_API_KEY";
  "GITHUB_TOKEN";
  "GITLAB_TOKEN";
  "SLACK_TOKEN";
  "HF_TOKEN";
  "HUGGINGFACE_TOKEN";
]

let secret_pattern_re = Str.regexp_case_fold ".*\\(secret\\|key\\|token\\|password\\|credential\\).*"

let prefix_drop_re = Str.regexp "^[Aa][Ww][Ss]_\\|^[Aa][Zz][Uu][Rr][Ee]_\\|^[Gg][Cc][Pp]_\\|^[Gg][Oo][Oo][Gg][Ll][Ee]_"

(* Drop if: (a) matches secret substring pattern, OR
            (b) starts with AWS_/AZURE_/GCP_/GOOGLE_ prefix.
   Also always drop exact matches in [always_strip_exact]. *)
let is_secret_key key =
  if List.mem key always_keep then false
  else if List.mem key always_strip_exact then true
  else
    let stripped = Str.global_replace prefix_drop_re "" key in
    if stripped <> key then true
    else
      try
        ignore (Str.search_forward secret_pattern_re key 0);
        true
      with Not_found -> false

(* Output is sorted for determinism. *)
let sanitize_env env =
  let kept = List.filter (fun (k, _) -> not (is_secret_key k)) env in
  List.sort (fun (a, _) (b, _) -> String.compare a b) kept

(* -------------------------------------------------------------------------- *)
(* strip_ansi                                                                *)
(* -------------------------------------------------------------------------- *)

let ansi_re = Str.regexp "\027\\[[0-9;?]*[a-zA-Z]\\|\027\\][^\007]*\007\\|\027[=>]"

let strip_ansi s =
  Str.global_replace ansi_re "" s

(* -------------------------------------------------------------------------- *)
(* truncate_output                                                           *)
(* -------------------------------------------------------------------------- *)

let truncate_output ~max_bytes ~max_lines s =
  let len = String.length s in
  let newline_re = Str.regexp "\n" in
  let lines_arr = Str.split newline_re s in
  let lines_count = List.length lines_arr in
  if len <= max_bytes && lines_count <= max_lines then
    (s, false)
  else begin
    let byte_limited =
      if len > max_bytes then String.sub s 0 max_bytes
      else s
    in
    let lines2 = Str.split newline_re byte_limited in
    let line_limited_str =
      if List.length lines2 > max_lines then
        String.concat "\n" (List.filteri (fun i _ -> i < max_lines) lines2)
      else byte_limited
    in
    let bytes_omitted = len - String.length line_limited_str in
    let lines_omitted = lines_count - max_lines in
    let marker = Printf.sprintf "\n[truncated: %d bytes / %d lines omitted]"
      (if bytes_omitted < 0 then 0 else bytes_omitted)
      (if lines_omitted < 0 then 0 else lines_omitted)
    in
    (line_limited_str ^ marker, true)
  end

(* -------------------------------------------------------------------------- *)
(* Policy predicates                                                         *)
(* -------------------------------------------------------------------------- *)

(* Use Filename.basename so "/bin/rm" matches the same as "rm". *)
let argv0_basename argv =
  match argv with
  | [] -> ""
  | prog :: _ -> Filename.basename prog

(* Tools that can mutate the filesystem. The v0.3.1 simplification:
   any invocation of these basenames is rejected by ReadOnly, regardless
   of argv tail. *)
let write_tools = [
  "rm"; "mv"; "cp"; "chmod"; "chown"; "write"; "tee";
  "dd"; "mount"; "umount"; "install";
  "apt"; "pip"; "npm"; "cargo"; "make";
  "touch"; "mkdir"; "rmdir"; "ln";
  "truncate"; "shred";
  "sed";  (* sed -i is the actual risk; v0.3.1 rejects all sed *)
]

(* Tools that talk to the network. *)
let network_tools = [
  "curl"; "wget"; "nc"; "ssh"; "scp"; "rsync";
  "ping"; "traceroute"; "nslookup"; "dig"; "host";
  "ftp"; "telnet"; "fetch"; "http";
]

let url_re = Str.regexp "https?://\\|ftp://"

let argv_contains_url argv =
  List.exists (fun s ->
    try
      ignore (Str.search_forward url_re s 0);
      true
    with Not_found -> false
  ) argv

let argv0_in_set set argv =
  let base = argv0_basename argv in
  base <> "" && List.mem base set

let is_write_tool argv = argv0_in_set write_tools argv
let is_network_tool argv = argv0_in_set network_tools argv

(* -------------------------------------------------------------------------- *)
(* POLICY: ReadOnly                                                          *)
(* -------------------------------------------------------------------------- *)

module ReadOnly : POLICY = struct
  let name = "ReadOnly"
  let max_cpu_seconds = 30.0
  let max_memory_kb = 262144  (* 256 MB *)
  let allow_network = true
  let allow_write = false

  let rec filter = function
    | No_op -> Ok No_op
    | Pipeline cmds ->
      (match cmds with
       | [] -> Ok (Pipeline [])
       | first :: _ ->
         match filter first with
         | Ok _ -> Ok (Pipeline cmds)
         | Error e -> Error e)
    | Exec { argv; cwd; env; timeout } ->
      if argv = [] then
        Error (Invalid_input "empty argv")
      else if env <> [] then
        Error (Permission_denied "ReadOnly: cannot set env vars")
      else if is_write_tool argv then
        let tool = argv0_basename argv in
        Error (Permission_denied (Printf.sprintf "ReadOnly: %s not allowed" tool))
      else
        Ok (Exec { argv; cwd; env = sanitize_env env; timeout })
end

(* -------------------------------------------------------------------------- *)
(* POLICY: ReadOnlyNoNet                                                     *)
(* -------------------------------------------------------------------------- *)

module ReadOnlyNoNet : POLICY = struct
  let name = "ReadOnlyNoNet"
  let max_cpu_seconds = 30.0
  let max_memory_kb = 262144
  let allow_network = false
  let allow_write = false

  let rec filter = function
    | No_op -> Ok No_op
    | Pipeline cmds ->
      (match cmds with
       | [] -> Ok (Pipeline [])
       | first :: _ ->
         match filter first with
         | Ok _ -> Ok (Pipeline cmds)
         | Error e -> Error e)
    | Exec { argv; cwd; env; timeout } ->
      if argv = [] then
        Error (Invalid_input "empty argv")
      else if env <> [] then
        Error (Permission_denied "ReadOnlyNoNet: cannot set env vars")
      else if is_write_tool argv then
        let tool = argv0_basename argv in
        Error (Permission_denied (Printf.sprintf "ReadOnlyNoNet: %s not allowed" tool))
      else if is_network_tool argv then
        let tool = argv0_basename argv in
        Error (Permission_denied (Printf.sprintf "ReadOnlyNoNet: %s not allowed (network)" tool))
      else if argv_contains_url argv then
        Error (Permission_denied "ReadOnlyNoNet: URL not allowed in argv")
      else
        Ok (Exec { argv; cwd; env = sanitize_env env; timeout })
end

(* -------------------------------------------------------------------------- *)
(* POLICY: Coder                                                             *)
(* -------------------------------------------------------------------------- *)

module Coder : POLICY = struct
  let name = "Coder"
  let max_cpu_seconds = 60.0
  let max_memory_kb = 524288  (* 512 MB *)
  let allow_network = true
  let allow_write = true

  let rec filter = function
    | No_op -> Ok No_op
    | Pipeline cmds ->
      (match cmds with
       | [] -> Ok (Pipeline [])
       | first :: _ ->
         match filter first with
         | Ok _ -> Ok (Pipeline cmds)
         | Error e -> Error e)
    | Exec { argv; cwd; env; timeout } ->
      let hits = Bash_blacklist.matches ~argv in
      match hits with
      | _ :: _ ->
        let names = String.concat ", " (Bash_blacklist.names_of hits) in
        Error (Permission_denied (Printf.sprintf "Blacklist: %s" names))
      | [] ->
        Ok (Exec { argv; cwd; env = sanitize_env env; timeout })
end
