open Types

(* A callback exception is not a malformed SSE event.  Wrap it so the per-event
   parse handlers can re-raise it instead of logging-and-continuing. *)
exception Callback_raised of exn

let invoke_callback cb chunk =
  try cb chunk with
  | Cancellation.Stream_cancelled_by_token as exn -> raise exn
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> raise (Callback_raised exn)

(* — Anthropic LLM Client *)

type t = {
  api_key : string;
  base_url : string;
  mutable net : [ `Generic] Eio.Net.ty Eio.Net.t option;
}

let set_network t net = t.net <- Some net

let create = function
  | Anthropic { api_key; base_url } ->
    if String.length api_key = 0 then
      Result.Error (Invalid_input "api_key must not be empty")
    else
      Ok {
        api_key;
        base_url = Option.value base_url ~default:"https://api.anthropic.com";
        net = None;
      }
  | _ -> Result.Error (Invalid_input "Anthropic provider requires Anthropic configuration")

(* -------------------------------------------------------------------------- *)
(* Error conversion                                                      *)
(* -------------------------------------------------------------------------- *)

let http_error_to_error_category = function
  | Http_client.Invalid_input s -> Types.Invalid_input s
  | Http_client.Permission_denied s -> Types.Permission_denied s
  | Http_client.Rate_limited -> Types.Rate_limited
  | Http_client.Timeout -> Types.Timeout
  | Http_client.External_failure s -> Types.External_failure s

(* -------------------------------------------------------------------------- *)
(* JSON request building                                                 *)
(* -------------------------------------------------------------------------- *)

let build_tool_calls_content tcs =
  List.map
    (fun (tc : tool_call) ->
      `Assoc
        [ ("type", `String "tool_use")
        ; ("id", `String tc.id)
        ; ("name", `String tc.name)
        ; ("input", tc.arguments)
        ])
    tcs

let cache_control_to_json (cc : cache_control) =
  match cc.ttl with
  | Some `Five_min -> `Assoc [ ("type", `String "ephemeral"); ("ttl", `String "5m") ]
  | Some `One_hour -> `Assoc [ ("type", `String "ephemeral"); ("ttl", `String "1h") ]
  | None -> `Assoc [ ("type", `String "ephemeral") ]

let emit_block_with_cache (block : content_block) : Yojson.Safe.t =
  let base = match block with
    | Text_block { text; _ } ->
      `Assoc [("type", `String "text"); ("text", `String text)]
    | Tool_use_block { id; name; arguments; _ } ->
      `Assoc [("type", `String "tool_use"); ("id", `String id);
              ("name", `String name); ("input", arguments)]
    | Tool_result_block { tool_use_id; content; _ } ->
      `Assoc [("type", `String "tool_result");
              ("tool_use_id", `String tool_use_id);
              ("content", `String content)]
    | Image_block { source; media_type; _ } ->
      (* Anthropic's image schema puts the MIME type INSIDE "source" for
         base64 payloads, and has no top-level "data" key. Emitting
         media_type/data as siblings of "source" produced a body Anthropic
         rejects, so base64 images were unusable. *)
      let src = match source with
        | Url u -> `Assoc [("type", `String "url"); ("url", `String u)]
        | Base64 b ->
          `Assoc [("type", `String "base64"); ("media_type", `String media_type);
                  ("data", `String b)]
      in
      `Assoc [("type", `String "image"); ("source", src)]
    | Reasoning_block { text; signature; _ } ->
      (* Anthropic requires the thinking block back verbatim, signature
         included, whenever the assistant message also carries tool_use. *)
      (match signature with
       | Some sig_ ->
         `Assoc [("type", `String "thinking"); ("thinking", `String text);
                 ("signature", `String sig_)]
       | None ->
         (* Without a signature the block cannot be replayed; sending it
            anyway would be rejected, so only the text is kept out of the
            request when the provider never signed it. *)
         `Assoc [("type", `String "thinking"); ("thinking", `String text)])
    | Redacted_reasoning_block { data; _ } ->
      `Assoc [("type", `String "redacted_thinking"); ("data", `String data)]
  in
  match block with
  | Text_block { cache_control = Some cc; _ }
  | Tool_use_block { cache_control = Some cc; _ }
  | Tool_result_block { cache_control = Some cc; _ }
  | Image_block { cache_control = Some cc; _ } ->
    (match base with
     | `Assoc fields -> `Assoc (("cache_control", cache_control_to_json cc) :: fields)
     | _ -> base)
  | _ -> base

(* A thinking block without a signature cannot be replayed: Anthropic rejects
   it. Such blocks come from another provider or from pre-v0.13 persisted data,
   so they are kept in the conversation but left out of the request. *)
let replayable_block = function
  | Reasoning_block { signature = None; _ } -> false
  | _ -> true

let build_message_json msg =
  let blocks_json =
    List.filter replayable_block msg.content_blocks
    |> List.map emit_block_with_cache
  in
  match msg.role with
  | Tool ->
    (match msg.tool_call_id with
     | Some tu_id ->
       let result_text =
         msg.content_blocks
         |> List.filter_map (function
              | Text_block { text; _ } -> Some text
              | Tool_result_block { content; _ } -> Some content
              | _ -> None)
         |> String.concat "\n"
       in
       (* A tool that produced content (an image, say) needs the array form:
          Anthropic's tool_result content is either a string or a list of
          blocks, and an image block only exists in the list form. *)
       let image_blocks =
         msg.content_blocks
         |> List.filter_map (function
              | (Image_block _ as b) -> Some (emit_block_with_cache b)
              | _ -> None)
       in
       let content =
         if image_blocks = [] then `String result_text
         else
           let text_part =
             if result_text = "" then []
             else [`Assoc [("type", `String "text"); ("text", `String result_text)]]
           in
           `List (text_part @ image_blocks)
       in
       `Assoc [("role", `String "user");
               ("content", `List [
                  `Assoc [("type", `String "tool_result");
                          ("tool_use_id", `String tu_id);
                          ("content", content)]
                ])]
     | None ->
       (* Fallback: no tool_call_id (shouldn't happen in normal flow) *)
       `Assoc [("role", `String "user"); ("content", `List blocks_json)])
  | Assistant ->
    let tool_blocks = match msg.tool_calls with
      | Some tcs -> build_tool_calls_content tcs
      | None -> []
    in
    `Assoc [("role", `String "assistant"); ("content", `List (blocks_json @ tool_blocks))]
  | User | System ->
    `Assoc [("role", `String "user"); ("content", `List blocks_json)]

let extract_system_prompt conversation =
  let sys, rest =
    List.partition (fun (m : message) -> match m.role with System -> true | _ -> false)
      conversation.messages
  in
  let system_blocks =
    List.concat_map (fun (m : message) -> m.content_blocks) sys
  in
  let system_opt = if system_blocks = [] then None else Some system_blocks in
  (system_opt, { conversation with messages = rest })

let tool_descriptor_to_json (td : tool_descriptor) =
  let base = [
    ("name", `String td.name);
    ("description", `String td.description);
    ("input_schema", td.input_schema);
  ] in
  match td.cache_control with
  | Some cc -> `Assoc (("cache_control", cache_control_to_json cc) :: base)
  | None -> `Assoc base

(* Anthropic's own limits for extended thinking: the budget must be at least
   1024 tokens and smaller than max_tokens. Rejecting here turns a provider 400
   into an error that names the two values that disagree. *)
let check_thinking (model_config : model_config) : (unit, error_category) result =
  match model_config.thinking_budget_tokens with
  | None -> Ok ()
  | Some budget ->
    let max_tokens = Option.value model_config.max_tokens ~default:4096 in
    if budget < 1024 then
      Result.Error (Invalid_input
        (Printf.sprintf
           "thinking_budget_tokens is %d; Anthropic requires at least 1024" budget))
    else if budget >= max_tokens then
      Result.Error (Invalid_input
        (Printf.sprintf
           "thinking_budget_tokens (%d) must be smaller than max_tokens (%d)"
           budget max_tokens))
    else Ok ()

let build_request_body ~model_config ~tools ~conversation ~stream ?response_schema () =
  let system_blocks, conv = extract_system_prompt conversation in
  let thinking = model_config.thinking_budget_tokens in
  let fields =
    [ ("model", `String model_config.model_name)
    ; ("messages", `List (List.map build_message_json conv.messages))
    ; ("max_tokens", `Int (Option.value model_config.max_tokens ~default:4096))
    ]
  in
  (* Anthropic rejects temperature and top_p alongside extended thinking, so
     they are left out rather than sent and refused. *)
  let fields =
    match thinking with
    | Some _ -> fields
    | None -> ("temperature", `Float model_config.temperature) :: fields
  in
  let fields =
    match thinking with
    | Some budget ->
      ("thinking", `Assoc [("type", `String "enabled"); ("budget_tokens", `Int budget)])
      :: fields
    | None -> fields
  in
  let fields =
    match system_blocks with
    | Some blocks ->
      ("system", `List (List.map emit_block_with_cache blocks)) :: fields
    | None -> fields
  in
  let fields =
    match thinking, model_config.top_p with
    | None, Some tp -> ("top_p", `Float tp) :: fields
    | _ -> fields
  in
  let fields =
    match model_config.stop_sequences with
    | Some ss -> ("stop_sequences", `List (List.map (fun s -> `String s) ss)) :: fields
    | None -> fields
  in
  let fields = if stream then ("stream", `Bool true) :: fields else fields in
  let fields = if tools <> [] then
    ("tools", `List (List.map tool_descriptor_to_json tools)) :: fields
  else fields
  in
  let fields =
    match response_schema with
    | Some schema ->
      ("output_config",
       `Assoc
         [ ("format",
            `Assoc
              [ ("type", `String "json_schema")
              ; ("schema", schema)
              ])
         ])
      :: fields
    | None -> fields
  in
  Yojson.Safe.to_string (`Assoc fields)

(* -------------------------------------------------------------------------- *)
(* HTTP helpers                                                          *)
(* -------------------------------------------------------------------------- *)

let auth_headers t =
  [ ("x-api-key", t.api_key); ("anthropic-version", "2023-06-01") ]

(* -------------------------------------------------------------------------- *)
(* JSON response parsing                                                 *)
(* -------------------------------------------------------------------------- *)

let parse_stop_reason = function
  | "end_turn" -> Stop
  | "tool_use" -> Tool_calls
  | "max_tokens" -> Max_tokens
  | "stop_sequence" -> Stop
  | _ -> Stop

let parse_usage json =
  let open Yojson.Safe.Util in
  let input_t = try json |> member "input_tokens" |> to_int with _ -> 0 in
  let output_t = try json |> member "output_tokens" |> to_int with _ -> 0 in
  let cache_creation = try json |> member "cache_creation_input_tokens" |> to_int with _ -> 0 in
  let cache_read = try json |> member "cache_read_input_tokens" |> to_int with _ -> 0 in
  { prompt_tokens = input_t
  ; completion_tokens = output_t
  ; total_tokens = input_t + output_t
  ; cached_tokens = 0
  ; cache_creation_input_tokens = cache_creation
  ; cache_read_input_tokens = cache_read
  }

let parse_content_blocks json =
  let open Yojson.Safe.Util in
  let blocks = json |> to_list in
  let text_parts = ref [] in
  let tool_parts = ref [] in
  let reasoning = ref [] in
  List.iter
    (fun block ->
      let typ = block |> member "type" |> to_string in
      match typ with
      | "text" ->
        let txt = block |> member "text" |> to_string in
        text_parts := txt :: !text_parts
      | "tool_use" ->
        let tc =
          { id = block |> member "id" |> to_string
          ; name = block |> member "name" |> to_string
          ; arguments = block |> member "input"
          }
        in
        tool_parts := tc :: !tool_parts
      | "thinking" ->
        let text = try block |> member "thinking" |> to_string with _ -> "" in
        let signature =
          try match block |> member "signature" with
            | `String sig_ -> Some sig_
            | _ -> None
          with _ -> None
        in
        reasoning := Reasoning_block { text; signature; cache_control = None } :: !reasoning
      | "redacted_thinking" ->
        let data = try block |> member "data" |> to_string with _ -> "" in
        reasoning := Redacted_reasoning_block { data; cache_control = None } :: !reasoning
      | _ -> ())
    blocks;
  (List.rev !text_parts, List.rev !tool_parts, List.rev !reasoning)

let parse_llm_response json : (llm_response, error_category) result =
  let open Yojson.Safe.Util in
  let model = json |> member "model" |> to_string in
  let stop_reason =
    try json |> member "stop_reason" |> to_string |> parse_stop_reason
    with _ -> Stop
  in
  let usage =
    try parse_usage (json |> member "usage")
    with _ -> { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 ; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
  in
  let content = json |> member "content" in
  let text_parts, tool_parts, reasoning = parse_content_blocks content in
  let text =
    match text_parts with
    | [] -> None
    | parts -> Some (String.concat "" parts)
  in
  let tool_calls =
    match tool_parts with [] -> None | tcs -> Some (List.rev tcs)
  in
  Ok { text; reasoning; tool_calls; finish_reason = stop_reason; usage; model }

(* -------------------------------------------------------------------------- *)
(* SSE parsing                                                           *)
(* -------------------------------------------------------------------------- *)

let process_stream_event (evt_type, data_str) callback usage finish chunks current_tc_id =
  let open Yojson.Safe.Util in
  let callback = invoke_callback callback in
  let log_exn ctx exn =
    match exn with
    | Cancellation.Stream_cancelled_by_token -> raise exn
    | Eio.Cancel.Cancelled _ -> raise exn
    | Callback_raised _ -> raise exn
    | _ ->
      Logs.warn (fun m -> m "anthropic_provider: stream %s parse error: %s" ctx (Printexc.to_string exn))
  in
  try
    let json = Yojson.Safe.from_string data_str in
    match evt_type with
    | "message_start" ->
      let msg = json |> member "message" in
      let u = try parse_usage (msg |> member "usage") with exn -> log_exn "message_start.usage" exn; !usage in
      usage := u
    | "content_block_start" ->
      let block = json |> member "content_block" in
      (try
         let typ = block |> member "type" |> to_string in
         if typ = "redacted_thinking" then
           Logs.warn (fun m -> m
             "anthropic_provider: stream dropped a redacted thinking block; \
              the streaming chunk interface cannot carry it. Use the \
              non-streaming path when thinking is enabled and tools are in play.")
         else if typ = "tool_use" then begin
           let tc_id = block |> member "id" |> to_string in
           let name = block |> member "name" |> to_string in
           let _idx = try json |> member "index" |> to_int with exn -> log_exn "block_start.index" exn; 0 in
           current_tc_id := tc_id;
           callback (Tool_call_start { tool_call_id = tc_id; name });
           incr chunks
         end
       with exn -> log_exn "content_block_start" exn)
    | "content_block_delta" ->
      let delta = json |> member "delta" in
      (try
         let typ = delta |> member "type" |> to_string in
         if typ = "text_delta" then begin
           let txt = delta |> member "text" |> to_string in
           callback (Text_delta { text = txt });
           incr chunks
         end
       with exn -> log_exn "text_delta" exn);
      (try
         let typ = delta |> member "type" |> to_string in
         if typ = "thinking_delta" then begin
           let txt = delta |> member "thinking" |> to_string in
           callback (Reasoning_delta { text = txt });
           incr chunks
         end else if typ = "signature_delta" then begin
           let signature = delta |> member "signature" |> to_string in
           callback (Reasoning_signature { signature });
           incr chunks
         end
       with exn -> log_exn "thinking_delta" exn);
      (try
         let typ = delta |> member "type" |> to_string in
         if typ = "input_json_delta" then begin
           let args = delta |> member "partial_json" |> to_string in
           let idx = try json |> member "index" |> to_int with exn -> log_exn "json_delta.index" exn; 0 in
           let key = if !current_tc_id <> "" then !current_tc_id
                     else string_of_int idx in
           callback (Tool_call_delta { tool_call_id = key; args_json = args });
           incr chunks
         end
       with exn -> log_exn "input_json_delta" exn)
    | "message_delta" ->
      let delta = json |> member "delta" in
      (try
         let sr = delta |> member "stop_reason" |> to_string in
         finish := parse_stop_reason sr
       with exn -> log_exn "stop_reason" exn);
      (try
         let u = parse_usage (json |> member "usage") in
         usage :=
           { prompt_tokens = !usage.prompt_tokens + u.prompt_tokens
           ; completion_tokens = !usage.completion_tokens + u.completion_tokens
           ; total_tokens = !usage.total_tokens + u.total_tokens; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0
           }
       with exn -> log_exn "message_delta.usage" exn)
    | "message_stop" ->
      callback (Done { finish_reason = !finish });
      incr chunks
    | _ -> ()
  with exn ->
    (match exn with
     | Cancellation.Stream_cancelled_by_token -> raise exn
     | Eio.Cancel.Cancelled _ -> raise exn
     | Callback_raised _ -> raise exn
     | _ ->
       let preview = String.sub data_str 0 (min 200 (String.length data_str)) in
       Logs.warn (fun m -> m "anthropic_provider: stream event dropped: %s — type: %s data: %s"
         (Printexc.to_string exn) evt_type preview))

(* -------------------------------------------------------------------------- *)
(* LLM_SERVICE implementation                                            *)
(* -------------------------------------------------------------------------- *)

let complete t model_config tools conversation =
  match check_thinking model_config with
  | Error _ as e -> e
  | Ok () ->
  match t.net with
  | None -> Result.Error (Internal "Network not initialized; call set_network first")
  | Some net ->
    let url = Http_client.parse_url t.base_url in
    let body = build_request_body ~model_config ~tools ~conversation ~stream:false () in
    let headers = auth_headers t in
    let request =
      Http_client.build_http_request
        ~host:url.Http_client.host
        ~path:(url.Http_client.path ^ "v1/messages")
        ~headers ~body
    in
    ( try
        let raw = Http_client.do_request net url request in
        let headers, raw_body = Http_client.split_response raw in
        let status = Http_client.parse_status_line headers in
        let resp_body = Http_client.decode_body headers raw_body in
        if status <> 200 then Result.Error (http_error_to_error_category (Http_client.map_http_status status resp_body))
        else
          let json = Yojson.Safe.from_string resp_body in
          parse_llm_response json
      with
      | Eio.Io _ -> Result.Error (External_failure "Network error during Anthropic request")
      | Failure msg -> Result.Error (Invalid_input msg)
      | exn -> Result.Error (Internal (Printexc.to_string exn)) )

let complete_structured t model_config tools conversation schema =
  match check_thinking model_config with
  | Error _ as e -> e
  | Ok () ->
  match t.net with
  | None -> Result.Error (Internal "Network not initialized; call set_network first")
  | Some net ->
    let url = Http_client.parse_url t.base_url in
    let body =
      build_request_body ~model_config ~tools ~conversation ~stream:false
        ~response_schema:schema ()
    in
    let headers = auth_headers t in
    let request =
      Http_client.build_http_request
        ~host:url.Http_client.host
        ~path:(url.Http_client.path ^ "v1/messages")
        ~headers ~body
    in
    ( try
        let raw = Http_client.do_request net url request in
        let headers, raw_body = Http_client.split_response raw in
        let status = Http_client.parse_status_line headers in
        let resp_body = Http_client.decode_body headers raw_body in
        if status <> 200 then
          Result.Error
            (http_error_to_error_category
               (Http_client.map_http_status status resp_body))
        else
          let json = Yojson.Safe.from_string resp_body in
          parse_llm_response json
      with
      | Eio.Io _ ->
        Result.Error
          (External_failure "Network error during Anthropic structured request")
      | Failure msg -> Result.Error (Invalid_input msg)
      | exn -> Result.Error (Internal (Printexc.to_string exn)) )

let stream t model_config tools conversation _stream_config callback =
  match check_thinking model_config with
  | Error _ as e -> e
  | Ok () ->
  match t.net with
  | None -> Result.Error (Internal "Network not initialized; call set_network first")
  | Some net ->
    let url = Http_client.parse_url t.base_url in
    let body = build_request_body ~model_config ~tools ~conversation ~stream:true () in
    let headers = auth_headers t in
    let request =
      Http_client.build_http_request
        ~host:url.Http_client.host
        ~path:(url.Http_client.path ^ "v1/messages")
        ~headers ~body
    in
    ( try
        Http_client.do_request_streaming net url request
          (fun ~status:_ ~headers:_ ~read_line ->
            let chunks = ref 0 in
            let usage =
              ref { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 ; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
            in
             let finish = ref Stop in
             let current_type = ref "" in
             let current_data = ref "" in
             let current_tc_id = ref "" in
             let stop = ref false in
             let rec process_lines () =
               if !stop then ()
               else
                 match read_line () with
                 | None ->
                   if !current_data <> "" then
                     process_stream_event
                       (!current_type, !current_data)
                       callback usage finish chunks current_tc_id
                 | Some line ->
                   if String.starts_with ~prefix:"event: " line then begin
                     let evt = String.sub line 7 (String.length line - 7) in
                     current_type := evt;
                     if evt = "message_stop" then stop := true
                   end
                   else if String.starts_with ~prefix:"data: " line then
                     current_data :=
                       String.sub line 6 (String.length line - 6)
                   else if line = "" && !current_data <> "" then begin
                     process_stream_event
                       (!current_type, !current_data)
                       callback usage finish chunks current_tc_id;
                     current_type := "";
                     current_data := ""
                   end;
                   process_lines ()
            in
            process_lines ();
            Ok
              { final_usage = !usage
              ; finish_reason = !finish
              ; chunks_received = !chunks
              })
      with
      | Http_client.Http_status_error (status, body) ->
        Result.Error
          (http_error_to_error_category
             (Http_client.map_http_status status body))
      | Eio.Io _ -> Result.Error (External_failure "Network error during Anthropic stream")
      | Cancellation.Stream_cancelled_by_token as exn -> raise exn
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | Callback_raised exn -> Result.Error (Internal (Printexc.to_string exn))
      | Failure msg -> Result.Error (Invalid_input msg)
      | exn -> Result.Error (Internal (Printexc.to_string exn)) )

let embed _t _messages = Result.Error Embedding_unsupported

let close _t = ()
