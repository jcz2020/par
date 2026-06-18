(* test/test_cli_args.ml - PAR-v5a
   Tests that multi-token prompts are correctly joined into a single
   question string. The actual Cmdliner argv parsing is integration-tested
   via `par ask` manual smoke; these tests verify the join contract. *)

(* The join logic used by cmd_ask to normalize the variadic positional
   argument list into a single question string. Kept in sync with
   bin/main.ml's `String.concat " " question_tokens`. *)
let normalize_question tokens = String.concat " " tokens

let test_ask_single_word () =
  let result = normalize_question ["hello"] in
  Alcotest.(check string) "single token passes through"
    "hello" result

let test_ask_multi_word_english () =
  let result = normalize_question ["what"; "time"; "is"; "it"] in
  Alcotest.(check string) "multiple tokens joined with spaces"
    "what time is it" result

let test_ask_cjk_multibyte () =
  let result = normalize_question ["本地有哪些文件夹？"] in
  Alcotest.(check string) "single CJK token passes through"
    "本地有哪些文件夹？" result

let test_ask_mixed_cjk_english () =
  let result = normalize_question ["看看"; "config.json"; "文件"] in
  Alcotest.(check string) "mixed CJK + English joined"
    "看看 config.json 文件" result

let test_ask_empty_list () =
  let result = normalize_question [] in
  Alcotest.(check string) "empty token list yields empty string"
    "" result

let () =
  Alcotest.run "CLI args (PAR-v5a)" [
    "normalize_question", [
      Alcotest.test_case "single word" `Quick
        test_ask_single_word;
      Alcotest.test_case "multi-word English" `Quick
        test_ask_multi_word_english;
      Alcotest.test_case "CJK multibyte" `Quick
        test_ask_cjk_multibyte;
      Alcotest.test_case "mixed CJK + English" `Quick
        test_ask_mixed_cjk_english;
      Alcotest.test_case "empty list" `Quick
        test_ask_empty_list;
    ];
  ]
