open Types

(* — LLM Client *)

type t = {
  api_key : string;
  base_url : string;
  organization : string option;
  mutable net : [ `Generic] Eio.Net.ty Eio.Net.t option;
}

let set_network t net = t.net <- Some net

let create = function
  | Openai { api_key; base_url; organization } ->
    if String.length api_key = 0 then
      Result.Error (Invalid_input "api_key must not be empty")
    else
      Ok {
        api_key;
        base_url = Option.value base_url ~default:"https://api.openai.com/v1";
        organization;
        net = None;
      }
  | _ -> Result.Error (Invalid_input "OpenAI provider requires Openai configuration")

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

let tool_descriptor_to_json (td : tool_descriptor) =
  `Assoc [
    ("type", `String "function");
    ("function", `Assoc [
      ("name", `String td.name);
      ("description", `String td.description);
      ("parameters", td.input_schema);
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
    ("tools", `List (List.map tool_descriptor_to_json tools)) :: fields
  else fields
  in
  Yojson.Safe.to_string (`Assoc fields)

(* -------------------------------------------------------------------------- *)
(* HTTP helpers                                                          *)
(* -------------------------------------------------------------------------- *)

let build_auth_headers t =
  let base = [ ("Authorization", "Bearer " ^ t.api_key) ] in
  match t.organization with
  | Some o -> ("OpenAI-Organization", o) :: base
  | None -> base

(* -------------------------------------------------------------------------- *)
(* JSON response parsing                                                 *)
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
(* SSE parsing                                                           *)
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
    let tool_chunks =
      try
        let tcs = delta |> member "tool_calls" |> to_list in
        ( match tcs with
        | tc :: _ ->
          let fn = tc |> member "function" in
          let idx = tc |> member "index" |> to_int in
          let key = string_of_int idx in
          let name = try fn |> member "name" |> to_string with _ -> "" in
          let args = try fn |> member "arguments" |> to_string with _ -> "" in
          if name <> "" then begin
            let start = Tool_call_start { tool_call_id = key; name } in
            if args <> "" && args <> "null" then
              [ start; Tool_call_delta { tool_call_id = key; args_json = args } ]
            else
              [ start ]
          end else if args <> "" && args <> "null" then
            [ Tool_call_delta { tool_call_id = key; args_json = args } ]
          else []
        | [] -> [] )
      with _ -> []
    in
    (text_chunk, tool_chunks, finish_opt, usage_opt)
  | [] -> (None, [], None, None)

(* -------------------------------------------------------------------------- *)
(* LLM_SERVICE implementation                                            *)
(* -------------------------------------------------------------------------- *)

let complete t model_config tools conversation =
  match t.net with
  | None -> Result.Error (Internal "Network not initialized; call set_network first")
  | Some net ->
    let url = Http_client.parse_url t.base_url in
    let body = build_request_body ~model_config ~tools ~conversation ~stream:false in
    let headers = build_auth_headers t in
    let request =
      Http_client.build_http_request
        ~host:url.Http_client.host
        ~path:(url.Http_client.path ^ "chat/completions")
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
      | Eio.Io _ -> Result.Error (External_failure "Network error during OpenAI request")
      | Failure msg -> Result.Error (Invalid_input msg)
      | exn -> Result.Error (Internal (Printexc.to_string exn)) )

let stream t model_config tools conversation _stream_config callback =
  match t.net with
  | None -> Result.Error (Internal "Network not initialized; call set_network first")
  | Some net ->
    let url = Http_client.parse_url t.base_url in
    let body = build_request_body ~model_config ~tools ~conversation ~stream:true in
    let headers = build_auth_headers t in
    let request =
      Http_client.build_http_request
        ~host:url.Http_client.host
        ~path:(url.Http_client.path ^ "chat/completions")
        ~headers ~body
    in
    ( try
        Http_client.do_request_streaming net url request
          (fun ~status:_ ~headers:_ ~read_line ->
            let chunks = ref 0 in
            let usage =
              ref { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 }
            in
            let finish = ref Stop in
            let rec process_lines () =
              match read_line () with
              | None -> ()
              | Some line ->
                if String.starts_with ~prefix:"data: " line then begin
                  let data =
                    String.sub line 6 (String.length line - 6) |> String.trim
                  in
                  if data <> "[DONE]" then begin
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
                      | chunk :: rest ->
                        List.iter (fun c -> callback c; incr chunks) (chunk :: rest)
                      | [] -> () );
                      ( match finish_opt with
                      | Some f -> finish := f
                      | None -> () );
                      ( match usage_opt with
                      | Some u -> usage := u
                      | None -> () )
                    with _ -> ()
                  end
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
      | Eio.Io _ -> Result.Error (External_failure "Network error during OpenAI stream")
      | Failure msg -> Result.Error (Invalid_input msg)
      | exn -> Result.Error (Internal (Printexc.to_string exn)) )

let close _t = ()
