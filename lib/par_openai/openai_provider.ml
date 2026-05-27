open Par_core.Types

(* §8 — LLM Client *)

type t = {
  api_key : string;
  base_url : string;
  organization : string option;
  mutable net : [ `Generic] Eio.Net.ty Eio.Net.t option;
}

let set_network t net = t.net <- Some net

let create = function
  | Openai { api_key; base_url; organization } ->
    Ok {
      api_key;
      base_url = Option.value base_url ~default:"https://api.openai.com/v1";
      organization;
      net = None;
    }
  | _ -> Result.Error (Invalid_input "OpenAI provider requires Openai configuration")

(* -------------------------------------------------------------------------- *)
(* §8.1 URL parsing                                                           *)
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

let role_to_string = function
  | System -> "system"
  | User -> "user"
  | Assistant -> "assistant"
  | Tool -> "tool"

let build_message_json msg =
  let fields = [ ("role", `String (role_to_string msg.role)) ] in
  let fields =
    match msg.content with Some c -> ("content", `String c) :: fields | None -> fields
  in
  let fields =
    match msg.tool_calls with
    | Some tcs ->
      let tc_json =
        List.map
          (fun (tc:tool_call) ->
            `Assoc
              [ ("id", `String tc.id)
              ; ("type", `String "function")
              ; ( "function",
                  `Assoc
                    [ ("name", `String tc.name)
                    ; ("arguments", `String (Yojson.Safe.to_string tc.arguments))
                    ] )
              ])
          tcs
      in
      ("tool_calls", `List tc_json) :: fields
    | None -> fields
  in
  let fields =
    match msg.tool_call_id with Some id -> ("tool_call_id", `String id) :: fields | None -> fields
  in
  let fields = match msg.name with Some n -> ("name", `String n) :: fields | None -> fields in
  `Assoc fields

let tool_binding_to_json (tb : tool_binding) =
  `Assoc [
    ("type", `String "function");
    ("function", `Assoc [
      ("name", `String tb.name);
      ("description", `String tb.description);
      ("parameters", tb.input_schema);
    ])
  ]

let build_request_body ~model_config ~tools ~conversation ~stream =
  let fields =
    [ ("model", `String model_config.model_name)
    ; ("messages", `List (List.map build_message_json conversation.messages))
    ; ("temperature", `Float model_config.temperature)
    ]
  in
  let fields =
    match model_config.max_tokens with Some mt -> ("max_tokens", `Int mt) :: fields | None -> fields
  in
  let fields =
    match model_config.top_p with Some tp -> ("top_p", `Float tp) :: fields | None -> fields
  in
  let fields =
    match model_config.stop_sequences with
    | Some ss -> ("stop", `List (List.map (fun s -> `String s) ss)) :: fields
    | None -> fields
  in
  let fields = if stream then ("stream", `Bool true) :: fields else fields in
  let fields = if tools <> [] then
    ("tools", `List (List.map tool_binding_to_json tools)) :: fields
  else fields
  in
  Yojson.Safe.to_string (`Assoc fields)

(* -------------------------------------------------------------------------- *)
(* §8.3 HTTP layer                                                            *)
(* -------------------------------------------------------------------------- *)

let build_http_request ~host ~path ~api_key ~organization ~body =
  let org_header =
    match organization with Some o -> Printf.sprintf "OpenAI-Organization: %s\r\n" o | None -> ""
  in
  Printf.sprintf
    "POST %schat/completions HTTP/1.1\r\n\
     Host: %s\r\n\
     Authorization: Bearer %s\r\n\
     %s\
     Content-Type: application/json\r\n\
     Content-Length: %d\r\n\
     Connection: close\r\n\
     \r\n\
     %s"
    path host api_key org_header (String.length body) body

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

let parse_finish_reason = function
  | "stop" -> Stop
  | "tool_calls" -> Tool_calls
  | "length" -> Max_tokens
  | "content_filter" -> Content_filter
  | _ -> Stop

let parse_usage json =
  let open Yojson.Safe.Util in
  { prompt_tokens = json |> member "prompt_tokens" |> to_int
  ; completion_tokens = json |> member "completion_tokens" |> to_int
  ; total_tokens = json |> member "total_tokens" |> to_int
  }

let parse_tool_calls json =
  let open Yojson.Safe.Util in
  List.map
    (fun tc ->
      let fn = tc |> member "function" in
      let args_str = fn |> member "arguments" |> to_string in
      { id = tc |> member "id" |> to_string
      ; name = fn |> member "name" |> to_string
      ; arguments = Yojson.Safe.from_string args_str
      })
    (json |> to_list)

let parse_llm_response json : (llm_response, error_category) result =
  let open Yojson.Safe.Util in
  let choices = json |> member "choices" |> to_list in
  let model = json |> member "model" |> to_string in
  let usage =
    try parse_usage (json |> member "usage")
    with _ -> { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 }
  in
  match choices with
  | first :: _ ->
    let message = first |> member "message" in
    let finish =
      first |> member "finish_reason" |> to_string_option
      |> Option.map parse_finish_reason
      |> Option.value ~default:Stop
    in
    let text =
      try match message |> member "content" with `String s -> Some s | _ -> None
      with _ -> None
    in
    let tool_calls =
      try Some (parse_tool_calls (message |> member "tool_calls")) with _ -> None
    in
    Ok { text; tool_calls; finish_reason = finish; usage; model }
  | [] -> Result.Error (External_failure "No choices in OpenAI response")

(* -------------------------------------------------------------------------- *)
(* §8.7 SSE parsing                                                           *)
(* -------------------------------------------------------------------------- *)

let parse_stream_delta json =
  let open Yojson.Safe.Util in
  let choices = json |> member "choices" |> to_list in
  let usage_opt =
    try Some (parse_usage (json |> member "usage"))
    with _ -> None
  in
  match choices with
  | first :: _ ->
    let delta = first |> member "delta" in
    let finish_opt =
      try
        let fr = first |> member "finish_reason" |> to_string_option in
        Option.map parse_finish_reason fr
      with _ -> None
    in
    let text_chunk =
      try
        match delta |> member "content" with
        | `String s -> Some (Text_delta { text = s })
        | _ -> None
      with _ -> None
    in
    let tool_chunk =
      try
        let tcs = delta |> member "tool_calls" |> to_list in
        ( match tcs with
        | tc :: _ ->
          let fn = tc |> member "function" in
          let tc_id = tc |> member "id" |> to_string in
          let name = try fn |> member "name" |> to_string with _ -> "" in
          let args = try fn |> member "arguments" |> to_string with _ -> "" in
          if tc_id <> "null" && name <> "" then
            Some (Tool_call_start { tool_call_id = tc_id; name })
          else if args <> "" && args <> "null" then
            let idx = tc |> member "index" |> to_int in
            Some (Tool_call_delta { tool_call_id = string_of_int idx; args_json = args })
          else None
        | [] -> None )
      with _ -> None
    in
    (text_chunk, tool_chunk, finish_opt, usage_opt)
  | [] -> (None, None, None, None)

(* -------------------------------------------------------------------------- *)
(* §8.8 LLM_SERVICE implementation                                            *)
(* -------------------------------------------------------------------------- *)

let complete t model_config tools conversation =
  match t.net with
  | None -> Result.Error (Internal "Network not initialized; call set_network first")
  | Some net ->
    let url = parse_url t.base_url in
    let body = build_request_body ~model_config ~tools ~conversation ~stream:false in
    let request =
      build_http_request
        ~host:url.host ~path:url.path ~api_key:t.api_key
        ~organization:t.organization ~body
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
      | Eio.Io _ -> Result.Error (External_failure "Network error during OpenAI request")
      | Failure msg -> Result.Error (Invalid_input msg)
      | exn -> Result.Error (Internal (Printexc.to_string exn)) )

let stream t model_config tools conversation _stream_config callback =
  match t.net with
  | None -> Result.Error (Internal "Network not initialized; call set_network first")
  | Some net ->
    let url = parse_url t.base_url in
    let body = build_request_body ~model_config ~tools ~conversation ~stream:true in
    let request =
      build_http_request
        ~host:url.host ~path:url.path ~api_key:t.api_key
        ~organization:t.organization ~body
    in
    ( try
        let raw = do_request net url request in
        let headers, raw_body = split_response raw in
        let status = parse_status_line headers in
        let resp_body = decode_body headers raw_body in
        if status <> 200 then Result.Error (map_http_status status resp_body)
        else begin
          let chunks = ref 0 in
          let usage = ref { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 } in
          let finish = ref Stop in
          let lines = String.split_on_char '\n' resp_body in
          List.iter
            (fun line ->
              if String.starts_with ~prefix:"data: " line then begin
                let data = String.sub line 6 (String.length line - 6) in
                let data = String.trim data in
                if data = "[DONE]" then ()
                else
                  try
                    let json = Yojson.Safe.from_string data in
                    let text_c, tool_c, finish_opt, usage_opt =
                      parse_stream_delta json
                    in
                    ( match text_c with
                    | Some chunk ->
                      callback chunk;
                      incr chunks
                    | None -> () );
                    ( match tool_c with
                    | Some chunk ->
                      callback chunk;
                      incr chunks
                    | None -> () );
                    ( match finish_opt with Some f -> finish := f | None -> () );
                    ( match usage_opt with Some u -> usage := u | None -> () )
                  with _ -> ()
              end)
            lines;
          Ok { final_usage = !usage; finish_reason = !finish; chunks_received = !chunks }
        end
      with
      | Eio.Io _ -> Result.Error (External_failure "Network error during OpenAI stream")
      | Failure msg -> Result.Error (Invalid_input msg)
      | exn -> Result.Error (Internal (Printexc.to_string exn)) )

let close _t = ()
