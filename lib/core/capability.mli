(** Runtime capability registry for the PAR SDK.

    Detects platform-specific features at runtime and provides a single
    source of truth for capability gating.  Modules that need
    platform-specific behaviour (e.g. process spawning, signal-based kill,
    pipe I/O) consult [Capability.detect] instead of scattering
    [Sys.os_type] checks across the codebase.

    On Unix-like systems ([Sys.os_type = "Unix"]) every capability is
    [Available].  On Windows ([Sys.os_type = "Win32"]) certain
    capabilities return [Unavailable] with an actionable message that
    explains the gap and links to the relevant upstream tracking issue.

    This module has no mutable state and is safe to call from any domain
    without synchronization. *)

(** The set of platform capabilities the runtime may gate on.

    Each variant names a feature that requires platform support.  Add new
    variants here when a new platform-dependent feature is introduced. *)
type capability = [
  | `Process_spawning
  | `Pipe_io
  | `Signal_based_kill
]

(** The status of a single capability on the current platform. *)
type capability_status = [
  | `Available
  | `Unavailable of string
]

val detect : unit -> capability -> capability_status
(** [detect () cap] returns the status of [cap] on the current platform.

    On Unix-like systems every capability is [`Available].
    On Windows, [Process_spawning], [Pipe_io], and [Signal_based_kill]
    return [`Unavailable msg] where [msg] is an actionable explanation
    including the upstream tracking URL. *)

val is_windows : unit -> bool
(** [is_windows ()] is [true] when [Sys.os_type = "Win32"]. *)

val platform_name : unit -> string
(** [platform_name ()] returns a human-readable platform identifier.

    Examples: ["Linux"], ["macOS"], ["Windows"], ["Unix (unknown)"]. *)
