(** The trust boundary for the bash tool. Every bash invocation passes
    its [Bash_safe_command.command] through [POLICY.filter], which decides
    whether to allow, modify, or reject the command.
*)

module type POLICY = sig
  val name : string
  (** Short identifier for logs, e.g., "Coder", "ReadOnly", "ReadOnlyNoNet" *)

  val filter : Bash_safe_command.command -> (Bash_safe_command.command, Types.error_category) result
  (** Examine a [command] and either:
      - Return [Ok cmd'] (possibly modified) if the command is allowed
      - Return [Error (Permission_denied "...")] if the command is rejected
      - Return [Error (Invalid_input "...")] if the command is malformed
      Must be total: never raise. *)

  val max_cpu_seconds : float
  (** Hard cap on CPU time per invocation (seconds) *)

  val max_memory_kb : int
  (** Soft target for memory usage (best-effort; not enforced in v0.3.1) *)

  val allow_network : bool
  (** Whether commands that talk to the network are allowed *)

  val allow_write : bool
  (** Whether commands that mutate the filesystem are allowed *)
end

(** Rejects any command that could mutate the filesystem or env.
    Read-only commands pass through unchanged. Network is allowed. *)
module ReadOnly : POLICY

(** [ReadOnly] + rejects any command that touches the network.
    Most restrictive preset. *)
module ReadOnlyNoNet : POLICY

(** Default policy. Allows write + network. Rejects commands that match
    the [Bash_blacklist] (rm -rf /, dd of=/dev/, fork bombs, etc.). *)
module Coder : POLICY

(** Strip known secret env vars. Applied by all 3 policies' [filter]
    on [Exec] commands before returning. The 3 policies differ only in
    what additional checks they perform.

    Strips: any key matching (case-insensitive) *secret*, *key*, *token*,
    *password*, *credential*, plus exact AWS_*, AZURE_*, GCP_*,
    OPENAI_API_KEY, ANTHROPIC_API_KEY, GITHUB_TOKEN.
    Keeps: PATH, HOME, LANG, LC_ALL, TZ, USER, LOGNAME, SHELL, TMPDIR,
    PWD, OLDPWD.

    Output is sorted by key (descending) for determinism — the same input
    always produces the same output, important for tests. *)
val sanitize_env : (string * string) list -> (string * string) list

(** Remove ANSI escape sequences from command output.
    Strips: ESC[...letter (CSI), ESC]...BEL (OSC), ESC= / ESC>. *)
val strip_ansi : string -> string

(** Truncate command output for safety.
    Returns [(truncated_text, was_truncated)].
    Byte-first ([max_bytes]), then line cap ([max_lines]).
    Appends a marker if truncated. *)
val truncate_output : max_bytes:int -> max_lines:int -> string -> string * bool
