(** Type-safe command ADT for the bash tool.

    The absence of an [Exec_raw_shell] constructor is the load-bearing
    design decision: by forcing [argv] to be [string list] at the type
    level, the compiler rejects any code that tries to pass a single
    shell string. Shell injection becomes unrepresentable.

    @see <docs/v0.3.1-ROADMAP.md> lines 102-130
    @see <docs/v0.3-ROADMAP.md> lines 845-878 *)

(** A path guaranteed to be CWD-relative and free of parent traversal.
    The [private] constructor means [Path] can only be invoked from
    inside this module — all callers must go through
    [sandboxed_path_of_string] to obtain a [sandboxed_path]. *)
type sandboxed_path = private Path of string

val sandboxed_path_of_string :
  string -> (sandboxed_path, Types.error_category) result
(** Construct a [sandboxed_path] from a CWD-relative string.
    Validation rules (first error wins):
    1. Reject [..] as a path component → [Invalid_input "path contains .."]
    2. Reject paths starting with [/] → [Invalid_input "absolute path not allowed; must be CWD-relative"]
    3. Reject paths containing [:] → [Invalid_input "path contains :"]
    4. Reject paths that, when joined with [Sys.getcwd ()], land inside
       a sensitive absolute prefix → [Permission_denied "<joined>"] *)

val sandboxed_path_to_string : sandboxed_path -> string

val sandboxed_path_cwd : unit -> sandboxed_path
(** Returns the current working directory wrapped in [Path]. *)

(** A command ready for the policy layer to evaluate.
    - [Exec] is the only way to run a program; argv is mandatory.
    - [Pipeline] composes already-validated commands (no shell parsing).
    - [No_op] is a sentinel for disabled / test contexts. *)
type command =
  | Exec of {
      argv : string list;
      cwd : sandboxed_path;
      env : (string * string) list;
      timeout : float;
    }
  | Pipeline of command list
  | No_op

val make_exec :
  argv:string list ->
  ?cwd:sandboxed_path ->
  ?env:(string * string) list ->
  ?timeout:float ->
  unit -> command
(** Build an [Exec] command.
    Defaults: [cwd = sandboxed_path_cwd ()], [env = []], [timeout = 30.0].
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
