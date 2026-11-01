open Par
open Types

let mk_tool ?(cache_control = None) name : tool_descriptor = {
  name; description = "test"; input_schema = `Assoc [];
  output_schema = None; permission = Allow; timeout = None;
  concurrency_limit = None; on_update = None; cache_control;
}

let dummy_conv : conversation = {
  messages = [
    { role = System; content_blocks = [Text_block { text = "sys"; cache_control = None }];
      tool_calls = None; tool_call_id = None; name = None };
    { role = User; content_blocks = [Text_block { text = "hi"; cache_control = None }];
      tool_calls = None; tool_call_id = None; name = None };
  ];
  metadata = [];
}

let bp_location (bp : Cache_breakpoint.breakpoint) = bp.location
let bp_ttl (bp : Cache_breakpoint.breakpoint) = bp.ttl

let test_no_marked_tools () =
  let tools = [ mk_tool "a"; mk_tool "b" ] in
  let cands = Engine.build_breakpoint_candidates ~ttl:`Five_min ~tools ~conv:dummy_conv in
  let marked = List.filter (fun (bp : Cache_breakpoint.breakpoint) ->
    bp.priority = 60) cands in
  Alcotest.check Alcotest.int "no marked candidates" 0 (List.length marked);
  Alcotest.check Alcotest.bool "has system candidate" true
    (List.exists (fun bp -> bp_location bp = `System) cands);
  let tool_cands = List.filter (fun (bp : Cache_breakpoint.breakpoint) ->
    match bp.location with `Tool _ -> true | _ -> false) cands in
  Alcotest.check Alcotest.int "no auto-guessed tool candidates" 0 (List.length tool_cands)

let test_one_marked_tool () =
  let cc = Some { type_ = `Ephemeral; ttl = Some `Five_min } in
  let tools = [ mk_tool "a"; mk_tool ~cache_control:cc "b" ] in
  let cands = Engine.build_breakpoint_candidates ~ttl:`Five_min ~tools ~conv:dummy_conv in
  let marked = List.filter (fun (bp : Cache_breakpoint.breakpoint) ->
    bp.priority = 60) cands in
  Alcotest.check Alcotest.int "one marked candidate" 1 (List.length marked);
  let bp = List.hd marked in
  Alcotest.check Alcotest.bool "location is Tool 1" true (bp_location bp = `Tool 1);
  Alcotest.check Alcotest.bool "ttl is Five_min" true (bp_ttl bp = `Five_min)

let test_multiple_marked_tools () =
  let cc1 = Some { type_ = `Ephemeral; ttl = Some `Five_min } in
  let cc2 = Some { type_ = `Ephemeral; ttl = Some `One_hour } in
  let tools = [ mk_tool ~cache_control:cc1 "a"; mk_tool "b"; mk_tool ~cache_control:cc2 "c" ] in
  let cands = Engine.build_breakpoint_candidates ~ttl:`Five_min ~tools ~conv:dummy_conv in
  let marked = List.filter (fun (bp : Cache_breakpoint.breakpoint) ->
    bp.priority = 60) cands in
  Alcotest.check Alcotest.int "two marked candidates" 2 (List.length marked);
  Alcotest.check Alcotest.bool "has Tool 0" true
    (List.exists (fun bp -> bp_location bp = `Tool 0) marked);
  Alcotest.check Alcotest.bool "has Tool 2" true
    (List.exists (fun bp -> bp_location bp = `Tool 2) marked)

let test_marked_tool_one_hour_ttl () =
  let cc = Some { type_ = `Ephemeral; ttl = Some `One_hour } in
  let tools = [ mk_tool ~cache_control:cc "a" ] in
  let cands = Engine.build_breakpoint_candidates ~ttl:`Five_min ~tools ~conv:dummy_conv in
  let marked = List.filter (fun (bp : Cache_breakpoint.breakpoint) ->
    bp.priority = 60) cands in
  Alcotest.check Alcotest.int "one marked candidate" 1 (List.length marked);
  let bp = List.hd marked in
  Alcotest.check Alcotest.bool "ttl is One_hour" true (bp_ttl bp = `One_hour)

let test_mixed_marked_unmarked () =
  let cc = Some { type_ = `Ephemeral; ttl = Some `Five_min } in
  let tools = [ mk_tool "a"; mk_tool ~cache_control:cc "b"; mk_tool "c"; mk_tool "d" ] in
  let cands = Engine.build_breakpoint_candidates ~ttl:`Five_min ~tools ~conv:dummy_conv in
  let marked = List.filter (fun (bp : Cache_breakpoint.breakpoint) ->
    bp.priority = 60) cands in
  Alcotest.check Alcotest.int "one marked candidate" 1 (List.length marked);
  let bp = List.hd marked in
  Alcotest.check Alcotest.bool "location is Tool 1" true (bp_location bp = `Tool 1)

let () =
  Alcotest.run "Engine build_breakpoint_candidates" [
    "marked_tools", [
      Alcotest.test_case "no marked tools" `Quick test_no_marked_tools;
      Alcotest.test_case "one marked tool" `Quick test_one_marked_tool;
      Alcotest.test_case "multiple marked tools" `Quick test_multiple_marked_tools;
      Alcotest.test_case "marked tool One_hour ttl" `Quick test_marked_tool_one_hour_ttl;
      Alcotest.test_case "mixed marked + unmarked" `Quick test_mixed_marked_unmarked;
    ];
  ]
