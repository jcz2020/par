(* -------------------------------------------------------------------------- *)
(* Cli_style — minimal ANSI color helpers for terminal output.                *)
(*                                                                            *)
(* All styling is opt-in: when stdout is not a TTY (pipe, redirect) or the   *)
(* NO_COLOR environment variable is set, [styled] returns the string          *)
(* unchanged. This is the conventional contract that cargo, ls, ripgrep,      *)
(* and most well-behaved Unix tools follow.                                    *)
(* -------------------------------------------------------------------------- *)

type style =
  | Bold
  | Dim
  | Cyan
  | Green
  | BoldCyan

let esc = "\027"

let ansi_open = function
  | Bold     -> esc ^ "[1m"
  | Dim      -> esc ^ "[2m"
  | Cyan     -> esc ^ "[36m"
  | Green    -> esc ^ "[32m"
  | BoldCyan -> esc ^ "[1;36m"

let ansi_close = esc ^ "[0m"

let supports_color () =
  Unix.isatty Unix.stdout
  && Sys.getenv_opt "NO_COLOR" = None

let styled style s =
  if supports_color () then
    ansi_open style ^ s ^ ansi_close
  else
    s

let bold      s = styled Bold s
let dim       s = styled Dim s
let cyan      s = styled Cyan s
let green     s = styled Green s
let bold_cyan s = styled BoldCyan s
