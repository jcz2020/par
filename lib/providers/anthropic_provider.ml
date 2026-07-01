open Types

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
    | Image_block { source; media_type; data; _ } ->
      let src = match source with
        | Url u -> `Assoc [("type", `String "url"); ("url", `String u)]
        | Base64 b -> `Assoc [("type", `String "base64"); ("data", `String b)]
      in
      `Assoc [("type", `String "image"); ("source", src);
              ("media_type", `String media_type); ("data", `String data)]
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

let build_message_json msg =
  let blocks_json = List.map emit_block_with_cache msg.content_blocks in
  match msg.role with
  | Tool ->
    `Assoc [("role", `String "user"); ("content", `List blocks_json)]
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

let build_request_body ~model_config ~tools ~conversation ~stream ?response_schema () =
  let system_blocks, conv = extract_system_prompt conversation in
  let fields =
    [ ("model", `String model_config.model_name)
    ; ("messages", `List (List.map build_message_json conv.messages))
    ; ("max_tokens", `Int (Option.value model_config.max_tokens ~default:4096))
    ; ("temperature", `Float model_config.temperature)
    ]
  in
  let fields =
    match system_blocks with
    | Some blocks ->
      ("system", `List (List.map emit_block_with_cache blocks)) :: fields
    | None -> fields
  in
  let fields =
    match model_config.top_p with Some tp -> ("top_p", `Float tp) :: fields | None -> fields
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
      | _ -> ())
    blocks;
  (List.rev !text_parts, List.rev !tool_parts)

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
  let text_parts, tool_parts = parse_content_blocks content in
  let text =
    match text_parts with
    | [] -> None
    | parts -> Some (String.concat "" parts)
  in
  let tool_calls =
    match tool_parts with [] -> None | tcs -> Some (List.rev tcs)
  in
  Ok { text; tool_calls; finish_reason = stop_reason; usage; model }

(* -------------------------------------------------------------------------- *)
(* SSE parsing                                                           *)
(* -------------------------------------------------------------------------- *)

let process_stream_event (evt_type, data_str) callback usage finish chunks current_tc_id =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string data_str in
    match evt_type with
    | "message_start" ->
      let msg = json |> member "message" in
      let u = try parse_usage (msg |> member "usage") with _ -> !usage in
      usage := u
    | "content_block_start" ->
      let block = json |> member "content_block" in
      (try
         let typ = block |> member "type" |> to_string in
         if typ = "tool_use" then begin
           let tc_id = block |> member "id" |> to_string in
           let name = block |> member "name" |> to_string in
           let _idx = try json |> member "index" |> to_int with _ -> 0 in
           current_tc_id := tc_id;
           callback (Tool_call_start { tool_call_id = tc_id; name });
           incr chunks
         end
       with _ -> ())
    | "content_block_delta" ->
      let delta = json |> member "delta" in
      (try
         let typ = delta |> member "type" |> to_string in
         if typ = "text_delta" then begin
           let txt = delta |> member "text" |> to_string in
           callback (Text_delta { text = txt });
           incr chunks
         end
       with _ -> ());
      (try
         let typ = delta |> member "type" |> to_string in
         if typ = "input_json_delta" then begin
           let args = delta |> member "partial_json" |> to_string in
           let idx = try json |> member "index" |> to_int with _ -> 0 in
           let key = if !current_tc_id <> "" then !current_tc_id
                     else string_of_int idx in
           callback (Tool_call_delta { tool_call_id = key; args_json = args });
           incr chunks
         end
       with _ -> ())
    | "message_delta" ->
      let delta = json |> member "delta" in
      (try
         let sr = delta |> member "stop_reason" |> to_string in
         finish := parse_stop_reason sr
       with _ -> ());
      (try
         let u = parse_usage (json |> member "usage") in
         usage :=
           { prompt_tokens = !usage.prompt_tokens + u.prompt_tokens
           ; completion_tokens = !usage.completion_tokens + u.completion_tokens
           ; total_tokens = !usage.total_tokens + u.total_tokens; cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0
           }
       with _ -> ())
    | "message_stop" ->
      callback (Done { finish_reason = !finish });
      incr chunks
    | _ -> ()
  with _ -> ()

(* -------------------------------------------------------------------------- *)
(* LLM_SERVICE implementation                                            *)
(* -------------------------------------------------------------------------- *)

let complete t model_config tools conversation =
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
      | Failure msg -> Result.Error (Invalid_input msg)
      | exn -> Result.Error (Internal (Printexc.to_string exn)) )

let embed _t _messages = Result.Error Embedding_unsupported

let close _t = ()
