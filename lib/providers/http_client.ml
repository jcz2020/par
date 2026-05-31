(* HTTP client utilities shared across LLM providers.
   Self-contained — no dependency on Types. *)

(* -------------------------------------------------------------------------- *)
(* URL parsing                                                                *)
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
(* HTTP request building                                                      *)
(* -------------------------------------------------------------------------- *)

let build_http_request ~host ~path ~headers ~body =
  let custom_headers =
    List.map (fun (k, v) -> Printf.sprintf "%s: %s\r\n" k v) headers
    |> String.concat ""
  in
  Printf.sprintf
    "POST %s HTTP/1.1\r\n\
     Host: %s\r\n\
     %s\
     Content-Type: application/json\r\n\
     Content-Length: %d\r\n\
     Connection: close\r\n\
     \r\n\
     %s"
    path host custom_headers (String.length body) body

(* -------------------------------------------------------------------------- *)
(* HTTP response parsing                                                      *)
(* -------------------------------------------------------------------------- *)

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

(* -------------------------------------------------------------------------- *)
(* HTTP status → error mapping                                                *)
(* -------------------------------------------------------------------------- *)

type http_error =
  | Invalid_input of string
  | Permission_denied of string
  | Rate_limited
  | Timeout
  | External_failure of string

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
(* TLS setup                                                                  *)
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
(* TCP + TLS connection                                                       *)
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

type _exec_result = {
  status : int;
  headers : string;
  body : string;
}

let _exec_request ~net ~url ~request =
  try
    let raw = do_request net url request in
    let hdrs, raw_body = split_response raw in
    let status = parse_status_line hdrs in
    let body = decode_body hdrs raw_body in
    Ok { status; headers = hdrs; body }
  with
  | Eio.Io _ -> Error (External_failure "Network error")
  | Failure msg -> Error (Invalid_input msg)
  | exn -> Error (External_failure (Printexc.to_string exn))
