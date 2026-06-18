let strip_ansi_escapes s =
  let len = String.length s in
  let buf = Buffer.create len in
  let i = ref 0 in
  let is_csi_final c = c >= '@' && c <= '~' in
  while !i < len do
    if !i + 1 < len && s.[!i] = '\027' && s.[!i + 1] = '[' then begin
      i := !i + 2;
      while !i < len && not (is_csi_final s.[!i]) do incr i done;
      if !i < len then incr i
    end else if !i + 1 < len && s.[!i] = '\027' && s.[!i + 1] = 'O' then begin
      i := !i + 3
    end else if !i + 1 < len && s.[!i] = '\027' then begin
      i := !i + 2
    end else begin
      Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  Buffer.contents buf
