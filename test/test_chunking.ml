(** Tests for [Chunking] — Phase B.3 of v0.5.1 RAG foundation.

    Pure text chunking with three splitter strategies:
    - chunk_by_chars: fixed-size sliding window over characters
    - chunk_by_tokens: whitespace-tokenized sliding window
    - chunk_recursive: LangChain RecursiveCharacterTextSplitter

    No I/O, no provider coupling. *)

open Par

(* Pretty-printer for chunk — lib/dune's pps list does not include
   ppx_deriving.show, so we roll our own. *)
let pp_chunk fmt (c : Chunking.chunk) =
  Format.fprintf fmt "{ text=%S; start_pos=%d; end_pos=%d }"
    c.Chunking.text c.Chunking.start_pos c.Chunking.end_pos

let chunk_testable = Alcotest.testable pp_chunk (=)

let chunk_list_testable = Alcotest.(list chunk_testable)

let chunks_text (chunks : Chunking.chunk list) =
  List.map (fun c -> c.Chunking.text) chunks

let () =
  Alcotest.run "chunking" [
    ("chunk_by_chars", [
      (* 1. basic sliding window, no overlap *)
      Alcotest.test_case "hello world max_size=5 overlap=0 -> 3 chunks" `Quick
        (fun () ->
          let chunks =
            Chunking.chunk_by_chars ~text:"hello world" ~max_size:5 ~overlap:0
          in
          Alcotest.(check int) "3 chunks" 3 (List.length chunks);
          Alcotest.(check (list string)) "texts"
            ["hello"; " worl"; "d"] (chunks_text chunks);
          Alcotest.(check int) "first start_pos" 0
            (List.nth chunks 0).Chunking.start_pos;
          Alcotest.(check int) "first end_pos" 5
            (List.nth chunks 0).Chunking.end_pos;
          Alcotest.(check int) "last end_pos" 11
            (List.nth chunks 2).Chunking.end_pos);

      (* 2. with overlap — shared characters between consecutive chunks *)
      Alcotest.test_case "abcdefghij max_size=3 overlap=1 -> 5 chunks" `Quick
        (fun () ->
          let chunks =
            Chunking.chunk_by_chars ~text:"abcdefghij" ~max_size:3 ~overlap:1
          in
          Alcotest.(check int) "5 chunks" 5 (List.length chunks);
          Alcotest.(check (list string)) "texts with overlap"
            ["abc"; "cde"; "efg"; "ghi"; "ij"] (chunks_text chunks);
          (* overlap invariant: chunk N's tail overlaps chunk N+1's head *)
          Alcotest.(check int) "chunk1.start = chunk0.start + stride" 2
            (List.nth chunks 1).Chunking.start_pos);

      (* 3. empty string *)
      Alcotest.test_case "empty string -> empty list" `Quick
        (fun () ->
          let chunks =
            Chunking.chunk_by_chars ~text:"" ~max_size:10 ~overlap:0
          in
          Alcotest.(check int) "no chunks" 0 (List.length chunks));

      (* 4. text smaller than max_size — one chunk, whole text *)
      Alcotest.test_case "small text -> 1 chunk" `Quick
        (fun () ->
          let chunks =
            Chunking.chunk_by_chars ~text:"small" ~max_size:100 ~overlap:0
          in
          Alcotest.(check int) "1 chunk" 1 (List.length chunks);
          Alcotest.(check string) "text is whole input" "small"
            (List.hd chunks).Chunking.text;
          Alcotest.(check int) "start_pos 0" 0
            (List.hd chunks).Chunking.start_pos;
          Alcotest.(check int) "end_pos = length" 5
            (List.hd chunks).Chunking.end_pos);

      (* 5. overlap == max_size is rejected (would yield zero stride) *)
      Alcotest.test_case "overlap == max_size raises" `Quick
        (fun () ->
          Alcotest.check_raises "Invalid_argument"
            (Invalid_argument "overlap must be < max_size")
            (fun () ->
              ignore
                (Chunking.chunk_by_chars ~text:"x" ~max_size:5 ~overlap:5)));

      (* 6. max_size <= 0 is rejected *)
      Alcotest.test_case "max_size == 0 raises" `Quick
        (fun () ->
          Alcotest.check_raises "Invalid_argument"
            (Invalid_argument "max_size must be > 0")
            (fun () ->
              ignore
                (Chunking.chunk_by_chars ~text:"x" ~max_size:0 ~overlap:0)));
    ]);

    ("chunk_by_tokens", [
      (* 7. whitespace tokenization: 4 words / max_tokens=2 -> 2 chunks *)
      Alcotest.test_case "4 tokens max_tokens=2 overlap=0 -> 2 chunks" `Quick
        (fun () ->
          let chunks =
            Chunking.chunk_by_tokens
              ~text:"one two three four" ~max_tokens:2 ~overlap:0
          in
          Alcotest.(check int) "2 chunks" 2 (List.length chunks);
          Alcotest.(check (list string)) "texts"
            ["one two"; "three four"] (chunks_text chunks));

      (* 8. approximation: 1 whitespace-separated word ≈ 1 token.
            A 34-char word with no spaces counts as 1 token, demonstrating
            that whitespace splitting is a coarse approximation of true
            token counts. For accurate counts, pre-tokenize with the
            provider's tokenizer. *)
      Alcotest.test_case "long word with no spaces = 1 token (approximation)" `Quick
        (fun () ->
          let long_word = String.make 34 'x' in
          let chunks =
            Chunking.chunk_by_tokens
              ~text:long_word ~max_tokens:1 ~overlap:0
          in
          Alcotest.(check int) "1 chunk (1 word = 1 token)" 1
            (List.length chunks);
          Alcotest.(check string) "full word preserved" long_word
            (List.hd chunks).Chunking.text);

      (* 9. token chunk positions track original text offsets *)
      Alcotest.test_case "token chunk positions match original text" `Quick
        (fun () ->
          let text = "one two three four" in
          let chunks =
            Chunking.chunk_by_tokens ~text ~max_tokens:2 ~overlap:0
          in
          List.iter
            (fun c ->
              let len = c.Chunking.end_pos - c.Chunking.start_pos in
              let sub = String.sub text c.Chunking.start_pos len in
              Alcotest.(check string) "substring matches chunk text"
                c.Chunking.text sub)
            chunks);
    ]);

    ("chunk_recursive", [
      (* 10. paragraph splitting with explicit separators *)
      Alcotest.test_case "para split on \\n\\n -> 3 paragraph chunks" `Quick
        (fun () ->
          let chunks =
            Chunking.chunk_recursive
              ~text:"para1\n\npara2\n\npara3"
              ~separators:["\n\n"; "\n"; " "; ""]
              ~max_size:10 ~overlap:0
          in
          Alcotest.(check int) "3 chunks" 3 (List.length chunks);
          Alcotest.(check (list string)) "paragraphs"
            ["para1"; "para2"; "para3"] (chunks_text chunks);
          (* positions skip the \n\n separators *)
          Alcotest.(check int) "para2 start_pos = 7"
            7 (List.nth chunks 1).Chunking.start_pos;
          Alcotest.(check int) "para2 end_pos = 12"
            12 (List.nth chunks 1).Chunking.end_pos);

      (* 11. default separators match the explicit LangChain default *)
      Alcotest.test_case "default separators == [\\n\\n; \\n; ' '; '']" `Quick
        (fun () ->
          let text = "hello world\n\nfoo bar baz" in
          let with_default =
            Chunking.chunk_recursive ~text ~max_size:10 ~overlap:0
          in
          let with_explicit =
            Chunking.chunk_recursive
              ~text ~separators:["\n\n"; "\n"; " "; ""]
              ~max_size:10 ~overlap:0
          in
          Alcotest.(check chunk_list_testable)
            "default separators match explicit default"
            with_explicit with_default);

      (* 12. falls through to finer separator when chunk too big *)
      Alcotest.test_case "long homogeneous string falls through to char split" `Quick
        (fun () ->
          let chunks =
            Chunking.chunk_recursive
              ~text:(String.make 10 'a')
              ~max_size:3 ~overlap:0
          in
          Alcotest.(check (list string)) "split into 3-char chunks"
            ["aaa"; "aaa"; "aaa"; "a"] (chunks_text chunks));

      (* 13. mixed: short paragraph kept whole, long paragraph recursed *)
      Alcotest.test_case "short para kept, long para split by words" `Quick
        (fun () ->
          let chunks =
            Chunking.chunk_recursive
              ~text:"short\n\nthis is too long"
              ~max_size:10 ~overlap:0
          in
          let texts = chunks_text chunks in
          Alcotest.(check bool) "first chunk is 'short'"
            true ("short" = List.hd texts);
          Alcotest.(check bool) "long paragraph was split into multiple"
            true (List.length texts > 2);
          Alcotest.(check (list string)) "expected split"
            ["short"; "this is"; "too long"] texts);
    ]);

    ("positions and roundtrip", [
      (* 14. all chunk_by_chars offsets are valid substrings of original *)
      Alcotest.test_case "chunk_by_chars offsets are valid substrings" `Quick
        (fun () ->
          let text = "hello world foo bar" in
          let chunks =
            Chunking.chunk_by_chars ~text ~max_size:7 ~overlap:2
          in
          List.iter
            (fun c ->
              let len = c.Chunking.end_pos - c.Chunking.start_pos in
              let sub = String.sub text c.Chunking.start_pos len in
              Alcotest.(check string) "substring matches chunk text"
                c.Chunking.text sub)
            chunks);

      (* 15. all chunk_recursive offsets are valid substrings *)
      Alcotest.test_case "chunk_recursive offsets are valid substrings" `Quick
        (fun () ->
          let text = "para1\n\npara2\n\npara3" in
          let chunks =
            Chunking.chunk_recursive ~text ~max_size:10 ~overlap:0
          in
          List.iter
            (fun c ->
              let len = c.Chunking.end_pos - c.Chunking.start_pos in
              let sub = String.sub text c.Chunking.start_pos len in
              Alcotest.(check string) "substring matches chunk text"
                c.Chunking.text sub)
            chunks);

      (* 16. (bonus) roundtrip for chunk_by_chars overlap=0 reconstructs text *)
      Alcotest.test_case "chunk_by_chars overlap=0 roundtrip" `Quick
        (fun () ->
          let text = "abcdefghijklmnop" in
          let chunks =
            Chunking.chunk_by_chars ~text ~max_size:4 ~overlap:0
          in
          let reconstructed = String.concat "" (chunks_text chunks) in
          Alcotest.(check string) "roundtrip reconstructs original"
            text reconstructed);
    ]);
  ]
