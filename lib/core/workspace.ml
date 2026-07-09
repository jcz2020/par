(* Workspace — path-admission authority. Wave 1 (purely additive).

   NOTE: deliberately NOT `open Types`. Doing so imports the [Types.Error]
   record constructor, which shadows stdlib's polymorphic [Result.Error] and
   makes every [Error (Types.Invalid_input ...)] below fail to type-check.
   The same trap is documented in bash_safe_command.ml; we follow that
   discipline and fully qualify [Types.*].

   The [private] modifiers live ONLY in workspace.mli. Here the types are
   concrete so this module can construct them; clients see them as private
   through the interface, which is the load-bearing type-level guarantee
   (a [sandboxed_path] can only originate here, i.e. via a passing [admit]). *)

type workspace_policy = {
  sensitive_prefixes : string list;
}

type workspace = {
  roots : string list;
  policy : workspace_policy;
}

type sandboxed_path = Path of string

(* ----------------- cross-platform path helpers (Wave 2) ---------------- *)

(* Home directory resolution with Windows fallback chain:
   HOME → USERPROFILE → HOMEDRIVE+HOMEPATH. Empty strings are treated as
   unset so that [HOME=""] on a misconfigured shell falls through to the
   next variable rather than producing empty sensitive prefixes. *)
let get_home_dir () =
  let non_empty name =
    match Sys.getenv_opt name with
    | Some s when s <> "" -> Some s
    | _ -> None
  in
  match non_empty "HOME" with
  | Some h -> Some h
  | None ->
    match non_empty "USERPROFILE" with
    | Some u -> Some u
    | None ->
      match (Sys.getenv_opt "HOMEDRIVE", Sys.getenv_opt "HOMEPATH") with
      | (Some d, Some p) -> Some (d ^ p)
      | _ -> None

(* Cross-platform absolute path detection:
   - Unix absolute: starts with ["/"]
   - Windows drive letter: ["C:\\..."] or ["C:/..."]
   - Windows UNC: ["\\\\server\\share..."] *)
let is_absolute_path s =
  if String.length s >= 1 && s.[0] = '/' then true
  else if String.length s >= 3
       && s.[1] = ':'
       && (s.[2] = '\\' || s.[2] = '/')
    then true
  else if String.length s >= 2 && s.[0] = '\\' && s.[1] = '\\'
    then true
  else false

(* Windows-aware colon rejection. The original check rejected ALL colons
   to block shell injection. On Windows, drive letters ([C:\...]) use a
   colon, so we allow it ONLY at position 1 followed by [\] or [/]. Any
   other colon (foo:bar, C:\foo:bar) is still suspicious. *)
let has_suspicious_colon s =
  try
    let idx = String.index s ':' in
    (* Allow drive letter: exactly position 1, followed by \ or / *)
    if idx = 1
       && String.length s > 2
       && (s.[2] = '\\' || s.[2] = '/')
    then begin
      (* Drive letter is fine — but scan the rest for additional colons. *)
      try
        let _ = String.index_from s 2 ':' in
        true  (* found another colon — suspicious *)
      with Not_found -> false
    end
    else true  (* colon not at drive-letter position — suspicious *)
  with Not_found -> false

(* --------------------------- canonicalization --------------------------- *)

(* Lexical fallback when [Unix.realpath] cannot resolve (admit target does
   not exist on disk yet — common for a path that will be created). Drops
   ["."] segments and collapses ["//"]; leaves [".."] untouched because
   [admit] has already rejected any [".."] component upstream, and roots are
   always realpath-resolved (so never contain [".."]).

   Backslash separators are normalized to ["/"] for uniform processing so
   that Windows paths like [C:\Users\foo] canonicalize consistently. The
   drive-letter prefix ([C:]) survives as a path component, and the leading
   absolute marker is preserved. *)
let lexical_normalize p =
  let p = String.map (fun c -> if c = '\\' then '/' else c) p in
  let parts = String.split_on_char '/' p in
  let rec aux acc = function
    | [] -> acc
    | "" :: rest -> aux acc rest
    | "." :: rest -> aux acc rest
    | x :: rest -> aux (x :: acc) rest
  in
  let norm = List.rev (aux [] parts) in
  if String.length p > 0 && p.[0] = '/' then
    "/" ^ String.concat "/" norm
  else match norm with
    | [] -> "."
    | _ -> String.concat "/" norm

let canonicalize p =
  try Unix.realpath p with
  | Not_found -> lexical_normalize p
  | Unix.Unix_error _ -> lexical_normalize p

(* ------------------------------- policy -------------------------------- *)

let absolute_sensitive_prefixes = ["/etc"; "/var"; "/proc"; "/sys"; "/dev"]
let home_sensitive_suffixes = ["/.ssh"; "/.aws"; "/.gnupg"]

(* Faithful port of Bash_safe_command.sensitive_prefixes: the absolute list
   plus, when a home directory is resolved and non-empty, [home/<suffix>]
   for each entry. Trailing slash (or backslash) on home is trimmed.
   Wave 2: home resolution now follows the Windows fallback chain
   (HOME → USERPROFILE → HOMEDRIVE+HOMEPATH) via [get_home_dir]. *)
let default_policy () =
  let abs = absolute_sensitive_prefixes in
  let prefixes =
    match get_home_dir () with
    | None | Some "" -> abs
    | Some home ->
      let home =
        let len = String.length home in
        if len > 0 && (home.[len - 1] = '/' || home.[len - 1] = '\\') then
          String.sub home 0 (len - 1)
        else home
      in
      abs @ List.map (fun s -> home ^ s) home_sensitive_suffixes
  in
  { sensitive_prefixes = prefixes }

let make_policy ~sensitive_prefixes = { sensitive_prefixes }

(* ------------------------------ accessors ------------------------------- *)

let root ws =
  match ws.roots with
  | [] -> assert false
  | r :: _ -> r

let to_string (Path s) = s

(* --------------------------- admit helpers ------------------------------ *)

(* Detects [".."] as a path component on either separator. Backslashes are
   normalized to ["/"] before splitting so that [foo\..] is caught just like
   [foo/..]. This is a security primitive — it must not be bypassable by
   switching separators. *)
let has_parent_component s =
  let normalized = String.map (fun c -> if c = '\\' then '/' else c) s in
  List.exists (fun part -> part = "..") (String.split_on_char '/' normalized)

(* A drive-letter root like ["C:\\"] or ["C:/"] — the Windows equivalent of
   the Unix ["/"] special-case in [is_under]. Used to admit any path on the
   same drive. *)
let is_drive_root s =
  String.length s >= 3
  && s.[1] = ':'
  && (s.[2] = '\\' || s.[2] = '/')
  && String.length s <= 4

(* Boundary-aware containment: [path] is under [root] iff it equals root or
   begins with [root ^ "/"]. The [root = "/"] case admits any absolute path.
   This is the NEW under-root check — boundary-aware so a workspace rooted at
   ["/tmp"] does NOT admit ["/tmp_evil"]. Contrast hits_sensitive_prefix
   below, which is deliberately a bare [starts_with] to match the legacy
   checker's semantics (no semantic drift).

   Wave 2: also handles Windows drive roots ([C:\]) and checks both [/] and
   [\] as boundary separators so that mixed-separator comparisons work. *)
let is_under ~root path =
  if root = "/" then
    String.length path > 0 && path.[0] = '/'
  else if is_drive_root root then
    (* Windows drive root: admit anything starting with the same drive letter. *)
    String.length path >= 2 && path.[0] = root.[0] && path.[1] = ':'
  else
    path = root
    || String.starts_with ~prefix:(root ^ "/") path
    || String.starts_with ~prefix:(root ^ "\\") path

let hits_sensitive_prefix policy path =
  List.exists
    (fun p -> String.starts_with ~prefix:p path)
    policy.sensitive_prefixes

(* ----------------------------- constructors ----------------------------- *)

let of_cwd ?(policy = default_policy ()) () =
  Ok { roots = [canonicalize (Sys.getcwd ())]; policy }

let of_dir ?(policy = default_policy ()) dir =
  if dir = "" then
    Error (Types.Invalid_input "workspace root must not be empty")
  else if not (is_absolute_path dir) then
    Error (Types.Invalid_input
             ("workspace root must be absolute (got: " ^ dir ^ ")"))
  else if not (Sys.file_exists dir) then
    Error (Types.Invalid_input
             ("workspace root does not exist: " ^ dir))
  else
    Ok { roots = [canonicalize dir]; policy }

let of_dirs ?(policy = default_policy ()) dirs =
  match dirs with
  | [] -> Error (Types.Invalid_input "workspace must have at least one root")
  | _ ->
    let rec walk acc = function
      | [] -> Ok (List.rev acc)
      | d :: rest ->
        (match of_dir ~policy d with
         | Error _ as e -> e
         | Ok w ->
           let canonical =
             match w.roots with [x] -> x | _ -> assert false
           in
           if List.mem canonical acc then walk acc rest
           else walk (canonical :: acc) rest)
    in
    match walk [] dirs with
    | Error e -> Error e
    | Ok roots -> Ok { roots; policy }

(* -------------------------------- admit -------------------------------- *)

let admit ws s =
  if has_parent_component s then
    Error (Types.Invalid_input "path contains ..")
  else if has_suspicious_colon s then
    Error (Types.Invalid_input "path contains :")
  else
    let primary = root ws in
    let resolved, was_absolute =
      if is_absolute_path s then (s, true)
      else if s = "" then (primary, false)
      else (Filename.concat primary s, false)
    in
    let canonical = canonicalize resolved in
    let under_root =
      if was_absolute then
        List.exists (fun r -> is_under ~root:r canonical) ws.roots
      else true
    in
    if not under_root then
      Error (Types.Invalid_input "absolute path not under any workspace root")
    else if hits_sensitive_prefix ws.policy canonical then
      Error (Types.Permission_denied canonical)
    else
      Ok (Path canonical)
