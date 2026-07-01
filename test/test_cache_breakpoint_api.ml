open Par
open Types

let dummy_tool : tool_descriptor = {
  name = "test_tool";
  description = "A test tool";
  input_schema = `Assoc [];
  output_schema = None;
  permission = Allow;
  timeout = None;
  concurrency_limit = None;
  on_update = None;
  cache_control = None;
}

let dummy_message ?(blocks = [Text_block { text = "hello"; cache_control = None }]) () : message = {
  role = User;
  content_blocks = blocks;
  tool_calls = None;
  tool_call_id = None;
  name = None;
}

let cc_equals ?ttl (cc : cache_control option) =
  match cc with
  | Some { type_ = `Ephemeral; ttl = t } ->
    begin match ttl, t with
    | Some expected, Some actual -> expected = actual
    | None, None -> true
    | _ -> false
    end
  | _ -> false

let test_mark_tool_five_min () =
  let marked = Cache_breakpoint.mark_tool ~ttl:`Five_min dummy_tool in
  Alcotest.(check bool) "cache_control set" true (cc_equals ~ttl:`Five_min marked.cache_control);
  Alcotest.(check string) "name preserved" "test_tool" marked.name

let test_mark_tool_one_hour () =
  let marked = Cache_breakpoint.mark_tool ~ttl:`One_hour dummy_tool in
  Alcotest.(check bool) "cache_control set" true (cc_equals ~ttl:`One_hour marked.cache_control)

let test_mark_tool_preserves_fields () =
  let marked = Cache_breakpoint.mark_tool ~ttl:`Five_min dummy_tool in
  Alcotest.(check string) "description matches" "A test tool" marked.description;
  Alcotest.(check (option (float 0.))) "timeout preserved" None marked.timeout;
  Alcotest.(check (option int)) "concurrency_limit preserved" None marked.concurrency_limit

let test_mark_message_single_block () =
  let msg = dummy_message () in
  let marked = Cache_breakpoint.mark_message ~ttl:`Five_min msg in
  match marked.content_blocks with
  | [Text_block b] ->
    Alcotest.(check bool) "text block marked" true (cc_equals ~ttl:`Five_min b.cache_control);
    Alcotest.(check string) "text preserved" "hello" b.text
  | _ -> Alcotest.fail "expected single Text_block"

let test_mark_message_multiple_blocks () =
  let blocks = [
    Text_block { text = "first"; cache_control = None };
    Text_block { text = "second"; cache_control = None };
    Text_block { text = "last"; cache_control = None };
  ] in
  let msg = dummy_message ~blocks () in
  let marked = Cache_breakpoint.mark_message ~ttl:`One_hour msg in
  match marked.content_blocks with
  | [Text_block a; Text_block b; Text_block c] ->
    Alcotest.(check (option string)) "first unmarked" None (Option.map (fun _ -> "set") a.cache_control);
    Alcotest.(check (option string)) "second unmarked" None (Option.map (fun _ -> "set") b.cache_control);
    Alcotest.(check bool) "last marked" true (cc_equals ~ttl:`One_hour c.cache_control)
  | _ -> Alcotest.fail "expected three Text_blocks"

let test_mark_message_empty_blocks () =
  let msg = dummy_message ~blocks:[] () in
  let marked = Cache_breakpoint.mark_message ~ttl:`Five_min msg in
  Alcotest.(check int) "empty stays empty" 0 (List.length marked.content_blocks)

let test_mark_message_tool_result_block () =
  let blocks = [
    Tool_result_block { tool_use_id = "tr1"; content = "result"; cache_control = None };
  ] in
  let msg = dummy_message ~blocks () in
  let marked = Cache_breakpoint.mark_message ~ttl:`Five_min msg in
  match marked.content_blocks with
  | [Tool_result_block b] ->
    Alcotest.(check bool) "tool_result marked" true (cc_equals ~ttl:`Five_min b.cache_control);
    Alcotest.(check string) "content preserved" "result" b.content
  | _ -> Alcotest.fail "expected Tool_result_block"

let test_mark_message_preserves_fields () =
  let msg : message = {
    role = Assistant;
    content_blocks = [Text_block { text = "hi"; cache_control = None }];
    tool_calls = None;
    tool_call_id = Some "tc1";
    name = Some "bot";
  } in
  let marked = Cache_breakpoint.mark_message ~ttl:`One_hour msg in
  Alcotest.(check string) "role preserved" "Assistant" (match marked.role with Assistant -> "Assistant" | _ -> "other");
  Alcotest.(check (option string)) "tool_call_id preserved" (Some "tc1") marked.tool_call_id;
  Alcotest.(check (option string)) "name preserved" (Some "bot") marked.name;
  Alcotest.(check bool) "block marked" true
    (match marked.content_blocks with
     | [Text_block b] -> cc_equals ~ttl:`One_hour b.cache_control
     | _ -> false)

let () =
  Alcotest.run "cache-breakpoint-api" [
    "mark-tool", [
      Alcotest.test_case "five_min sets cache_control" `Quick test_mark_tool_five_min;
      Alcotest.test_case "one_hour sets cache_control" `Quick test_mark_tool_one_hour;
      Alcotest.test_case "preserves other fields" `Quick test_mark_tool_preserves_fields;
    ];
    "mark-message", [
      Alcotest.test_case "single block marked" `Quick test_mark_message_single_block;
      Alcotest.test_case "multiple blocks: only last marked" `Quick test_mark_message_multiple_blocks;
      Alcotest.test_case "empty blocks: no-op" `Quick test_mark_message_empty_blocks;
      Alcotest.test_case "tool_result_block marked" `Quick test_mark_message_tool_result_block;
      Alcotest.test_case "preserves other fields" `Quick test_mark_message_preserves_fields;
    ];
  ]
