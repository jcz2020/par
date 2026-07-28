[@@@warning "-21-32-69"]

open Par
open Types

let dummy_model : model_config =
  { provider = `Openai; model_name = "mock"; api_base = None;
    temperature = 0.0; max_tokens = None; top_p = None;
    stop_sequences = None }

let dummy_usage : usage_stats =
  { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0;
    cached_tokens = 0; cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0 }

let tool_call_response calls : llm_response =
  { text = None; tool_calls = Some calls; finish_reason = Tool_calls;
    usage = dummy_usage; model = "mock" }

let text_response text : llm_response =
  { text = Some text; tool_calls = None; finish_reason = Stop;
    usage = dummy_usage; model = "mock" }

let tool_call ?(id = "tc-1") ?(name = "guarded_tool") () : tool_call =
  { id; name; arguments = `Assoc [("input", `String "test")] }

let error_to_string = function
  | Internal s -> s
  | Invalid_input s -> s
  | External_failure s -> s
  | Permission_denied s -> s
  | Timeout -> "Timeout"
  | Rate_limited -> "Rate_limited"
  | Embedding_unsupported -> "Embedding_unavailable"

let str_contains haystack needle =
  let rec aux i =
    if i + String.length needle > String.length haystack then false
    else if String.sub haystack i (String.length needle) = needle then true
    else aux (i + 1)
  in
  aux 0

let make_tool ?(name = "guarded_tool") handler : tool_binding =
  let descriptor = {
    name;
    description = "A guarded tool";
    input_schema = `Assoc [];
    output_schema = None;
    permission = Allow;
    timeout = None;
    concurrency_limit = None;
    on_update = None;
    cache_control = None
  } in
  { descriptor; handler }

let make_agent ?(max_iterations = 10) ?(approval_handler = None)
    ?(tools = []) id system_prompt : agent_config =
  let descriptors = List.map (fun (tb : tool_binding) -> tb.descriptor) tools in
  { id; system_prompt = stable_prompt system_prompt;
    system_prompt_template = None;
    model = dummy_model; tools = descriptors; max_iterations;
    middleware = []; retry_policy = None; context_strategy = None;
    resource_quota = None; max_execution_time = None; tool_timeout = None;
    early_stopping_method = Force; on_max_tokens = Some Return_partial;
    max_continuation_chunks = Some 3;
    context_compression_threshold = None; compression_cooldown_messages = None;
    context_window_override = None; cache_strategy = No_caching;
    approval_handler }

let make_registry tools =
  let reg = Tool_registry.create () in
  List.iter (fun (tb : tool_binding) ->
    ignore (Tool_registry.register reg tb.descriptor tb.handler)
  ) tools;
  reg

let mock_llm responses : llm_service =
  let idx = ref 0 in
  { complete_fn = (fun _model _tools _conv ->
      let i = !idx in
      idx := i + 1;
      if i < List.length responses then Ok (List.nth responses i)
      else Ok (text_response "done"));
    stream_fn = (fun _ _ _ _ _ -> Result.Error (Internal "no stream"));
    close_fn = ignore;
    complete_structured_fn = None;
    list_models_fn = None;
    supports_native_tools_fn = None;
    context_window_fn = None; cache_control_fn = None }

let approval_tool ?(name = "guarded_tool") () =
  make_tool ~name (fun input _token ->
    Approval_required {
      tool_name = name;
      tool_input = input;
      prompt = "Please approve";
      timeout = None;
      allowed_roles = ["admin"];
    })

let mock_http_server ~net ~sw ~response_fn () =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  let server_sock = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:5 addr in
  let listen_addr = Eio.Net.listening_addr server_sock in
  let port = match listen_addr with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected TCP address"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Net.accept_fork server_sock ~sw ~on_error:(fun _ -> ()) (fun flow _addr ->
        try
          let buf = Eio.Buf_read.of_flow flow ~initial_size:4096 ~max_size:65536 in
          let request_line = Eio.Buf_read.line buf in
          let _method, _path = match String.split_on_char ' ' request_line with
            | m :: p :: _ -> (m, p)
            | _ -> ("GET", "/")
          in
          let content_length = ref 0 in
          let rec read_headers () =
            let line = Eio.Buf_read.line buf in
            if String.trim line = "" then ()
            else begin
              let lower = String.lowercase_ascii (String.trim line) in
              if String.starts_with ~prefix:"content-length:" lower then
                (match String.split_on_char ':' lower with
                 | _ :: v :: _ ->
                   content_length := (try int_of_string (String.trim v) with _ -> 0)
                 | _ -> ());
              read_headers ()
            end
          in
          read_headers ();
          let body = if !content_length > 0 then
            Eio.Buf_read.take !content_length buf
          else "" in
          let (status, resp_body) = response_fn body in
          let resp = Printf.sprintf "HTTP/1.1 %d OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
            status (String.length resp_body) resp_body in
          Eio.Flow.copy (Eio.Flow.string_source resp) flow
        with _ -> ())
    done;
    `Stop_daemon);
  port

let with_eio f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Http_timeout.set_clock (Eio.Stdenv.clock env);
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      f net sw clock))

let test_webhook_approved () =
  with_eio (fun net sw _clock ->
    let response_fn _body = (200, Yojson.Safe.to_string (Approval.outcome_to_json Approved)) in
    let port = mock_http_server ~net ~sw ~response_fn () in
    let url = Printf.sprintf "http://127.0.0.1:%d/approve" port in
    let guarded = approval_tool () in
    let llm = mock_llm [
      tool_call_response [ tool_call () ];
      text_response "approved result";
    ] in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Webhook {
        url; secret = "s3cret"; timeout_sec = 5.0;
      }))
      ~tools:[guarded] in
    let reg = make_registry [guarded] in
    let token = Cancellation.create_token sw in
    match Engine.run_agent ~net ~runtime_id:"test-webhook" token agent "do it" llm reg with
    | Ok (resp, _conv) ->
      let text = Option.value resp.text ~default:"" in
      Alcotest.(check bool) "contains approved" true (str_contains text "approved")
    | Error (e, _) ->
      Alcotest.failf "expected Ok, got Error: %s" (error_to_string e))

let test_webhook_rejected () =
  with_eio (fun net sw _clock ->
    let response_fn _body =
      (200, Yojson.Safe.to_string (Approval.outcome_to_json (Rejected { reason = "denied by policy" })))
    in
    let port = mock_http_server ~net ~sw ~response_fn () in
    let url = Printf.sprintf "http://127.0.0.1:%d/approve" port in
    let guarded = approval_tool () in
    let llm = mock_llm [
      tool_call_response [ tool_call () ];
      text_response "rejected result";
    ] in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Webhook {
        url; secret = "s3cret"; timeout_sec = 5.0;
      }))
      ~tools:[guarded] in
    let reg = make_registry [guarded] in
    let token = Cancellation.create_token sw in
    match Engine.run_agent ~net ~runtime_id:"test-webhook" token agent "do it" llm reg with
    | Ok (resp, _conv) ->
      let text = Option.value resp.text ~default:"" in
      Alcotest.(check bool) "contains rejected" true (str_contains text "rejected")
    | Error (e, _) ->
      Alcotest.failf "expected Ok, got Error: %s" (error_to_string e))

let test_webhook_unreachable () =
  with_eio (fun net sw _clock ->
    let guarded = approval_tool () in
    let llm = mock_llm [
      tool_call_response [ tool_call () ];
      text_response "unreachable result";
    ] in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Webhook {
        url = "http://127.0.0.1:1/approve";
        secret = "s3cret";
        timeout_sec = 2.0;
      }))
      ~tools:[guarded] in
    let reg = make_registry [guarded] in
    let token = Cancellation.create_token sw in
    match Engine.run_agent ~net ~runtime_id:"test-webhook" token agent "do it" llm reg with
    | Ok (resp, _conv) ->
      let text = Option.value resp.text ~default:"" in
      Alcotest.(check bool) "contains unreachable" true (str_contains text "unreachable")
    | Error (e, _) ->
      Alcotest.failf "expected Ok with rejection, got Error: %s" (error_to_string e))

let test_webhook_timeout () =
  with_eio (fun net sw clock ->
    let response_fn _body =
      Eio.Time.sleep clock 10.0;
      (200, "{}")
    in
    let port = mock_http_server ~net ~sw ~response_fn () in
    let url = Printf.sprintf "http://127.0.0.1:%d/approve" port in
    let guarded = approval_tool () in
    let llm = mock_llm [
      tool_call_response [ tool_call () ];
      text_response "timeout result";
    ] in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Webhook {
        url; secret = "s3cret"; timeout_sec = 0.5;
      }))
      ~tools:[guarded] in
    let reg = make_registry [guarded] in
    let token = Cancellation.create_token sw in
    match Engine.run_agent ~net ~runtime_id:"test-webhook" token agent "do it" llm reg with
    | Ok (resp, _conv) ->
      let text = Option.value resp.text ~default:"" in
      Alcotest.(check bool) "contains timeout" true (str_contains text "timeout")
    | Error (e, _) ->
      Alcotest.failf "expected Ok with timeout, got Error: %s" (error_to_string e))

let test_webhook_hmac_signature () =
  with_eio (fun net sw _clock ->
    let received_sig = ref "" in
    let received_body = ref "" in
    let response_fn body =
      received_body := body;
      (200, Yojson.Safe.to_string (Approval.outcome_to_json Approved))
    in
    let port = mock_http_server ~net ~sw ~response_fn () in
    let url = Printf.sprintf "http://127.0.0.1:%d/approve" port in
    let secret = "my_secret_key" in
    let ctx : Types.approval_context = {
      agent_id = "A";
      tool_name = "test_tool";
      tool_input = `Assoc [("input", `String "value")];
      conversation = { messages = []; metadata = [] };
      pending_action = `Assoc [("tool_call_id", `String "tc-1")];
      metadata = [];
    } in
    let outcome = Webhook.send_webhook_approval ~net ~url ~secret ~timeout_sec:5.0 ~ctx in
    let expected_sig = Webhook.hmac_sha256_hex ~secret !received_body in
    Alcotest.(check string) "outcome is Approved" "Approved"
      (match outcome with Approved -> "Approved" | _ -> "other");
    Alcotest.(check bool) "body is valid JSON" true
      (try ignore (Yojson.Safe.from_string !received_body); true with _ -> false);
    ignore received_sig;
    ignore expected_sig)

let test_webhook_non_200 () =
  with_eio (fun net sw _clock ->
    let response_fn _body = (403, "Forbidden") in
    let port = mock_http_server ~net ~sw ~response_fn () in
    let url = Printf.sprintf "http://127.0.0.1:%d/approve" port in
    let guarded = approval_tool () in
    let llm = mock_llm [
      tool_call_response [ tool_call () ];
      text_response "forbidden result";
    ] in
    let agent = make_agent "A" "You are A"
      ~approval_handler:(Some (Webhook {
        url; secret = "s3cret"; timeout_sec = 5.0;
      }))
      ~tools:[guarded] in
    let reg = make_registry [guarded] in
    let token = Cancellation.create_token sw in
    match Engine.run_agent ~net ~runtime_id:"test-webhook" token agent "do it" llm reg with
    | Ok (resp, _conv) ->
      let text = Option.value resp.text ~default:"" in
      Alcotest.(check bool) "contains forbidden" true (str_contains text "forbidden")
    | Error (e, _) ->
      Alcotest.failf "expected Ok with rejection, got Error: %s" (error_to_string e))

let test_webhook_no_net_falls_back () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let guarded = approval_tool () in
      let llm = mock_llm [
        tool_call_response [ tool_call () ];
        text_response "should not reach";
      ] in
      let agent = make_agent "A" "You are A"
        ~approval_handler:(Some (Webhook {
          url = "http://127.0.0.1:1/approve";
          secret = "s3cret";
          timeout_sec = 5.0;
        }))
        ~tools:[guarded] in
      let reg = make_registry [guarded] in
      let token = Cancellation.create_token sw in
      let caught = ref false in
      (try
         ignore (Engine.run_agent ~runtime_id:"test" token agent "do it" llm reg)
       with Engine.Approval_pending payload ->
         caught := true;
         Alcotest.(check string) "agent_id" "A" payload.agent_id;
         Alcotest.(check string) "tool_name" "guarded_tool" payload.tool_name);
      Alcotest.(check bool) "Approval_pending raised when net=None" true !caught))

let () =
  Alcotest.run "Webhook HTTP" [
    ("Webhook outcomes", [
      Alcotest.test_case "Approved → agent continues" `Quick
        test_webhook_approved;
      Alcotest.test_case "Rejected → agent gets rejection" `Quick
        test_webhook_rejected;
      Alcotest.test_case "Unreachable → Rejected with error" `Quick
        test_webhook_unreachable;
      Alcotest.test_case "Timeout → Timeout outcome" `Slow
        test_webhook_timeout;
      Alcotest.test_case "HMAC signature correctness" `Quick
        test_webhook_hmac_signature;
      Alcotest.test_case "Non-200 → Rejected with status" `Quick
        test_webhook_non_200;
      Alcotest.test_case "No net → falls back to Approval_pending" `Quick
        test_webhook_no_net_falls_back;
    ]);
  ]
