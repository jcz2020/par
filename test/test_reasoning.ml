(* test/test_reasoning.ml — reasoning blocks and Anthropic extended thinking.
 *
 * Before this, reasoning lived in a `reasoning_content : string option` field
 * on both `llm_response` and `message`. That shape could not carry an
 * Anthropic thinking signature, so a tool-use round-trip would have been
 * rejected, and it kept reasoning outside the content-block model.
 *
 * These tests pin the four contracts that matter:
 *   1. reasoning is a block, and it survives the message JSON round-trip,
 *   2. it does not leak into `text_of_message` (it is not output text),
 *   3. Anthropic parsed blocks keep their signature, and are emitted back
 *      verbatim in the request,
 *   4. the thinking parameter is sent with the temperature/top_p omission and
 *      with Anthropic's own budget limits enforced locally.
 *)

open Par
open Par.Types

(* -------------------------------------------------------------------------- *)
(* Fixtures                                                                   *)
(* -------------------------------------------------------------------------- *)

let dummy_usage = {
  prompt_tokens = 10; completion_tokens = 5; total_tokens = 15;
  cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0;
}

let model ?(thinking = None) ?(max_tokens = Some 4096) () : model_config = {
  provider = `Anthropic;
  model_name = "claude-test";
  api_base = None;
  temperature = 0.7;
  max_tokens;
  top_p = Some 0.9;
  stop_sequences = None;
  thinking_budget_tokens = thinking; context_window = None;
}

let conversation_of messages = { messages; metadata = [] }

let user_msg text : message =
  { role = User;
    content_blocks = [Text_block { text; cache_control = None }];
    tool_calls = None; tool_call_id = None; name = None }

let assistant_msg blocks : message =
  { role = Assistant;
    content_blocks = blocks;
    tool_calls = None; tool_call_id = None; name = None }

let assoc_field name json =
  match json with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let str_field name json =
  match assoc_field name json with Some (`String s) -> Some s | _ -> None

let int_field name json =
  match assoc_field name json with Some (`Int n) -> Some n | _ -> None

(* -------------------------------------------------------------------------- *)
(* Block round-trip                                                           *)
(* -------------------------------------------------------------------------- *)

let test_reasoning_block_roundtrip () =
  let blocks : content_block list =
    [ Reasoning_block { text = "let me think"; signature = Some "sig-abc"; cache_control = None };
      Text_block { text = "answer"; cache_control = None };
      Redacted_reasoning_block { data = "opaque-blob"; cache_control = None } ]
  in
  let msg = assistant_msg blocks in
  match message_of_yojson (message_to_yojson msg) with
  | Error e -> Alcotest.fail ("message round-trip failed: " ^ e)
  | Ok decoded ->
    Alcotest.(check int) "all three blocks survive" 3 (List.length decoded.content_blocks);
    (match decoded.content_blocks with
     | Reasoning_block { text; signature; _ } :: _ ->
       Alcotest.(check string) "reasoning text" "let me think" text;
       Alcotest.(check (option string)) "signature" (Some "sig-abc") signature
     | _ -> Alcotest.fail "expected the reasoning block first");
    (match List.nth decoded.content_blocks 2 with
     | Redacted_reasoning_block { data; _ } ->
       Alcotest.(check string) "redacted payload" "opaque-blob" data
     | _ -> Alcotest.fail "expected the redacted block last")

(* A message persisted by the previous version carries `reasoning_content`.
   Reading it must not fail: the derived parser rejects unknown keys, so
   without a shim every conversation written before v0.13 would be unreadable.
   The text is preserved as an unsigned reasoning block. *)
let test_legacy_reasoning_field_is_migrated () =
  let legacy =
    {|{"role":["Assistant"],
       "content_blocks":[["Text_block",{"text":"old answer","cache_control":null}]],
       "tool_calls":null,"tool_call_id":null,"name":null,
       "reasoning_content":"old reasoning"}|}
  in
  match message_of_yojson (Yojson.Safe.from_string legacy) with
  | Error e -> Alcotest.fail ("legacy message rejected: " ^ e)
  | Ok msg ->
    Alcotest.(check string) "text preserved" "old answer"
      (Message.text_of_message msg);
    (match msg.content_blocks with
     | [Reasoning_block { text; signature; _ }; Text_block _] ->
       Alcotest.(check string) "legacy reasoning kept" "old reasoning" text;
       Alcotest.(check (option string)) "and it is unsigned" None signature
     | other ->
       Alcotest.failf "expected a migrated reasoning block first, got %d blocks"
         (List.length other))

(* The nested path matters too: `conversation_of_yojson` (used by the pending
   approval snapshot) must use the migrating parser, not the derived one. *)
let test_legacy_conversation_loads () =
  let legacy =
    {|{"messages":[
         {"role":["Assistant"],
          "content_blocks":[["Text_block",{"text":"old","cache_control":null}]],
          "tool_calls":null,"tool_call_id":null,"name":null,
          "reasoning_content":"old reasoning"}],
       "metadata":[]}|}
  in
  match conversation_of_yojson (Yojson.Safe.from_string legacy) with
  | Error e -> Alcotest.fail ("legacy conversation rejected: " ^ e)
  | Ok conv ->
    (match conv.messages with
     | [ { content_blocks = [ Reasoning_block _; Text_block _ ]; _ } ] -> ()
     | _ -> Alcotest.fail "nested message did not go through the migrating parser")

(* An unsigned reasoning block must not reach Anthropic: replaying a thinking
   block without its signature is rejected. *)
let test_anthropic_drops_unsigned_reasoning () =
  let msg = assistant_msg
      [ Reasoning_block { text = "from another provider"; signature = None; cache_control = None };
        Text_block { text = "answer"; cache_control = None } ]
  in
  let json = Anthropic_provider.build_message_json msg in
  match assoc_field "content" json with
  | Some (`List blocks) ->
    Alcotest.(check int) "only the text block is sent" 1 (List.length blocks);
    (match blocks with
     | [ b ] -> Alcotest.(check (option string)) "text only" (Some "text") (str_field "type" b)
     | _ -> Alcotest.fail "expected one block")
  | _ -> Alcotest.fail "expected a content list"

let test_text_of_message_ignores_reasoning () =
  let msg = assistant_msg
      [ Reasoning_block { text = "internal monologue"; signature = None; cache_control = None };
        Text_block { text = "visible answer"; cache_control = None } ]
  in
  Alcotest.(check string) "only the text block is output" "visible answer"
    (Message.text_of_message msg)

(* -------------------------------------------------------------------------- *)
(* Anthropic: parsing                                                         *)
(* -------------------------------------------------------------------------- *)

let test_anthropic_parses_thinking_and_redacted () =
  let body =
    {|{"id":"msg_1","model":"claude-test","stop_reason":"tool_use",
       "usage":{"input_tokens":10,"output_tokens":5},
       "content":[
         {"type":"thinking","thinking":"step one","signature":"sig-1"},
         {"type":"redacted_thinking","data":"blob-1"},
         {"type":"text","text":"calling a tool"},
         {"type":"tool_use","id":"tu_1","name":"lookup","input":{"q":"x"}}
       ]}|}
  in
  match Anthropic_provider.parse_llm_response (Yojson.Safe.from_string body) with
  | Error e -> Alcotest.fail ("parse failed: " ^ Types.string_of_error_category e)
  | Ok resp ->
    Alcotest.(check int) "two reasoning blocks" 2 (List.length resp.reasoning);
    (match resp.reasoning with
     | Reasoning_block { text; signature; _ } :: Redacted_reasoning_block { data; _ } :: [] ->
       Alcotest.(check string) "thinking text" "step one" text;
       Alcotest.(check (option string)) "signature kept" (Some "sig-1") signature;
       Alcotest.(check string) "redacted payload kept" "blob-1" data
     | _ -> Alcotest.fail "unexpected reasoning shape");
    Alcotest.(check (option string)) "text" (Some "calling a tool") resp.text;
    Alcotest.(check int) "tool calls"
      1 (List.length (Option.value resp.tool_calls ~default:[]))

(* A response with only thinking is not actionable output. *)
let test_anthropic_reasoning_only_is_rejected () =
  let resp : llm_response =
    { text = None;
      reasoning = [Reasoning_block { text = "hmm"; signature = None; cache_control = None }];
      tool_calls = None; finish_reason = Max_tokens; usage = dummy_usage; model = "m" }
  in
  match llm_response_validate resp with
  | Ok () -> Alcotest.fail "expected a reasoning-only response to be rejected"
  | Error msg ->
    Alcotest.(check bool) "message names the cause" true
      (let needle = "reasoning_only_response" in
       let n = String.length needle in
       let rec go i =
         i + n <= String.length msg
         && (String.sub msg i n = needle || go (i + 1))
       in
       go 0)

(* -------------------------------------------------------------------------- *)
(* Anthropic: request serialisation                                           *)
(* -------------------------------------------------------------------------- *)

let test_anthropic_emits_thinking_blocks_back () =
  let msg = assistant_msg
      [ Reasoning_block { text = "step one"; signature = Some "sig-1"; cache_control = None };
        Redacted_reasoning_block { data = "blob-1"; cache_control = None };
        Text_block { text = "answer"; cache_control = None } ]
  in
  let json = Anthropic_provider.build_message_json msg in
  match assoc_field "content" json with
  | Some (`List blocks) ->
    Alcotest.(check int) "three blocks" 3 (List.length blocks);
    (match List.nth blocks 0 with
     | `Assoc _ as b ->
       Alcotest.(check (option string)) "type" (Some "thinking") (str_field "type" b);
       Alcotest.(check (option string)) "thinking text" (Some "step one")
         (str_field "thinking" b);
       Alcotest.(check (option string)) "signature replayed" (Some "sig-1")
         (str_field "signature" b)
     | _ -> Alcotest.fail "expected an object");
    (match List.nth blocks 1 with
     | `Assoc _ as b ->
       Alcotest.(check (option string)) "redacted type" (Some "redacted_thinking")
         (str_field "type" b);
       Alcotest.(check (option string)) "redacted data" (Some "blob-1")
         (str_field "data" b)
     | _ -> Alcotest.fail "expected an object")
  | _ -> Alcotest.fail "expected a content list"

let test_anthropic_thinking_block_never_gets_cache_control () =
  let msg = assistant_msg
      [ Reasoning_block { text = "t"; signature = Some "s";
                          cache_control = Some { type_ = `Ephemeral; ttl = None } } ]
  in
  let json = Anthropic_provider.build_message_json msg in
  match assoc_field "content" json with
  | Some (`List (block :: _)) ->
    Alcotest.(check (option string)) "no cache_control" None
      (Option.map (fun _ -> "present") (assoc_field "cache_control" block))
  | _ -> Alcotest.fail "expected one block"

let test_anthropic_request_includes_thinking_param () =
  let conv = conversation_of [user_msg "think hard"] in
  let body =
    Anthropic_provider.build_request_body
      ~model_config:(model ~thinking:(Some 2048) ~max_tokens:(Some 8192) ())
      ~tools:[] ~conversation:conv ~stream:false ()
  in
  let json = Yojson.Safe.from_string body in
  (match assoc_field "thinking" json with
   | Some (`Assoc _ as t) ->
     Alcotest.(check (option string)) "enabled" (Some "enabled") (str_field "type" t);
     Alcotest.(check (option int)) "budget" (Some 2048) (int_field "budget_tokens" t)
   | _ -> Alcotest.fail "expected a thinking object");
  (* Anthropic rejects temperature and top_p alongside thinking. *)
  Alcotest.(check (option string)) "temperature omitted" None
    (Option.map (fun _ -> "present") (assoc_field "temperature" json));
  Alcotest.(check (option string)) "top_p omitted" None
    (Option.map (fun _ -> "present") (assoc_field "top_p" json))

let test_anthropic_request_without_thinking_keeps_sampling () =
  let conv = conversation_of [user_msg "hello"] in
  let body =
    Anthropic_provider.build_request_body
      ~model_config:(model ()) ~tools:[] ~conversation:conv ~stream:false ()
  in
  let json = Yojson.Safe.from_string body in
  Alcotest.(check (option string)) "no thinking object" None
    (Option.map (fun _ -> "present") (assoc_field "thinking" json));
  Alcotest.(check bool) "temperature present" true
    (Option.is_some (assoc_field "temperature" json));
  Alcotest.(check bool) "top_p present" true (Option.is_some (assoc_field "top_p" json))

let test_anthropic_budget_limits () =
  let expect_error label cfg =
    match Anthropic_provider.check_thinking cfg with
    | Ok () -> Alcotest.fail (label ^ ": expected an error")
    | Error (Invalid_input msg) ->
      Alcotest.(check bool) (label ^ ": message is non-empty") true (msg <> "")
    | Error other ->
      Alcotest.fail (label ^ ": expected Invalid_input, got "
                     ^ Types.string_of_error_category other)
  in
  expect_error "below the 1024 minimum" (model ~thinking:(Some 512) ());
  expect_error "not smaller than max_tokens"
    (model ~thinking:(Some 4096) ~max_tokens:(Some 4096) ());
  (match Anthropic_provider.check_thinking
           (model ~thinking:(Some 1024) ~max_tokens:(Some 4096) ()) with
   | Ok () -> ()
   | Error e -> Alcotest.fail ("valid budget rejected: " ^ Types.string_of_error_category e));
  (match Anthropic_provider.check_thinking (model ()) with
   | Ok () -> ()
   | Error e -> Alcotest.fail ("thinking off should be valid: " ^ Types.string_of_error_category e))

(* -------------------------------------------------------------------------- *)
(* Anthropic: streaming                                                       *)
(* -------------------------------------------------------------------------- *)

let test_anthropic_stream_thinking_and_signature () =
  let chunks = ref [] in
  let usage = ref dummy_usage in
  let finish = ref Stop in
  let count = ref 0 in
  let current_tc = ref "" in
  let sink chunk = chunks := chunk :: !chunks in
  let send evt data =
    Anthropic_provider.process_stream_event (evt, data) sink usage finish count current_tc
  in
  send "content_block_delta"
    {|{"index":0,"delta":{"type":"thinking_delta","thinking":"step "}}|};
  send "content_block_delta"
    {|{"index":0,"delta":{"type":"thinking_delta","thinking":"one"}}|};
  send "content_block_delta"
    {|{"index":0,"delta":{"type":"signature_delta","signature":"sig-stream"}}|};
  let delta_text =
    List.filter_map (function
        | Reasoning_delta { text } -> Some text
        | _ -> None) (List.rev !chunks)
    |> String.concat ""
  in
  Alcotest.(check string) "thinking deltas forwarded" "step one" delta_text;
  let signatures =
    List.filter_map (function
        | Reasoning_signature { signature } -> Some signature
        | _ -> None) (List.rev !chunks)
  in
  Alcotest.(check (list string)) "signature delta forwarded" ["sig-stream"] signatures

(* -------------------------------------------------------------------------- *)

let () =
  Alcotest.run "reasoning" [
    "blocks", [
      Alcotest.test_case "reasoning and redacted blocks round-trip" `Quick
        test_reasoning_block_roundtrip;
      Alcotest.test_case "legacy reasoning_content field is migrated" `Quick
        test_legacy_reasoning_field_is_migrated;
      Alcotest.test_case "nested legacy conversation loads" `Quick
        test_legacy_conversation_loads;
      Alcotest.test_case "text_of_message ignores reasoning" `Quick
        test_text_of_message_ignores_reasoning;
    ];
    "anthropic_parse", [
      Alcotest.test_case "thinking and redacted blocks are parsed" `Quick
        test_anthropic_parses_thinking_and_redacted;
      Alcotest.test_case "reasoning-only response is rejected" `Quick
        test_anthropic_reasoning_only_is_rejected;
    ];
    "anthropic_request", [
      Alcotest.test_case "thinking blocks are emitted back" `Quick
        test_anthropic_emits_thinking_blocks_back;
      Alcotest.test_case "thinking never carries cache_control" `Quick
        test_anthropic_thinking_block_never_gets_cache_control;
      Alcotest.test_case "unsigned reasoning is not replayed" `Quick
        test_anthropic_drops_unsigned_reasoning;
      Alcotest.test_case "thinking parameter is sent" `Quick
        test_anthropic_request_includes_thinking_param;
      Alcotest.test_case "sampling params stay when thinking is off" `Quick
        test_anthropic_request_without_thinking_keeps_sampling;
      Alcotest.test_case "budget limits are enforced" `Quick
        test_anthropic_budget_limits;
    ];
    "streaming", [
      Alcotest.test_case "thinking and signature deltas are forwarded" `Quick
        test_anthropic_stream_thinking_and_signature;
    ];
  ]
