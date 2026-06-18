open Par

let esc = String.make 1 '\027'

let test_plain_ascii () =
  let result = Cli_util.strip_ansi_escapes "hello world" in
  Alcotest.(check string) "plain ascii unchanged" "hello world" result

let test_cjk_unchanged () =
  let result = Cli_util.strip_ansi_escapes "你好世界" in
  Alcotest.(check string) "CJK characters unchanged" "你好世界" result

let test_csi_up_arrow () =
  let input = "hello" ^ esc ^ "[Aworld" in
  let result = Cli_util.strip_ansi_escapes input in
  Alcotest.(check string) "CSI up arrow stripped" "helloworld" result

let test_csi_delete_key () =
  let input = "abc" ^ esc ^ "[3~def" in
  let result = Cli_util.strip_ansi_escapes input in
  Alcotest.(check string) "CSI delete key stripped" "abcdef" result

let test_ss3_up_arrow () =
  let input = "hello" ^ esc ^ "OAworld" in
  let result = Cli_util.strip_ansi_escapes input in
  Alcotest.(check string) "SS3 up arrow stripped" "helloworld" result

let test_ss3_home () =
  let input = "hello" ^ esc ^ "OHworld" in
  let result = Cli_util.strip_ansi_escapes input in
  Alcotest.(check string) "SS3 home stripped" "helloworld" result

let test_multiple_escapes () =
  let input = esc ^ "[A" ^ esc ^ "[B" ^ esc ^ "OChello" in
  let result = Cli_util.strip_ansi_escapes input in
  Alcotest.(check string) "multiple escapes stripped" "hello" result

let test_mixed_cjk_and_escapes () =
  let input = "你" ^ esc ^ "[A好" in
  let result = Cli_util.strip_ansi_escapes input in
  Alcotest.(check string) "CJK + escape mix" "你好" result

let test_empty_string () =
  let result = Cli_util.strip_ansi_escapes "" in
  Alcotest.(check string) "empty string" "" result

let test_only_escapes () =
  let input = esc ^ "[A" ^ esc ^ "OB" ^ esc ^ "[3~" in
  let result = Cli_util.strip_ansi_escapes input in
  Alcotest.(check string) "only escapes → empty" "" result

let () =
  Alcotest.run "strip_ansi_escapes" [
    "basic", [
      Alcotest.test_case "plain ascii" `Quick test_plain_ascii;
      Alcotest.test_case "CJK unchanged" `Quick test_cjk_unchanged;
      Alcotest.test_case "empty string" `Quick test_empty_string;
    ];
    "csi_sequences", [
      Alcotest.test_case "up arrow (CSI A)" `Quick test_csi_up_arrow;
      Alcotest.test_case "delete key (CSI 3~)" `Quick test_csi_delete_key;
    ];
    "ss3_sequences", [
      Alcotest.test_case "up arrow (SS3 A)" `Quick test_ss3_up_arrow;
      Alcotest.test_case "home (SS3 H)" `Quick test_ss3_home;
    ];
    "complex", [
      Alcotest.test_case "multiple escapes" `Quick test_multiple_escapes;
      Alcotest.test_case "mixed CJK + escapes" `Quick test_mixed_cjk_and_escapes;
      Alcotest.test_case "only escapes" `Quick test_only_escapes;
    ];
  ]
