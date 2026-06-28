(* Tests for Tool_prompt — prompt rendering and synthesized-call parsing.
   PAR-k38 (T0.5). No engine/provider wiring; pure module. *)

open Par
open Types

(* -------------------------------------------------------------------------- *)
(* Fixtures                                                                  *)
(* -------------------------------------------------------------------------- *)

let dummy_permission = Allow

let dummy_descriptor ~name ~description ~schema : tool_descriptor =
  {
    name;
    description;
    input_schema = schema;
    output_schema = None;
    permission = dummy_permission;
    timeout = None;
    concurrency_limit = None;
    on_update = None;
  }

let echo_tool =
  dummy_descriptor
    ~name:"echo"
    ~description:"Echoes the input string back."
    ~schema:(`Assoc [("type", `String "object");
                    ("properties",
                     `Assoc [("message", `Assoc [("type", `String "string")])]);
                    ("required", `List [`String "message"])])

let calc_tool =
  dummy_descriptor
    ~name:"calc"
    ~description:"Evaluates a math expression."
    ~schema:(`Assoc [("type", `String "object");
                    ("properties",
                     `Assoc [("expr", `Assoc [("type", `String "string")])])])

let tool_call_pp fmt (tc : tool_call) =
  Format.fprintf fmt "{id=%s; name=%s; arguments=%s}"
    tc.id tc.name (Yojson.Safe.to_string tc.arguments)

let tool_call_testable : tool_call Alcotest.testable =
  Alcotest.testable tool_call_pp (=)

(* -------------------------------------------------------------------------- *)
(* Suite                                                                     *)
(* -------------------------------------------------------------------------- *)

let render_then_parse_roundtrip () =
  (* GIVEN: a list of two tool descriptors. *)
  let tools = [echo_tool; calc_tool] in
  (* WHEN: render to prompt text (just to exercise the renderer), then parse
     a realistic model response. Real model responses do NOT echo the prompt
     back — only the LLM's reply text. Including the prompt in the parser
     input would let the example JSON inside the header leak into the parser
     output, so we keep the two concerns separate. *)
  let _prompt = Tool_prompt.descriptors_to_prompt_text tools in
  let model_text =
    "Sure, calling echo and calc:\n\n```json\n\
     {\"tool_calls\": [\
      {\"name\": \"echo\", \"arguments\": {\"message\": \"hi\"}},\
      {\"name\": \"calc\", \"arguments\": {\"expr\": \"2+2\"}}]}\n\
     ```\n"
  in
  let parsed = Tool_prompt.parse_tool_calls_from_text model_text in
  (* THEN: parsed list has 2 calls with matching name + arguments. *)
  Alcotest.(check int) "two calls parsed" 2 (List.length parsed);
  let first, second = match parsed with
    | a :: b :: _ -> a, b
    | _ -> Alcotest.fail "expected at least 2 parsed calls"
  in
  Alcotest.(check string) "first name" "echo" first.name;
  Alcotest.(check string) "second name" "calc" second.name;
  Alcotest.(check string) "first arguments"
    "{\"message\":\"hi\"}" (Yojson.Safe.to_string first.arguments);
  Alcotest.(check string) "second arguments"
    "{\"expr\":\"2+2\"}" (Yojson.Safe.to_string second.arguments);
  (* Empty id — engine layer (T3.1) assigns the real id. *)
  Alcotest.(check string) "id is empty (engine-assigned)" "" first.id

let parse_handles_json_fences () =
  let input = "Here you go:\n```json\n\
              {\"tool_calls\": [{\"name\": \"echo\", \"arguments\": {\"x\": 1}}]}\n\
              ```\n"
  in
  let parsed = Tool_prompt.parse_tool_calls_from_text input in
  Alcotest.(check int) "one call parsed" 1 (List.length parsed);
  match parsed with
  | [tc] ->
    Alcotest.(check string) "name" "echo" tc.name;
    Alcotest.(check string) "arguments"
      "{\"x\":1}" (Yojson.Safe.to_string tc.arguments)
  | _ -> Alcotest.fail "expected exactly one call"

let parse_handles_bare_json () =
  let input = "{\"tool_calls\": [{\"name\": \"calc\", \"arguments\": {\"y\": 42}}]}"
  in
  let parsed = Tool_prompt.parse_tool_calls_from_text input in
  Alcotest.(check int) "one call parsed" 1 (List.length parsed);
  match parsed with
  | [tc] ->
    Alcotest.(check string) "name" "calc" tc.name;
    Alcotest.(check string) "arguments"
      "{\"y\":42}" (Yojson.Safe.to_string tc.arguments)
  | _ -> Alcotest.fail "expected exactly one call"

let parse_malformed_returns_empty () =
  (* GIVEN: completely non-JSON garbage. *)
  (* WHEN: parse. *)
  let parsed = Tool_prompt.parse_tool_calls_from_text "not json at all" in
  (* THEN: empty list, NO exception thrown. *)
  Alcotest.(check (list tool_call_testable)) "empty list" [] parsed

let parse_empty_descriptors_renders_header_or_empty () =
  (* GIVEN: no tool descriptors. *)
  (* WHEN: render. *)
  let prompt = Tool_prompt.descriptors_to_prompt_text [] in
  (* THEN: prompt is non-empty (header) but contains no per-tool sections.
     The header itself uses "## " (H2), so we look for the per-tool "### "
     marker which only appears when there are tools. *)
  let has_per_tool_section =
    try
      let _ = Str.search_forward (Str.regexp_string "### ") prompt 0 in true
    with Not_found -> false
  in
  Alcotest.(check bool) "non-empty header" true (String.length prompt > 0);
  Alcotest.(check bool) "no per-tool '### ' section markers"
    false has_per_tool_section;
  (* AND: parsing a model reply that contains no tool_calls works fine. *)
  let parsed = Tool_prompt.parse_tool_calls_from_text
    "{\"tool_calls\": []}"
  in
  Alcotest.(check (list tool_call_testable)) "empty parsed list" [] parsed

let suite =
  ("tool_prompt", [
    Alcotest.test_case "render_then_parse_roundtrip"        `Quick render_then_parse_roundtrip;
    Alcotest.test_case "parse_handles_json_fences"          `Quick parse_handles_json_fences;
    Alcotest.test_case "parse_handles_bare_json"            `Quick parse_handles_bare_json;
    Alcotest.test_case "parse_malformed_returns_empty"       `Quick parse_malformed_returns_empty;
    Alcotest.test_case "parse_empty_descriptors"            `Quick parse_empty_descriptors_renders_header_or_empty;
  ])

let () = Alcotest.run "test_tool_prompt" [suite]