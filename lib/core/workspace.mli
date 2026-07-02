(** Workspace abstraction — the sole authority for path admission.

    Wave 1 of the path-admission refactor. This module is a purely additive
    replacement target for [Bash_safe_command.sandboxed_path_of_string] and
    exiles [Sys.getcwd] from every security primitive.

    A [workspace] is an unforgeable [private] value carrying multi-root
    support plus a [workspace_policy]. Callers cannot construct one directly:
    they must go through [of_cwd] / [of_dir] / [of_dirs], which canonicalize
    roots and (for explicit dirs) fail closed on non-existence.

    The single behavioural change vs. the legacy checker is that absolute
    paths are now {i admitted} when they fall under a workspace root — this is
    the whole point of the multi-root design. Everything else (reject [..],
    reject [:], reject sensitive prefixes) is a faithful port of
    [Bash_safe_command] so security semantics do not drift.

    NOTE on the [private] types: [workspace_policy], [workspace], and
    [sandboxed_path] are all [private]. External code may pattern-match and
    read their fields (e.g. [ws.policy.sensitive_prefixes]) but may {b not}
    construct them — so a [sandboxed_path] can only originate inside this
    module, i.e. only via a successful [admit]. This is the load-bearing
    type-level guarantee. *)

type workspace_policy = private {
  sensitive_prefixes : string list;
  (** Canonical list of absolute path prefixes that are off-limits
      (e.g. ["/etc"], ["$HOME/.ssh"]). Source of truth lives in
      [default_policy]; no other site in the codebase reads [$HOME]
      to derive this list. *)
}

type workspace = private {
  roots : string list;
  (** Canonicalized absolute paths. [List.hd roots] is the {b primary} root:
      relative paths admitted by [admit] resolve against it. Additional
      roots exist so absolute paths under any of them may be admitted.
      Invariant: non-empty (constructors reject []). *)
  policy : workspace_policy;
}

type sandboxed_path = private Path of string
(** A path that has passed [admit] validation: it is canonicalized, under a
    workspace root, free of [..] components and [:], and outside every
    sensitive prefix. The [Path] constructor is [private], so the only way
    to obtain a [sandboxed_path] is via [admit]. *)

(** [default_policy ()] returns the standard sensitive-prefix list.
    Reads [$HOME] exactly once. This is the ONLY place the prefix source is
    derived — downstream code should never re-read [$HOME] for prefixes. *)
val default_policy : unit -> workspace_policy

(** [make_policy ~sensitive_prefixes] constructs a custom policy with the
    given prefix list. Use this when you need a non-default sensitive-prefix
    set (e.g. a workspace that additionally protects a secrets directory). *)
val make_policy : sensitive_prefixes:string list -> workspace_policy

(** Construct a workspace from the process CWD. This is the ONLY sanctioned
    place [Sys.getcwd] is read by a security primitive (three convenience
    sites elsewhere — skill_loader / par_capi / main — are exempted). *)
val of_cwd : ?policy:workspace_policy -> unit ->
  (workspace, Types.error_category) result

(** Construct a single-root workspace from an absolute directory.
    Fails closed if [dir] is empty, relative, or does not exist on disk
    (existence is checked via [Sys.file_exists] before canonicalization, so
    a non-existent root can never become an admit target). *)
val of_dir : ?policy:workspace_policy -> string ->
  (workspace, Types.error_category) result

(** Construct a multi-root workspace. Head of the input list becomes the
    primary root. Roots are canonicalized and de-duplicated, preserving
    first-seen order. Empty input is rejected. Any non-absolute or
    non-existent root aborts the whole construction (fail-closed). *)
val of_dirs : ?policy:workspace_policy -> string list ->
  (workspace, Types.error_category) result

(** [admit workspace path] validates [path] and returns a [sandboxed_path]
    iff it is safe.

    Validation (first error wins, faithful to [Bash_safe_command] except
    where noted):
      1. Reject any path having [".."] as a [/]-split component →
         [Invalid_input "path contains .."]. (Substring "foo..bar" is fine.)
      2. Reject any path containing [:] → [Invalid_input "path contains :"].
      3. If [path] is absolute (starts with [/]): canonicalize it, then
         require it to fall under {i some} workspace root, else
         [Invalid_input "absolute path not under any workspace root"].
         (This is the NEW behaviour — absolute paths under a root are now OK.)
      4. If [path] is relative (or empty): join against the primary root
         ([List.hd workspace.roots]). An empty [path] admits the primary root
         itself.
      5. After resolution to an absolute canonical path, reject if it starts
         with any [workspace.policy.sensitive_prefixes] →
         [Permission_denied <canonical>].

    The sensitive-prefix match is a bare [String.starts_with] (no [/]
    boundary), intentionally matching the legacy checker's semantics so that
    security behaviour does not drift. *)
val admit : workspace -> string ->
  (sandboxed_path, Types.error_category) result

(** Primary root — [List.hd workspace.roots]. Used for display and for
    resolving relative paths inside [admit]. Never raises (roots is
    invariantly non-empty). *)
val root : workspace -> string

(** Extract the canonicalized absolute path string carried by a
    [sandboxed_path]. *)
val to_string : sandboxed_path -> string
