open Par_core.Types

(* §8 — Anthropic LLM Client *)

type t = {
  api_key : string;
  base_url : string;
  mutable net : [ `Generic] Eio.Net.ty Eio.Net.t option;
}

let set_network t net = t.net <- Some net

let create = function
  | Anthropic { api_key; base_url } ->
    Ok {
      api_key;
      base_url = Option.value base_url ~default:"https://api.anthropic.com";
      net = None;
    }
  | _ -> Result.Error (Invalid_input "Anthropic provider requires Anthropic configuration")

(* -------------------------------------------------------------------------- *)
(* §8.1 URL parsing (shared with openai — duplicated for independence)        *)
(* -------------------------------------------------------------------------- *)

type parsed_url = { host : string; port : int; path : string }

let parse_url url =
  let without_proto =
    if String.starts_with ~prefix:"https://" url then
      String.sub url 8 (String.length url - 8)
    else if String.starts_with ~prefix:"http://" url then
      String.sub url 7 (String.length url - 7)
    else url
  in
  let host_part, path =
    match String.index_opt without_proto '/' with
    | Some i ->
      (String.sub without_proto 0 i,
       String.sub without_proto i (String.length without_proto - i))
    | None -> (without_proto, "/")
  in
  let host, port =
    match String.rindex_opt host_part ':' with
    | Some i ->
      ( String.sub host_part 0 i,
        int_of_string
          (String.sub host_part (i + 1) (String.length host_part - i - 1)) )
    | None -> (host_part, 443)
  in
  let path = if String.ends_with ~suffix:"/" path then path else path ^ "/" in
  { host; port; path }

(* -------------------------------------------------------------------------- *)
(* §8.2 JSON request building                                                 *)
(* -------------------------------------------------------------------------- *)

let build_tool_result_content msg =
  match msg.tool_call_id with
  | Some tool_use_id ->
    [ `Assoc
        [ ("type", `String "tool_result")
        ; ("tool_use_id", `String tool_use_id)
        ; ("content", `String (Option.value msg.content ~default:""))
        ]
    ]
  | None -> []

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

let build_message_json msg =
  match msg.role with
  | Tool ->
    let content = build_tool_result_content msg in
    `Assoc [ ("role", `String "user"); ("content", `List content) ]
  | Assistant ->
    let text_blocks =
      match msg.content with
      | Some c -> [ `Assoc [ ("type", `String "text"); ("text", `String c) ] ]
      | None -> []
    in
    let tool_blocks =
      match msg.tool_calls with
      | Some tcs -> build_tool_calls_content tcs
      | None -> []
    in
    `Assoc
      [ ("role", `String "assistant")
      ; ("content", `List (text_blocks @ tool_blocks))
      ]
  | User | System ->
    let content =
      match msg.content with
      | Some c -> [ `Assoc [ ("type", `String "text"); ("text", `String c) ] ]
      | None -> []
    in
    `Assoc [ ("role", `String "user"); ("content", `List content) ]

let extract_system_prompt conversation =
  let sys, rest =
    List.partition (fun (m : message) -> match m.role with System -> true | _ -> false)
      conversation.messages
  in
  let system_text =
    List.filter_map (fun (m : message) -> m.content) sys
    |> String.concat "\n"
  in
  let system_opt = if system_text = "" then None else Some system_text in
  (system_opt, { conversation with messages = rest })

let build_request_body ~model_config ~conversation ~stream =
  let system_text, conv = extract_system_prompt conversation in
  let fields =
    [ ("model", `String model_config.model_name)
    ; ("messages", `List (List.map build_message_json conv.messages))
    ; ("max_tokens", `Int (Option.value model_config.max_tokens ~default:4096))
    ; ("temperature", `Float model_config.temperature)
    ]
  in
  let fields =
    match system_text with
    | Some s -> ("system", `String s) :: fields
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
  Yojson.Safe.to_string (`Assoc fields)

(* -------------------------------------------------------------------------- *)
(* §8.3 HTTP layer                                                            *)
(* -------------------------------------------------------------------------- *)

let build_http_request ~host ~path ~api_key ~body =
  Printf.sprintf
    "POST %sv1/messages HTTP/1.1\r\n\
     Host: %s\r\n\
     x-api-key: %s\r\n\
     anthropic-version: 2023-06-01\r\n\
     Content-Type: application/json\r\n\
     Content-Length: %d\r\n\
     Connection: close\r\n\
     \r\n\
     %s"
    path host api_key (String.length body) body

let split_response data =
  let sep = "\r\n\r\n" in
  let sep_len = String.length sep in
  let data_len = String.length data in
  let rec find i =
    if i + sep_len > data_len then data_len
    else if String.sub data i sep_len = sep then i
    else find (i + 1)
  in
  let header_end = find 0 in
  let headers = String.sub data 0 header_end in
  let body =
    if header_end + sep_len < data_len then
      String.sub data (header_end + sep_len) (data_len - header_end - sep_len)
    else ""
  in
  (headers, body)

let parse_status_line header_data =
  let line_end =
    match String.index_opt header_data '\r' with Some i -> i | None -> String.length header_data
  in
  let status_line = String.sub header_data 0 line_end in
  match String.split_on_char ' ' status_line with
  | _ :: code :: _ -> int_of_string code
  | _ -> 0

let headers_contain ~needle headers =
  let lower = String.lowercase_ascii headers in
  let lneedle = String.lowercase_ascii needle in
  let nlen = String.length lneedle in
  let hlen = String.length lower in
  let rec search i =
    if i + nlen > hlen then false
    else String.sub lower i nlen = lneedle || search (i + 1)
  in
  nlen = 0 || search 0

let decode_chunked data =
  let buf = Buffer.create 4096 in
  let pos = ref 0 in
  let len = String.length data in
  let skip_crlf () =
    if !pos < len && Char.equal (String.get data !pos) '\r' then incr pos;
    if !pos < len && Char.equal (String.get data !pos) '\n' then incr pos
  in
  let read_chunk_size () =
    let start = !pos in
    while !pos < len && not (Char.equal (String.get data !pos) '\r') do incr pos done;
    let hex = String.sub data start (!pos - start) in
    skip_crlf ();
    int_of_string ("0x" ^ hex)
  in
  ( try
      while !pos < len do
        let size = read_chunk_size () in
        if size = 0 then raise Exit;
        if !pos + size > len then raise Exit;
        Buffer.add_substring buf data !pos size;
        pos := !pos + size;
        skip_crlf ()
      done
    with Exit -> () );
  Buffer.contents buf

let decode_body headers raw_body =
  if headers_contain ~needle:"transfer-encoding: chunked" headers then
    decode_chunked raw_body
  else raw_body

let map_http_status status body =
  match status with
  | 400 -> Invalid_input body
  | 401 -> Permission_denied "Invalid API key"
  | 403 -> Permission_denied body
  | 429 -> Rate_limited
  | 408 | 504 -> Timeout
  | s when s >= 500 -> External_failure (Printf.sprintf "Server error %d: %s" s body)
  | s -> External_failure (Printf.sprintf "Unexpected HTTP %d: %s" s body)

(* -------------------------------------------------------------------------- *)
(* §8.4 TLS setup                                                             *)
(* -------------------------------------------------------------------------- *)

let tls_config =
  let no_auth ?ip:_ ~host:_ _certs = Ok None in
  lazy
    (match Tls.Config.client ~authenticator:no_auth () with
    | Ok cfg -> cfg
    | Result.Error (`Msg msg) -> failwith ("TLS configuration error: " ^ msg))

let tls_host_of_string host =
  match Domain_name.of_string host with
  | Error _ -> None
  | Ok dn -> ( match Domain_name.host dn with Ok h -> Some h | Error _ -> None )

(* -------------------------------------------------------------------------- *)
(* §8.5 Connection                                                            *)
(* -------------------------------------------------------------------------- *)

let do_request net url request =
  Eio.Net.with_tcp_connect
    ~host:url.host
    ~service:(string_of_int url.port)
    net
    (fun flow ->
      let cfg = Lazy.force tls_config in
      let tls =
        match tls_host_of_string url.host with
        | Some h -> Tls_eio.client_of_flow cfg ~host:h flow
        | None -> Tls_eio.client_of_flow cfg flow
      in
      Eio.Flow.copy_string request tls;
      Eio.Flow.shutdown tls `Send;
      Eio.Flow.read_all tls)

(* -------------------------------------------------------------------------- *)
(* §8.6 JSON response parsing                                                 *)
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
  { prompt_tokens = input_t
  ; completion_tokens = output_t
  ; total_tokens = input_t + output_t
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
    with _ -> { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 }
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
(* §8.7 SSE parsing                                                           *)
(* -------------------------------------------------------------------------- *)

let parse_sse_lines resp_body =
  let lines = String.split_on_char '\n' resp_body in
  let events = ref [] in
  let current_type = ref "" in
  let current_data = ref "" in
  List.iter
    (fun line ->
      if String.starts_with ~prefix:"event: " line then
        current_type := String.sub line 7 (String.length line - 7)
      else if String.starts_with ~prefix:"data: " line then
        current_data := String.sub line 6 (String.length line - 6)
      else if line = "" && !current_data <> "" then begin
        events := (!current_type, !current_data) :: !events;
        current_type := "";
        current_data := ""
      end
      else ())
    lines;
  List.rev !events

let parse_stream_events events callback =
  let chunks = ref 0 in
  let usage = ref { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 } in
  let finish = ref Stop in
  let open Yojson.Safe.Util in
  List.iter
    (fun (evt_type, data_str) ->
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
               callback (Tool_call_delta { tool_call_id = ""; args_json = args });
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
               ; total_tokens = !usage.total_tokens + u.total_tokens
               }
           with _ -> ())
        | "message_stop" ->
          callback (Done { finish_reason = !finish });
          incr chunks
        | _ -> ()
      with _ -> ())
    events;
  (!usage, !finish, !chunks)

(* -------------------------------------------------------------------------- *)
(* §8.8 LLM_SERVICE implementation                                            *)
(* -------------------------------------------------------------------------- *)

let complete t model_config conversation =
  match t.net with
  | None -> Result.Error (Internal "Network not initialized; call set_network first")
  | Some net ->
    let url = parse_url t.base_url in
    let body = build_request_body ~model_config ~conversation ~stream:false in
    let request =
      build_http_request ~host:url.host ~path:url.path ~api_key:t.api_key ~body
    in
    ( try
        let raw = do_request net url request in
        let headers, raw_body = split_response raw in
        let status = parse_status_line headers in
        let resp_body = decode_body headers raw_body in
        if status <> 200 then Result.Error (map_http_status status resp_body)
        else
          let json = Yojson.Safe.from_string resp_body in
          parse_llm_response json
      with
      | Eio.Io _ -> Result.Error (External_failure "Network error during Anthropic request")
      | Failure msg -> Result.Error (Invalid_input msg)
      | exn -> Result.Error (Internal (Printexc.to_string exn)) )

let stream t model_config conversation _stream_config callback =
  match t.net with
  | None -> Result.Error (Internal "Network not initialized; call set_network first")
  | Some net ->
    let url = parse_url t.base_url in
    let body = build_request_body ~model_config ~conversation ~stream:true in
    let request =
      build_http_request ~host:url.host ~path:url.path ~api_key:t.api_key ~body
    in
    ( try
        let raw = do_request net url request in
        let headers, raw_body = split_response raw in
        let status = parse_status_line headers in
        let resp_body = decode_body headers raw_body in
        if status <> 200 then Result.Error (map_http_status status resp_body)
        else
          let events = parse_sse_lines resp_body in
          let usage, finish, chunks = parse_stream_events events callback in
          Ok { final_usage = usage; finish_reason = finish; chunks_received = chunks }
      with
      | Eio.Io _ -> Result.Error (External_failure "Network error during Anthropic stream")
      | Failure msg -> Result.Error (Invalid_input msg)
      | exn -> Result.Error (Internal (Printexc.to_string exn)) )

let close _t = ()
