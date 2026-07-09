(* Capability — runtime platform feature detection.
   See [capability.mli] for the contract.

   Pure module: no mutable state, no Eio dependency, safe to call from
   any domain without synchronization.  Every platform-dependent check
   in the runtime should route through [Capability.detect] so there is
   exactly one detection point. *)

type capability = [
  | `Process_spawning
  | `Pipe_io
  | `Signal_based_kill
]

type capability_status = [
  | `Available
  | `Unavailable of string
]

let is_windows () = Sys.os_type = "Win32"

let platform_name () =
  match Sys.os_type with
  | "Win32" -> "Windows"
  | "Unix" ->
    (* Distinguish macOS from Linux when possible. *)
    if Sys.file_exists "/System/Library" then "macOS"
    else "Linux"
  | "Cygwin" -> "Cygwin"
  | other -> other

(* ------------------------------------------------------------------ *)
(* Windows unavailability messages                                     *)
(* ------------------------------------------------------------------ *)

let process_spawning_unavailable =
  "Process spawning requires Eio.Process, which is not implemented on \
   Windows. Track: https://github.com/ocaml-multicore/eio/issues/125"

let pipe_io_unavailable =
  "Pipe-based I/O requires Unix domain sockets, which have limited \
   support on Windows. Track: \
   https://github.com/ocaml-multicore/eio/issues/125"

let signal_kill_unavailable =
  "Signal-based process kill (SIGTERM / SIGKILL) is not available on \
   Windows; use TerminateProcess instead. Track: \
   https://github.com/ocaml-multicore/eio/issues/125"

(* ------------------------------------------------------------------ *)
(* Detection                                                           *)
(* ------------------------------------------------------------------ *)

let detect () (cap : capability) : capability_status =
  if is_windows () then
    match cap with
    | `Process_spawning -> `Unavailable process_spawning_unavailable
    | `Pipe_io          -> `Unavailable pipe_io_unavailable
    | `Signal_based_kill -> `Unavailable signal_kill_unavailable
  else
    `Available
