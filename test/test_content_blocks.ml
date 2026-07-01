open Par
open Types

let check_content_eq label expected actual =
  Alcotest.check Alcotest.bool label true (expected = actual)

let check_json_roundtrip (to_json : 'a -> Yojson.Safe.t)
    (of_json : Yojson.Safe.t -> ('a, string) result) (v : 'a) =
  let json = to_json v in
  match of_json json with
  | Ok v' ->
      let json' = to_json v' in
      Alcotest.check Alcotest.bool "json roundtrip" true
        (Yojson.Safe.equal json json')
  | Error msg ->
      Alcotest.fail (Printf.sprintf "roundtrip failed: %s" msg)

let text_block_construction =
  ( "Text_block construction", [
    Alcotest.test_case "cache_control=None" `Quick (fun () ->
      let block = Text_block { text = "hello"; cache_control = None } in
      check_content_eq "matches"
        (Text_block { text = "hello"; cache_control = None })
        block);

    Alcotest.test_case "cache_control=Some Ephemeral Five_min" `Quick (fun () ->
      let cc = Some { type_ = `Ephemeral; ttl = Some `Five_min } in
      let block = Text_block { text = "hi"; cache_control = cc } in
      check_content_eq "matches"
        (Text_block { text = "hi"; cache_control = cc })
        block);

    Alcotest.test_case "cache_control=Some Ephemeral One_hour" `Quick (fun () ->
      let cc = Some { type_ = `Ephemeral; ttl = Some `One_hour } in
      let block = Text_block { text = "hi"; cache_control = cc } in
      check_content_eq "matches"
        (Text_block { text = "hi"; cache_control = cc })
        block);

    Alcotest.test_case "cache_control=Some Ephemeral None" `Quick (fun () ->
      let cc = Some { type_ = `Ephemeral; ttl = None } in
      let block = Text_block { text = "hi"; cache_control = cc } in
      check_content_eq "matches"
        (Text_block { text = "hi"; cache_control = cc })
        block);
  ])

let tool_use_block_construction =
  ( "Tool_use_block construction", [
    Alcotest.test_case "basic with null args" `Quick (fun () ->
      let block = Tool_use_block {
        id = "tu_1"; name = "web_search";
        arguments = `Null; cache_control = None;
      } in
      check_content_eq "matches"
        (Tool_use_block {
          id = "tu_1"; name = "web_search";
          arguments = `Null; cache_control = None;
        })
        block);

    Alcotest.test_case "with cache_control" `Quick (fun () ->
      let cc = Some { type_ = `Ephemeral; ttl = Some `Five_min } in
      let args = `Assoc [("q", `String "ocaml")] in
      let block = Tool_use_block {
        id = "tu_2"; name = "search";
        arguments = args; cache_control = cc;
      } in
      check_content_eq "matches"
        (Tool_use_block {
          id = "tu_2"; name = "search";
          arguments = args; cache_control = cc;
        })
        block);
  ])

let tool_result_block_construction =
  ( "Tool_result_block construction", [
    Alcotest.test_case "basic with cache_control=None" `Quick (fun () ->
      let block = Tool_result_block {
        tool_use_id = "tu_1"; content = "result text"; cache_control = None;
      } in
      check_content_eq "matches"
        (Tool_result_block {
          tool_use_id = "tu_1"; content = "result text"; cache_control = None;
        })
        block);

    Alcotest.test_case "with cache_control" `Quick (fun () ->
      let cc = Some { type_ = `Ephemeral; ttl = Some `One_hour } in
      let block = Tool_result_block {
        tool_use_id = "tu_2"; content = "data"; cache_control = cc;
      } in
      check_content_eq "matches"
        (Tool_result_block {
          tool_use_id = "tu_2"; content = "data"; cache_control = cc;
        })
        block);
  ])

let image_block_construction =
  ( "Image_block construction", [
    Alcotest.test_case "Url source" `Quick (fun () ->
      let block = Image_block {
        source = Url "https://example.com/img.png";
        media_type = "image/png"; data = ""; cache_control = None;
      } in
      check_content_eq "matches"
        (Image_block {
          source = Url "https://example.com/img.png";
          media_type = "image/png"; data = ""; cache_control = None;
        })
        block);

    Alcotest.test_case "Base64 source" `Quick (fun () ->
      let block = Image_block {
        source = Base64 "iVBORw0KGgo=";
        media_type = "image/png"; data = "raw"; cache_control = None;
      } in
      check_content_eq "matches"
        (Image_block {
          source = Base64 "iVBORw0KGgo=";
          media_type = "image/png"; data = "raw"; cache_control = None;
        })
        block);

    Alcotest.test_case "with cache_control" `Quick (fun () ->
      let cc = Some { type_ = `Ephemeral; ttl = Some `Five_min } in
      let block = Image_block {
        source = Url "https://example.com/img.png";
        media_type = "image/jpeg"; data = ""; cache_control = cc;
      } in
      check_content_eq "matches"
        (Image_block {
          source = Url "https://example.com/img.png";
          media_type = "image/jpeg"; data = ""; cache_control = cc;
        })
        block);
  ])

let message_helper_tests =
  ( "Message helpers", [
    Alcotest.test_case "content_of_string hello" `Quick (fun () ->
      let blocks = Message.content_of_string "hello" in
      check_content_eq "one text block"
        [Text_block { text = "hello"; cache_control = None }]
        blocks);

    Alcotest.test_case "string_of_content text block" `Quick (fun () ->
      let content =
        [Text_block { text = "hello"; cache_control = None }]
      in
      Alcotest.check Alcotest.string "roundtrip" "hello"
        (Message.string_of_content content));

    Alcotest.test_case "string_of_content mixed blocks" `Quick (fun () ->
      let content = [
        Text_block { text = "a"; cache_control = None };
        Tool_use_block { id = "x"; name = "t"; arguments = `Null; cache_control = None };
        Text_block { text = "b"; cache_control = None };
      ] in
      Alcotest.check Alcotest.string "concatenates text only" "ab"
        (Message.string_of_content content));

    Alcotest.test_case "string_of_content empty" `Quick (fun () ->
      Alcotest.check Alcotest.string "empty" ""
        (Message.string_of_content []));

    Alcotest.test_case "text_of_message on User" `Quick (fun () ->
      let msg : message = {
        role = User;
        content_blocks =
          [Text_block { text = "question"; cache_control = None }];
        tool_calls = None;
        tool_call_id = None;
        name = None;
      } in
      Alcotest.check Alcotest.string "extracts text" "question"
        (Message.text_of_message msg));
  ])

let cache_control_equality =
  ( "cache_control equality", [
    Alcotest.test_case "same ttl -> equal" `Quick (fun () ->
      let a = Some { type_ = `Ephemeral; ttl = Some `Five_min } in
      let b = Some { type_ = `Ephemeral; ttl = Some `Five_min } in
      Alcotest.check Alcotest.bool "equal" true (a = b));

    Alcotest.test_case "different ttl -> not equal" `Quick (fun () ->
      let a = Some { type_ = `Ephemeral; ttl = Some `Five_min } in
      let b = Some { type_ = `Ephemeral; ttl = Some `One_hour } in
      Alcotest.check Alcotest.bool "not equal" false (a = b));
  ])

let yojson_roundtrips =
  ( "Yojson roundtrips", [
    Alcotest.test_case "cache_control roundtrip" `Quick (fun () ->
      let v = { type_ = `Ephemeral; ttl = Some `Five_min } in
      check_json_roundtrip cache_control_to_yojson
        cache_control_of_yojson v);

    Alcotest.test_case "image_source roundtrip Url" `Quick (fun () ->
      let v = Url "http://example.com/img.png" in
      check_json_roundtrip image_source_to_yojson
        image_source_of_yojson v);
  ])

let cache_ttl_equality =
  ( "cache_ttl equality", [
    Alcotest.test_case "Five_min = Five_min" `Quick (fun () ->
      Alcotest.check Alcotest.bool "equal" true (`Five_min = `Five_min));

    Alcotest.test_case "Five_min <> One_hour" `Quick (fun () ->
      Alcotest.check Alcotest.bool "not equal" false
        (`Five_min = `One_hour));
  ])

let () = Alcotest.run "Content_blocks" [
  text_block_construction;
  tool_use_block_construction;
  tool_result_block_construction;
  image_block_construction;
  message_helper_tests;
  cache_control_equality;
  yojson_roundtrips;
  cache_ttl_equality;
]
