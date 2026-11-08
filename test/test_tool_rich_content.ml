(* test/test_tool_rich_content.ml — a tool can hand the model content, not just JSON.
 *
 * Before this, a tool's return value was flattened into text, so a model could
 * never see what the tool produced. These tests pin the three layers:
 *
 *   - the wire envelope a foreign (Python) handler returns;
 *   - the provider wire formats for a tool result that carries an image;
 *   - the agent loop: the image reaches the model in the tool result.
 *)

open Par
open Par.Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None; thinking_budget_tokens = None; context_window = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }

let text_response text : llm_response =
  { text = Some text; reasoning = []; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let tool_call_response calls : llm_response =
  { text = None; reasoning = []; tool_calls = Some calls; finish_reason = Tool_calls;
    usage = dummy_usage; model = "mock" }

let runtime_config () : runtime_config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = false;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
  max_tool_schema_tokens = None;
}

let make_agent ?(max_iterations = 3) ?(tools = []) id : agent_config = {
  id;
  system_prompt = stable_prompt "rich content fixture";
  system_prompt_template = None;
  model = dummy_model;
  tools = List.map (fun (tb : tool_binding) -> tb.descriptor) tools;
  max_iterations;
  middleware = [];
  retry_policy = None;
  context_strategy = None;
  resource_quota = None;
  max_execution_time = None;
  early_stopping_method = Force;
  on_max_tokens = None;
  max_continuation_chunks = None;
  tool_timeout = None;
  context_compression_threshold = None;
  compression_cooldown_messages = None;
  context_window_override = None;
  cache_strategy = No_caching;
  approval_handler = None;
}

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

let png_block : content_block =
  match Message.image_base64 ~data:"aGk=" ~media_type:"image/png" () with
  | Ok b -> b
  | Error e -> Alcotest.failf "image_base64: %s" e

(* -------------------------------------------------------------------------- *)
(* The wire envelope                                                           *)
(* -------------------------------------------------------------------------- *)

let envelope_tests =
  ( "tool content envelope", [
    Alcotest.test_case "blocks round-trip through the envelope" `Quick (fun () ->
      let blocks = [ Message.text "a screenshot"; png_block ] in
      let json = Types.tool_content_to_yojson blocks in
      (match find_field Types.tool_content_key (json_assoc json) with
       | `List _ -> ()
       | _ -> Alcotest.fail "envelope does not hold a list");
      (match Types.tool_content_of_yojson json with
       | Result.Ok decoded ->
         Alcotest.(check int) "block count" 2 (List.length decoded);
         (match decoded with
          | Text_block { text; _ } :: rest ->
            Alcotest.(check string) "text preserved" "a screenshot" text;
            (match rest with
             | [ Image_block { media_type; _ } ] ->
               Alcotest.(check string) "media type preserved" "image/png" media_type
             | _ -> Alcotest.fail "expected an image block")
          | _ -> Alcotest.fail "expected a text block first")
       | Result.Error msg -> Alcotest.failf "decode failed: %s" msg));

    Alcotest.test_case "a plain payload is not rich content" `Quick (fun () ->
      match Types.tool_content_of_yojson (`Assoc [ ("stdout", `String "hi") ]) with
      | Result.Ok _ -> Alcotest.fail "a plain payload must not decode as content"
      | Result.Error _ -> ());
  ])

(* -------------------------------------------------------------------------- *)
(* Provider wire formats                                                       *)
(* -------------------------------------------------------------------------- *)

let tool_message blocks : message =
  { role = Tool;
    content_blocks = blocks;
    tool_calls = None;
    tool_call_id = Some "call-1";
    name = Some "shot";
  }

let provider_tests =
  ( "tool result wire formats", [
    Alcotest.test_case "openai uses the array content form" `Quick (fun () ->
      let msg = tool_message [ Message.text "a screenshot"; png_block ] in
      let fields = json_assoc (Openai_provider.build_message_json msg) in
      (match find_field "content" fields with
       | `List parts ->
         Alcotest.(check int) "part count" 2 (List.length parts);
         (match List.nth parts 1 with
          | `Assoc p ->
            Alcotest.(check string) "part type" "image_url" (find_string "type" p)
          | _ -> Alcotest.fail "expected a JSON object")
       | _ -> Alcotest.fail "expected content to be an array"));

    Alcotest.test_case "anthropic uses the tool_result array form" `Quick (fun () ->
      let msg = tool_message [ Message.text "a screenshot"; png_block ] in
      let fields = json_assoc (Anthropic_provider.build_message_json msg) in
      (match find_field "content" fields with
       | `List [ `Assoc tool_result ] ->
         (match find_field "content" tool_result with
          | `List parts ->
            Alcotest.(check int) "part count" 2 (List.length parts);
            (match List.nth parts 1 with
             | `Assoc p ->
               Alcotest.(check string) "part type" "image" (find_string "type" p)
             | _ -> Alcotest.fail "expected a JSON object")
          | `String _ -> Alcotest.fail "a rich tool result must not be flattened to a string"
          | _ -> Alcotest.fail "expected a list or a string")
       | _ -> Alcotest.fail "expected one tool_result block"));

    Alcotest.test_case "a text-only tool result stays a string" `Quick (fun () ->
      let msg = tool_message [ Message.text "just text" ] in
      let fields = json_assoc (Anthropic_provider.build_message_json msg) in
      (match find_field "content" fields with
       | `List [ `Assoc tool_result ] ->
         (match find_field "content" tool_result with
          | `String s -> Alcotest.(check string) "content" "just text" s
          | _ -> Alcotest.fail "expected a string tool result")
       | _ -> Alcotest.fail "expected one tool_result block"));
  ])

(* -------------------------------------------------------------------------- *)
(* The agent loop                                                              *)
(* -------------------------------------------------------------------------- *)

(* The tool produces an image; the model must see it in the tool result. *)
let test_tool_content_reaches_the_model () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let seen = ref None in
  let counter = ref 0 in
  let llm : llm_service = {
    complete_fn = (fun _model _tools conv ->
      incr counter;
      if !counter = 1 then
        Ok (tool_call_response [{ id = "call-1"; name = "shot"; arguments = `Assoc [] }])
      else begin
        seen := Some conv;
        Ok (text_response "done")
      end);
    stream_fn = (fun _ _ _ _ _ -> Ok {
        final_usage = dummy_usage; finish_reason = Stop; chunks_received = 0 });
    close_fn = (fun () -> ());
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None;
    cache_control_fn = None;
  } in
  match Runtime.create ~config:(runtime_config ()) ~llm sw with
  | Error e -> Alcotest.failf "create: %s" (string_of_error_category e)
  | Ok rt ->
    Fun.protect ~finally:(fun () -> ignore (Runtime.close rt)) @@ fun () ->
    let tb = match Runtime.register_tool rt ~name:"shot" ~description:"takes a screenshot"
                    ~input_schema:(`Assoc [])
                    ~handler:(fun _ _ ->
                      Success_content [ Message.text "a screenshot"; png_block ]) () with
      | Ok tb -> tb
      | Error e -> Alcotest.failf "register_tool: %s" (string_of_error_category e)
    in
    ignore (Runtime.register_agent rt (make_agent ~tools:[tb] "shooter"));
    (match Runtime.invoke rt ~agent_id:"shooter" ~message:"take a shot" () with
     | Ok r -> Alcotest.(check (option string)) "response" (Some "done") r.response.text
     | Error (e, _) -> Alcotest.failf "invoke: %s" (string_of_error_category e));
    match !seen with
    | None -> Alcotest.fail "the model was not called twice"
    | Some conv ->
      let tool_msgs =
        List.filter (fun (m : message) -> m.role = Tool) conv.messages in
      Alcotest.(check int) "one tool result" 1 (List.length tool_msgs);
      (match tool_msgs with
       | [ m ] ->
         let has_image =
           List.exists (function Image_block _ -> true | _ -> false) m.content_blocks in
         Alcotest.(check bool) "the image is in the tool result" true has_image;
         let has_text =
           List.exists (function
             | Text_block { text; _ } -> String.length text > 0
             | _ -> false) m.content_blocks in
         Alcotest.(check bool) "the text is in the tool result" true has_text
       | _ -> Alcotest.fail "expected exactly one tool message")

let () =
  Alcotest.run "tool rich content" [
    envelope_tests;
    provider_tests;
    ( "agent loop", [
      Alcotest.test_case "the image reaches the model" `Quick
        test_tool_content_reaches_the_model;
    ] );
  ]
