(** Text chunking module — Phase B.3 of v0.5.1 RAG foundation.

    Three splitter strategies for dividing text into processing chunks:
    - [chunk_by_chars]: fixed-size sliding window over characters
    - [chunk_by_tokens]: whitespace-tokenized sliding window
    - [chunk_recursive]: LangChain RecursiveCharacterTextSplitter

    Pure: no I/O, no provider coupling. *)

type chunk = {
  text : string;
  start_pos : int;  (** offset of first character in the original text *)
  end_pos : int;    (** offset one past the last character *)
}

let is_whitespace c = c = ' ' || c = '\t' || c = '\n' || c = '\r'

let validate_params ~max_size ~overlap =
  if max_size <= 0 then
    invalid_arg "max_size must be > 0";
  if overlap < 0 then
    invalid_arg "overlap must be >= 0";
  if overlap >= max_size then
    invalid_arg "overlap must be < max_size"

let chunk_by_chars ~text ~max_size ~overlap =
  validate_params ~max_size ~overlap;
  let len = String.length text in
  if len = 0 then []
  else begin
    let stride = max_size - overlap in
    let result = ref [] in
    let pos = ref 0 in
    while !pos < len do
      let end_pos = min (!pos + max_size) len in
      let chunk_text = String.sub text !pos (end_pos - !pos) in
      result := { text = chunk_text; start_pos = !pos; end_pos } :: !result;
      pos := !pos + stride
    done;
    List.rev !result
  end

let tokenize_whitespace text =
  let tokens = ref [] in
  let i = ref 0 in
  let len = String.length text in
  while !i < len do
    while !i < len && is_whitespace text.[!i] do
      incr i
    done;
    if !i < len then begin
      let start = !i in
      while !i < len && not (is_whitespace text.[!i]) do
        incr i
      done;
      let word = String.sub text start (!i - start) in
      tokens := (word, start, !i) :: !tokens
    end
  done;
  List.rev !tokens

let chunk_by_tokens ~text ~max_tokens ~overlap =
  validate_params ~max_size:max_tokens ~overlap;
  let tokens = tokenize_whitespace text in
  let n = List.length tokens in
  if n = 0 then []
  else begin
    let stride = max_tokens - overlap in
    let result = ref [] in
    let pos = ref 0 in
    while !pos < n do
      let end_idx = min (!pos + max_tokens) n in
      let first = List.nth tokens !pos in
      let last = List.nth tokens (end_idx - 1) in
      let (_, fs, _) = first in
      let (_, _, le) = last in
      let chunk_text = String.sub text fs (le - fs) in
      result := { text = chunk_text; start_pos = fs; end_pos = le } :: !result;
      pos := !pos + stride
    done;
    List.rev !result
  end

let contains_substring ~needle haystack =
  let nlen = String.length needle in
  if nlen = 0 then true
  else begin
    let hlen = String.length haystack in
    let found = ref false in
    let i = ref 0 in
    while not !found && !i <= hlen - nlen do
      let j = ref 0 in
      let matches = ref true in
      while !matches && !j < nlen do
        if haystack.[!i + !j] <> needle.[!j] then matches := false;
        incr j
      done;
      if !matches then found := true;
      incr i
    done;
    !found
  end

let find_separator separators text =
  let rec loop = function
    | [] -> ("", [])
    | s :: rest ->
      if s = "" then ("", rest)
      else if contains_substring ~needle:s text then (s, rest)
      else loop rest
  in
  loop separators

(* Split text on separator, returning pieces with absolute offsets.
   When sep = "", each character becomes its own piece. *)
let split_with_positions ~sep ~offset text =
  if sep = "" then begin
    let len = String.length text in
    let result = ref [] in
    for i = len - 1 downto 0 do
      let piece = String.sub text i 1 in
      result := (piece, offset + i, offset + i + 1) :: !result
    done;
    !result
  end else begin
    let sep_len = String.length sep in
    let len = String.length text in
    let pieces = ref [] in
    let chunk_start = ref 0 in
    let i = ref 0 in
    while !i <= len - sep_len do
      let is_match =
        let m = ref true in
        let j = ref 0 in
        while !m && !j < sep_len do
          if text.[!i + !j] <> sep.[!j] then m := false;
          incr j
        done;
        !m
      in
      if is_match then begin
        let piece = String.sub text !chunk_start (!i - !chunk_start) in
        pieces := (piece, offset + !chunk_start, offset + !i) :: !pieces;
        chunk_start := !i + sep_len;
        i := !i + sep_len
      end else
        incr i
    done;
    let final_piece = String.sub text !chunk_start (len - !chunk_start) in
    pieces := (final_piece, offset + !chunk_start, offset + len) :: !pieces;
    List.rev !pieces
  end

(* Merge consecutive splits into chunks respecting max_size and overlap.
   Splits are (text, abs_start, abs_end) tuples, contiguous in original.
   The separator is reinserted between splits; for contiguous splits
   this means the merged text equals the original substring. *)
let merge_splits ~original ~sep ~max_size ~overlap splits =
  let sep_len = String.length sep in
  let docs = ref [] in
  let current = ref [] in
  let total = ref 0 in
  let emit () =
    if !current <> [] then begin
      let (_, first_s, _) = List.hd !current in
      let (_, _, last_e) = List.hd (List.rev !current) in
      let merged = String.sub original first_s (last_e - first_s) in
      docs := ({ text = merged; start_pos = first_s; end_pos = last_e }) :: !docs
    end
  in
  let pop_front () =
    match !current with
    | [] -> ()
    | (t, _, _) :: rest ->
      let pop_len =
        String.length t + (if rest <> [] then sep_len else 0)
      in
      total := !total - pop_len;
      current := rest
  in
  List.iter
    (fun (d, ds, de) ->
      let d_len = String.length d in
      let added = d_len + (if !current <> [] then sep_len else 0) in
      if !current <> [] && !total + added > max_size then begin
        emit ();
        while !total > overlap && !current <> [] do
          pop_front ()
        done
      end;
      (* either current is empty or total + added <= max_size *)
      current := !current @ [(d, ds, de)];
      total := !total + added)
    splits;
  emit ();
  List.rev !docs

let default_separators = ["\n\n"; "\n"; " "; ""]

let rec split_recursive
    ~original ~offset ~separators ~max_size ~overlap text =
  let (sep, new_seps) = find_separator separators text in
  let splits = split_with_positions ~sep ~offset text in
  let final = ref [] in
  let good = ref [] in
  let flush_good () =
    if !good <> [] then begin
      let merged =
        merge_splits ~original ~sep ~max_size ~overlap (List.rev !good)
      in
      List.iter (fun c -> final := c :: !final) merged;
      good := []
    end
  in
  List.iter
    (fun ((piece, ps, pe) as split) ->
      if String.length piece <= max_size then
        good := split :: !good
      else begin
        flush_good ();
        if new_seps = [] then
          (* no finer separator; emit oversized piece as-is *)
          final :=
            { text = piece; start_pos = ps; end_pos = pe } :: !final
        else begin
          let recd =
            split_recursive
              ~original ~offset:ps ~separators:new_seps ~max_size ~overlap
              piece
          in
          List.iter (fun c -> final := c :: !final) recd
        end
      end)
    splits;
  flush_good ();
  List.rev !final

[@@@warning "-16"]

let chunk_recursive ~text ?(separators = default_separators) ~max_size ~overlap =
  validate_params ~max_size ~overlap;
  split_recursive ~original:text ~offset:0 ~separators ~max_size ~overlap text
