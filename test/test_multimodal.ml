open Par
open Par.Types

let image_source_testable = Alcotest.testable
  (fun ppf s ->
    match s with
    | Url u -> Format.pp_print_string ppf ("Url " ^ u)
    | Base64 b -> Format.pp_print_string ppf ("Base64 " ^ b))
  ( = )

(* -------------------------------------------------------------------------- *)
(* Message helpers                                                            *)
(* -------------------------------------------------------------------------- *)

let helper_tests =
  ( "Message image helpers", [
    Alcotest.test_case "text builds a Text_block" `Quick (fun () ->
      match Message.text "hello" with
      | Text_block { text; cache_control } ->
        Alcotest.check Alcotest.string "text" "hello" text;
        Alcotest.check Alcotest.bool "cache_control is None" true (cache_control = None)
      | _ -> Alcotest.fail "expected Text_block");

    Alcotest.test_case "image_url builds a Url-sourced Image_block" `Quick (fun () ->
      match Message.image_url "https://example.com/a.png" () with
      | Image_block { source; media_type; data; detail; _ } ->
        Alcotest.check image_source_testable "source" (Url "https://example.com/a.png") source;
        Alcotest.check Alcotest.string "media_type" "image/png" media_type;
        Alcotest.check Alcotest.string "data" "" data;
        Alcotest.check Alcotest.(option string) "detail" None detail
      | _ -> Alcotest.fail "expected Image_block");

    Alcotest.test_case "image_url honours media_type and detail" `Quick (fun () ->
      match Message.image_url "https://example.com/a.jpg" ~media_type:"image/jpeg" ~detail:"low" () with
      | Image_block { source; media_type; detail; _ } ->
        Alcotest.check image_source_testable "source" (Url "https://example.com/a.jpg") source;
        Alcotest.check Alcotest.string "media_type" "image/jpeg" media_type;
        Alcotest.check Alcotest.(option string) "detail" (Some "low") detail
      | _ -> Alcotest.fail "expected Image_block");

    Alcotest.test_case "image_base64 builds a Base64-sourced Image_block" `Quick (fun () ->
      match Message.image_base64 ~data:"aGk=" ~media_type:"image/gif" () with
      | Image_block { source; media_type; _ } ->
        Alcotest.check image_source_testable "source" (Base64 "aGk=") source;
        Alcotest.check Alcotest.string "media_type" "image/gif" media_type
      | _ -> Alcotest.fail "expected Image_block");

    Alcotest.test_case "media_type_of_extension maps known image types" `Quick (fun () ->
      Alcotest.check Alcotest.(option string) "png" (Some "image/png")
        (Message.media_type_of_extension ".png");
      Alcotest.check Alcotest.(option string) "jpg" (Some "image/jpeg")
        (Message.media_type_of_extension ".jpg");
      Alcotest.check Alcotest.(option string) "jpeg" (Some "image/jpeg")
        (Message.media_type_of_extension ".jpeg");
      Alcotest.check Alcotest.(option string) "gif" (Some "image/gif")
        (Message.media_type_of_extension ".gif");
      Alcotest.check Alcotest.(option string) "webp" (Some "image/webp")
        (Message.media_type_of_extension ".webp");
      Alcotest.check Alcotest.(option string) "uppercase" (Some "image/png")
        (Message.media_type_of_extension ".PNG");
      Alcotest.check Alcotest.(option string) "unknown" None
        (Message.media_type_of_extension ".txt"));

    Alcotest.test_case "image_file reads a file and infers media_type" `Quick (fun () ->
      let path = Filename.temp_file "par_mm" ".png" in
      let bytes = "\x89PNG\r\n\x1a\nfake" in
      let oc = open_out_bin path in
      output_string oc bytes;
      close_out oc;
      (match Message.image_file path () with
       | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
       | Ok block ->
         (match block with
          | Image_block { source; media_type; _ } ->
            Alcotest.check Alcotest.string "media_type" "image/png" media_type;
            (match source with
             | Base64 encoded ->
               (match Base64.decode encoded with
                | Ok decoded -> Alcotest.check Alcotest.string "roundtrip" bytes decoded
                | Error (`Msg m) -> Alcotest.fail ("base64 decode failed: " ^ m))
             | Url _ -> Alcotest.fail "expected Base64 source")
          | _ -> Alcotest.fail "expected Image_block"));
      Sys.remove path);

    Alcotest.test_case "image_file errors on a missing file" `Quick (fun () ->
      match Message.image_file "/nonexistent/definitely/not/here.png" () with
      | Ok _ -> Alcotest.fail "expected Error for missing file"
      | Error msg ->
        Alcotest.check Alcotest.bool "message is non-empty" true (msg <> ""));

    Alcotest.test_case "image_file falls back to image/png for unknown extension" `Quick (fun () ->
      let path = Filename.temp_file "par_mm" ".weird" in
      let oc = open_out_bin path in
      output_string oc "x";
      close_out oc;
      (match Message.image_file path () with
       | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
       | Ok (Image_block { media_type; _ }) ->
         Alcotest.check Alcotest.string "media_type" "image/png" media_type
       | Ok _ -> Alcotest.fail "expected Image_block");
      Sys.remove path);
  ])

(* -------------------------------------------------------------------------- *)
(* Provider wire formats                                                       *)
(* -------------------------------------------------------------------------- *)

let user_message blocks : message =
  { role = User;
    content_blocks = blocks;
    tool_calls = None;
    tool_call_id = None;
    name = None;
    reasoning_content = None }

let json_assoc = function
  | `Assoc fields -> fields
  | _ -> Alcotest.fail "expected a JSON object"

let find_field key fields =
  match List.assoc_opt key fields with
  | Some v -> v
  | None -> Alcotest.fail (Printf.sprintf "missing field %S" key)

let find_string key fields =
  match find_field key fields with
  | `String s -> s
  | _ -> Alcotest.fail (Printf.sprintf "field %S is not a JSON string" key)

let openai_tests =
  ( "OpenAI image wire format", [
    Alcotest.test_case "image message uses the array content form" `Quick (fun () ->
      let msg = user_message [ Message.text "what is this?"; Message.image_url "https://example.com/a.png" () ] in
      let fields = json_assoc (Openai_provider.build_message_json msg) in
      (match find_field "content" fields with
       | `List parts ->
         Alcotest.check Alcotest.int "part count" 2 (List.length parts);
         (match List.nth parts 0 with
          | `Assoc p ->
            Alcotest.check Alcotest.string "first part type" "text" (find_string "type" p);
            Alcotest.check Alcotest.string "first part text" "what is this?" (find_string "text" p)
          | _ -> Alcotest.fail "expected a JSON object");
         (match List.nth parts 1 with
          | `Assoc p ->
            Alcotest.check Alcotest.string "second part type" "image_url" (find_string "type" p);
            (match find_field "image_url" p with
             | `Assoc img ->
               Alcotest.check Alcotest.string "image url" "https://example.com/a.png" (find_string "url" img)
             | _ -> Alcotest.fail "expected image_url object")
          | _ -> Alcotest.fail "expected a JSON object")
       | _ -> Alcotest.fail "expected content to be an array"));

    Alcotest.test_case "base64 image becomes a data URI" `Quick (fun () ->
      let msg = user_message [ Message.image_base64 ~data:"aGk=" ~media_type:"image/jpeg" () ] in
      let fields = json_assoc (Openai_provider.build_message_json msg) in
      (match find_field "content" fields with
       | `List [ `Assoc p ] ->
         (match find_field "image_url" p with
          | `Assoc img ->
            Alcotest.check Alcotest.string "data uri" "data:image/jpeg;base64,aGk=" (find_string "url" img)
          | _ -> Alcotest.fail "expected image_url object")
       | _ -> Alcotest.fail "expected a one-element content array"));

    Alcotest.test_case "detail is passed through" `Quick (fun () ->
      let msg = user_message [ Message.image_url "https://example.com/a.png" ~detail:"high" () ] in
      let fields = json_assoc (Openai_provider.build_message_json msg) in
      (match find_field "content" fields with
       | `List [ `Assoc p ] ->
         (match find_field "image_url" p with
          | `Assoc img ->
            Alcotest.check Alcotest.string "detail" "high" (find_string "detail" img)
          | _ -> Alcotest.fail "expected image_url object")
       | _ -> Alcotest.fail "expected a one-element content array"));

    Alcotest.test_case "no image keeps the plain string content form" `Quick (fun () ->
      let msg = user_message [ Message.text "hello" ] in
      let fields = json_assoc (Openai_provider.build_message_json msg) in
      (match find_field "content" fields with
       | `String s -> Alcotest.check Alcotest.string "content" "hello" s
       | _ -> Alcotest.fail "expected content to remain a string"));
  ])

let anthropic_tests =
  ( "Anthropic image wire format", [
    Alcotest.test_case "base64 image keeps media_type inside source" `Quick (fun () ->
      let msg = user_message [ Message.image_base64 ~data:"aGk=" ~media_type:"image/jpeg" () ] in
      let fields = json_assoc (Anthropic_provider.build_message_json msg) in
      (match find_field "content" fields with
       | `List [ `Assoc p ] ->
         Alcotest.check Alcotest.string "type" "image" (find_string "type" p);
         (match find_field "source" p with
          | `Assoc src ->
            Alcotest.check Alcotest.string "source type" "base64" (find_string "type" src);
            Alcotest.check Alcotest.string "source media_type" "image/jpeg" (find_string "media_type" src);
            Alcotest.check Alcotest.string "source data" "aGk=" (find_string "data" src)
          | _ -> Alcotest.fail "expected source object")
       | _ -> Alcotest.fail "expected a one-element content array"));

    Alcotest.test_case "url image uses a url source" `Quick (fun () ->
      let msg = user_message [ Message.image_url "https://example.com/a.png" () ] in
      let fields = json_assoc (Anthropic_provider.build_message_json msg) in
      (match find_field "content" fields with
       | `List [ `Assoc p ] ->
         (match find_field "source" p with
          | `Assoc src ->
            Alcotest.check Alcotest.string "source type" "url" (find_string "type" src);
            Alcotest.check Alcotest.string "source url" "https://example.com/a.png" (find_string "url" src)
          | _ -> Alcotest.fail "expected source object")
       | _ -> Alcotest.fail "expected a one-element content array"));
  ])

(* -------------------------------------------------------------------------- *)
(* End-to-end: invoke_content carries image blocks to the provider            *)
(* -------------------------------------------------------------------------- *)

let config_json = {|{"persistence": ["Sqlite", ":memory:"], "event_bus": {"buffer_capacity": 10, "delivery": {"max_delivery_attempts": 3, "initial_retry_delay": 0.1, "retry_backoff": ["Fixed", 0.5], "delivery_timeout": 5.0}, "dlq_enabled": false, "dlq_max_size": 1000, "critical_event_types": []}, "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2, "max_tokens_per_turn": null, "max_total_tokens": null}, "shutdown": {"drain_timeout": 5.0, "cancel_grace_period": 2.0, "flush_batch_size": 100}, "llm_providers": [], "eval_limits": {"max_depth": 10, "max_node_visits": 1000}, "parallel_tool_execution": true}|}

let e2e_tests =
  ( "invoke_content end to end", [
    Alcotest.test_case "image block reaches the provider in the user message" `Quick (fun () ->
      let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
        | Ok c -> c
        | Error msg -> Alcotest.fail ("config parse: " ^ msg)
      in
      Eio_main.run (fun _ ->
        Eio.Switch.run (fun sw ->
          let (llm, history) = Mock_provider.create [Mock_provider.Text "ok"] in
          match Runtime.create ~config ~llm sw with
          | Error _ -> Alcotest.fail "runtime create failed"
          | Ok rt ->
            let model = { provider = `Openai; model_name = "t"; api_base = None;
                          temperature = 0.7; max_tokens = None; top_p = None;
                          stop_sequences = None } in
            let agent = match Runtime.make_agent ~id:"t" ~system_prompt:(stable_prompt "sys") ~model () with
              | Ok a -> a
              | Error _ -> Alcotest.fail "make_agent failed"
            in
            ignore (Runtime.register_agent rt agent);
            let content = [ Message.text "describe this"; Message.image_url "https://example.com/a.png" () ] in
            (match Runtime.invoke_content rt ~agent_id:"t" ~content () with
             | Error _ -> Alcotest.fail "invoke_content failed"
             | Ok _ ->
               (match Mock_provider.last_complete_call history with
                | None -> Alcotest.fail "provider was not called"
                | Some r ->
                  let user_msgs =
                    List.filter (fun (m : message) -> m.role = User) r.Mock_provider.conversation.messages
                  in
                  (match user_msgs with
                   | [] -> Alcotest.fail "no user message in the conversation"
                   | um :: _ ->
                     let has_image =
                       List.exists (function Image_block _ -> true | _ -> false) um.content_blocks
                     in
                     Alcotest.check Alcotest.bool "user message carries the image block" true has_image;
                     let text =
                       um.content_blocks
                       |> List.filter_map (function Text_block { text; _ } -> Some text | _ -> None)
                       |> String.concat ""
                     in
                     Alcotest.check Alcotest.string "text preserved" "describe this" text)));
            ignore (Runtime.close rt))));

    Alcotest.test_case "invoke (string) still produces a text-only user message" `Quick (fun () ->
      let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
        | Ok c -> c
        | Error msg -> Alcotest.fail ("config parse: " ^ msg)
      in
      Eio_main.run (fun _ ->
        Eio.Switch.run (fun sw ->
          let (llm, history) = Mock_provider.create [Mock_provider.Text "ok"] in
          match Runtime.create ~config ~llm sw with
          | Error _ -> Alcotest.fail "runtime create failed"
          | Ok rt ->
            let model = { provider = `Openai; model_name = "t"; api_base = None;
                          temperature = 0.7; max_tokens = None; top_p = None;
                          stop_sequences = None } in
            let agent = match Runtime.make_agent ~id:"t" ~system_prompt:(stable_prompt "sys") ~model () with
              | Ok a -> a
              | Error _ -> Alcotest.fail "make_agent failed"
            in
            ignore (Runtime.register_agent rt agent);
            (match Runtime.invoke rt ~agent_id:"t" ~message:"plain" () with
             | Error _ -> Alcotest.fail "invoke failed"
             | Ok _ ->
               (match Mock_provider.last_complete_call history with
                | None -> Alcotest.fail "provider was not called"
                | Some r ->
                  let user_msgs =
                    List.filter (fun (m : message) -> m.role = User) r.Mock_provider.conversation.messages
                  in
                  (match user_msgs with
                   | [] -> Alcotest.fail "no user message in the conversation"
                   | um :: _ ->
                     let has_image =
                       List.exists (function Image_block _ -> true | _ -> false) um.content_blocks
                     in
                     Alcotest.check Alcotest.bool "no image block" false has_image;
                     Alcotest.check Alcotest.string "text" "plain" (Message.text_of_message um))));
            ignore (Runtime.close rt))));

    Alcotest.test_case "invoke_content with an empty content list still works" `Quick (fun () ->
      let config = match runtime_config_of_yojson (Yojson.Safe.from_string config_json) with
        | Ok c -> c
        | Error msg -> Alcotest.fail ("config parse: " ^ msg)
      in
      Eio_main.run (fun _ ->
        Eio.Switch.run (fun sw ->
          let (llm, _history) = Mock_provider.create [Mock_provider.Text "ok"] in
          match Runtime.create ~config ~llm sw with
          | Error _ -> Alcotest.fail "runtime create failed"
          | Ok rt ->
            let model = { provider = `Openai; model_name = "t"; api_base = None;
                          temperature = 0.7; max_tokens = None; top_p = None;
                          stop_sequences = None } in
            let agent = match Runtime.make_agent ~id:"t" ~system_prompt:(stable_prompt "sys") ~model () with
              | Ok a -> a
              | Error _ -> Alcotest.fail "make_agent failed"
            in
            ignore (Runtime.register_agent rt agent);
            (match Runtime.invoke_content rt ~agent_id:"t" ~content:[] () with
             | Error _ -> Alcotest.fail "invoke_content failed"
             | Ok _ -> Alcotest.check Alcotest.bool "ok" true true);
            ignore (Runtime.close rt))));
  ])

let () =
  Alcotest.run "multimodal"
    [ helper_tests;
      openai_tests;
      anthropic_tests;
      e2e_tests ]
