(** Strip ANSI escape sequences from a string.

    Handles:
    - CSI sequences: ESC [ ... <final byte 0x40-0x7E>
    - SS3 sequences: ESC O <single char>
    - Bare ESC + single char

    Used by the REPL to clean up input when arrow keys or other
    terminal control keys generate escape sequences in canonical
    (cooked) mode. *)
val strip_ansi_escapes : string -> string
