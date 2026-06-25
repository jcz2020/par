let set_raw_mode fd =
  let orig = Unix.tcgetattr fd in
  let raw = { orig with
    Unix.c_icanon = false;
    Unix.c_echo = false;
    Unix.c_vmin = 1;
    Unix.c_vtime = 0;
  } in
  Unix.tcsetattr fd Unix.TCSANOW raw;
  orig

let restore_mode fd orig =
  Unix.tcsetattr fd Unix.TCSANOW orig

let utf8_continuation_count c =
  let code = Char.code c in
  if code < 0x80 then 0
  else if (code land 0xE0) = 0xC0 then 1
  else if (code land 0xF0) = 0xE0 then 2
  else if (code land 0xF8) = 0xF0 then 3
  else 0

let utf8_display_width leading_byte =
  let code = Char.code leading_byte in
  if code < 0x80 then 1
  else if (code land 0xF0) = 0xE0 then 2
  else if (code land 0xF8) = 0xF0 then 2
  else 1

let read_line_utf8 prompt =
  Printf.printf "%s" prompt;
  flush stdout;
  if not (Unix.isatty Unix.stdin) then
    (* Non-interactive stdin (pipe/redirect): skip raw-mode line editing
       and read a plain line. Keeps the REPL drivable for scripting/tests. *)
    (match input_line stdin with
     | line -> Some (String.trim line)
     | exception End_of_file -> None)
  else begin
    let orig = set_raw_mode Unix.stdin in
    Fun.protect
      ~finally:(fun () -> restore_mode Unix.stdin orig)
      (fun () ->
        let buf = Buffer.create 256 in
        let char_sizes : (int * int) list ref = ref [] in
        let pending = Buffer.create 4 in
        let pending_needed = ref 0 in
      let erase_last_char () =
        match !char_sizes with
        | [] -> ()
        | (bytes, cols) :: rest ->
          char_sizes := rest;
          for _ = 1 to bytes do
            Buffer.truncate buf (Buffer.length buf - 1)
          done;
          for _ = 1 to cols do
            Printf.printf "\b \b"
          done;
          flush stdout
      in
      let flush_pending () =
        if Buffer.length pending > 0 then begin
          let bytes = Buffer.length pending in
          let leading = (Buffer.sub pending 0 1).[0] in
          let cols = utf8_display_width leading in
          Buffer.add_buffer buf pending;
          char_sizes := (bytes, cols) :: !char_sizes;
          Buffer.output_buffer stdout pending;
          flush stdout;
          Buffer.clear pending;
          pending_needed := 0
        end
      in
      let rec loop () =
        let c = input_char stdin in
        let code = Char.code c in
        if code = 0x0a || code = 0x0d then begin
          flush_pending ();
          Printf.printf "\n";
          flush stdout;
          Some (Buffer.contents buf)
        end else if code = 0x7f || code = 0x08 then begin
          if Buffer.length pending > 0 then begin
            Buffer.clear pending;
            pending_needed := 0
          end else
            erase_last_char ();
          loop ()
        end else if code = 0x04 then
          if Buffer.length buf = 0 && Buffer.length pending = 0 then None
          else loop ()
        else if code = 0x1b then begin
          (try ignore (input_char stdin) with _ -> ());
          loop ()
        end else if !pending_needed > 0 then begin
          Buffer.add_char pending c;
          if Buffer.length pending > !pending_needed then flush_pending ();
          loop ()
        end else begin
          pending_needed := utf8_continuation_count c;
          Buffer.add_char pending c;
          if !pending_needed = 0 then flush_pending ();
          loop ()
        end
      in
      loop ())
  end

let read_line prompt =
  match read_line_utf8 prompt with
  | Some line -> Some line
  | None ->
    Printf.printf "\n";
    flush stdout;
    None
