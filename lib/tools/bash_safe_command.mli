(** Type-safe command ADT for the bash tool.

    The absence of an [Exec_raw_shell] constructor is the load-bearing
    design decision: by forcing [argv] to be [string list] at the type
    level, the compiler rejects any code that tries to pass a single
    shell string. Shell injection becomes unrepresentable.

    Wave 3 of the path-admission refactor: [sandboxed_path] and its
    constructors/validators now live in the [Workspace] module. This
    module references [Workspace.sandboxed_path] for the [Exec.cwd]
    field. There is no longer an ambient [sandboxed_path_cwd] here —
    callers must thread a [Workspace.workspace] through and call
    [Workspace.admit] / [Workspace.of_cwd] to obtain a cwd value. *)

(** A command ready for the policy layer to evaluate.
    - [Exec] is the only way to run a program; argv is mandatory.
    - [Pipeline] composes already-validated commands (no shell parsing).
    - [No_op] is a sentinel for disabled / test contexts.

    The [cwd] field of [Exec] is a [Workspace.sandboxed_path] — a value
    that can only originate from [Workspace.admit], so the type system
    guarantees every [Exec] carries a validated cwd. *)
type command =
  | Exec of {
      argv : string list;
      cwd : Workspace.sandboxed_path;
      env : (string * string) list;
      timeout : float;
    }
  | Pipeline of command list
  | No_op

val make_exec :
  argv:string list ->
  cwd:Workspace.sandboxed_path ->
  ?env:(string * string) list ->
  ?timeout:float ->
  unit -> command
(** Build an [Exec] command. [cwd] is MANDATORY (no default) — callers
    must obtain it via [Workspace.admit] / [Workspace.of_cwd].
    Defaults: [env = []], [timeout = 30.0].
    @raise Invalid_argument if [timeout <= 0.0] or [timeout > 600.0]. *)

val make_pipeline : command list -> command
(** Compose a [Pipeline] of already-built commands. *)

(** Heuristic risk assessment. Not a security boundary — [Bash_policy] (T4)
    enforces the real rules. This is for the operator-facing risk badge. *)
type risk = Low | Medium | High | Critical

val assess_risk : command -> risk
val risk_to_string : risk -> string

val validate_argv : string list -> (unit, Types.error_category) result
(** Pre-flight check used by the bash tool handler:
    - empty argv → [Invalid_input "empty argv"]
    - any NUL byte in argv → [Invalid_input "NUL byte in argv"]
    - length > 4096 → [Invalid_input "argv too long"] *)

val argv_of_command : command -> string list
(** Extract the argv list from a command. Returns [[]] for [Pipeline]
    and [No_op]. *)

val env_of_command : command -> (string * string) list
(** Extract the environment list from a command. Returns [[]] for
    [Pipeline] and [No_op]. *)

val command_to_string : command -> string
(** Render a command for logs / error messages.
    - [Exec]: space-joined argv
    - [Pipeline]: pipe-joined child commands
    - [No_op]: literal ["<no_op>"] *)

val command_to_yojson : command -> Yojson.Safe.t
(** Serialize a command for event payloads. Includes kind, argv, cwd
    (for [Exec]), env, timeout (for [Exec]), and the assessed risk. *)
