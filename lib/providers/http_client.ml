(* HTTP client utilities shared across LLM providers.
   Self-contained — no dependency on Types. *)

(* -------------------------------------------------------------------------- *)
(* URL parsing                                                                *)
(* -------------------------------------------------------------------------- *)

type parsed_url = { host : string; port : int; path : string; use_tls : bool }

let parse_url url =
  let use_tls, without_proto =
    if String.starts_with ~prefix:"https://" url then
      (true, String.sub url 8 (String.length url - 8))
    else if String.starts_with ~prefix:"http://" url then
      (false, String.sub url 7 (String.length url - 7))
    else (true, url)
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
    | None -> (host_part, if use_tls then 443 else 80)
  in
  let path = if String.ends_with ~suffix:"/" path then path else path ^ "/" in
  { host; port; path; use_tls }

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

let clock_ref : Obj.t option ref = ref None

let set_clock (c : 'a) = clock_ref := Some (Obj.repr c)

let request_timeout = ref 60.0

let set_request_timeout s = request_timeout := s

let with_timeout sw f =
  match !clock_ref with
  | None -> f ()
  | Some clock_obj ->
    let clock = (Obj.obj clock_obj : _ Eio.Time.clock_ty Eio.Resource.t) in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Time.sleep clock !request_timeout;
      Eio.Switch.fail sw (Failure (Printf.sprintf "HTTP request timed out after %.0fs" !request_timeout));
      `Stop_daemon);
    f ()

let tls_host_of_string host =
  match Domain_name.of_string host with
  | Error _ -> None
  | Ok dn -> ( match Domain_name.host dn with Ok h -> Some h | Error _ -> None )

(* -------------------------------------------------------------------------- *)
(* HTTP via cohttp-eio (handles Content-Length, chunked encoding, TLS properly) *)
(* -------------------------------------------------------------------------- *)

let tls_https_wrapper ?(cfg = Lazy.force tls_config) uri raw_flow =
  match Uri.host uri with
  | None -> Tls_eio.client_of_flow cfg raw_flow
  | Some host ->
    (match Domain_name.of_string host with
     | Ok dn ->
       (match Domain_name.host dn with
        | Ok h -> Tls_eio.client_of_flow cfg ~host:h raw_flow
        | Error _ -> Tls_eio.client_of_flow cfg raw_flow)
     | Error _ -> Tls_eio.client_of_flow cfg raw_flow)

let cohttp_client_of_net net =
  Cohttp_eio.Client.make ~https:(Some (tls_https_wrapper)) net

let parse_raw_request request =
  let header_end =
    let rec find i =
      if i + 4 > String.length request then String.length request
      else if String.sub request i 4 = "\r\n\r\n" then i
      else find (i + 1)
    in
    find 0
  in
  let header_block = String.sub request 0 header_end in
  let body =
    if header_end + 4 <= String.length request then
      String.sub request (header_end + 4) (String.length request - header_end - 4)
    else ""
  in
  let lines = String.split_on_char '\n' header_block
    |> List.map (fun l ->
      if String.length l > 0 && l.[String.length l - 1] = '\r' then
        String.sub l 0 (String.length l - 1) else l)
  in
  let path =
    match lines with
    | first :: _ ->
      (match String.split_on_char ' ' first with
       | _ :: p :: _ -> p
       | _ -> "/")
    | [] -> "/"
  in
  let headers =
    List.filter_map (fun line ->
      match String.index_opt line ':' with
      | Some i ->
        let k = String.sub line 0 i |> String.trim in
        let v = String.sub line (i + 1) (String.length line - i - 1) |> String.trim in
        if k = "" then None else Some (k, v)
      | None -> None
    ) (List.tl lines)
  in
  (path, headers, body)

let format_raw_response status_code reason headers body =
  let status_line = Printf.sprintf "HTTP/1.1 %d %s\r\n" status_code reason in
  let header_str =
    List.map (fun (k, v) -> Printf.sprintf "%s: %s\r\n" k v) headers
    |> String.concat ""
  in
  Printf.sprintf "%s%sContent-Length: %d\r\n\r\n%s" status_line header_str (String.length body) body

let do_request net url request =
  let (req_path, req_headers, req_body) = parse_raw_request request in
  let scheme = if url.use_tls then "https" else "http" in
  let uri_str = Printf.sprintf "%s://%s:%d%s" scheme url.host url.port req_path in
  let uri = Uri.of_string uri_str in
  Eio.Switch.run (fun sw ->
    with_timeout sw (fun () ->
      let client = cohttp_client_of_net net in
      let cohttp_headers = Cohttp.Header.of_list req_headers in
      let body = Cohttp_eio.Body.of_string req_body in
      let resp, resp_body = Cohttp_eio.Client.call ~sw
        ~headers:cohttp_headers ~body client `POST uri in
      let status_code = Cohttp.Code.code_of_status (Http.Response.status resp) in
      let body_string =
        Eio.Buf_read.parse_exn ~max_size:(100 * 1024 * 1024) Eio.Buf_read.take_all resp_body
      in
      let resp_headers =
        Cohttp.Header.to_list (Http.Response.headers resp)
        |> List.filter (fun (k, _) ->
          let lower = String.lowercase_ascii k in
          lower <> "content-length" && lower <> "transfer-encoding")
      in
      format_raw_response status_code "OK" resp_headers body_string))

(* -------------------------------------------------------------------------- *)
(* Incremental streaming response                                              *)
(* -------------------------------------------------------------------------- *)

exception Http_status_error of int * string

let max_stream_buffer = 50 * 1024 * 1024

(* State-machine reader for chunked transfer-encoded SSE bodies.
   The [pending] buffer accumulates chunk data across boundaries so that
   a single SSE line split between two chunks is reassembled before
   being surfaced to the caller. *)
let read_chunked_line buf pending done_ref : string option =
  let pop_line_from_pending () =
    let s = Buffer.contents pending in
    match String.index_opt s '\n' with
    | Some i ->
      let line = String.sub s 0 i in
      let rest = String.sub s (i + 1) (String.length s - i - 1) in
      Buffer.clear pending;
      Buffer.add_string pending rest;
      let stripped =
        let n = String.length line in
        if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1)
        else line
      in
      Some stripped
    | None -> None
  in
  let rec loop () =
    match pop_line_from_pending () with
    | Some _ as r -> r
    | None ->
      if !done_ref then
        if Buffer.length pending = 0 then None
        else begin
          let rest = Buffer.contents pending in
          Buffer.clear pending;
          let stripped =
            let n = String.length rest in
            if n > 0 && rest.[n - 1] = '\r' then String.sub rest 0 (n - 1)
            else rest
          in
          Some stripped
        end
      else begin
        let raw_size_line = Eio.Buf_read.line buf in
        let size_line =
          let line = match String.index_opt raw_size_line ';' with
            | Some i -> String.sub raw_size_line 0 i
            | None -> raw_size_line
          in
          let n = String.length line in
          if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1)
          else line
        in
        let size = int_of_string ("0x" ^ size_line) in
        if size = 0 then begin
          done_ref := true;
          let flow = Eio.Buf_read.as_flow buf in
          let cs = Cstruct.create 2 in
          (try Eio.Flow.read_exact flow cs with End_of_file -> ());
          loop ()
        end else begin
          let flow = Eio.Buf_read.as_flow buf in
          let cs = Cstruct.create size in
          Eio.Flow.read_exact flow cs;
          let s = Cstruct.to_string cs in
          Buffer.add_string pending s;
          let cs2 = Cstruct.create 2 in
          (try Eio.Flow.read_exact flow cs2 with End_of_file -> ());
          loop ()
        end
      end
  in
  loop ()

let read_unchunked_line buf : string option =
  try
    let line = Eio.Buf_read.line buf in
    let n = String.length line in
    let stripped =
      if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1)
      else line
    in
    Some stripped
  with
  | End_of_file -> None
  | Eio.Buf_read.Buffer_limit_exceeded as ex -> raise ex
  | Eio.Io _ as ex -> raise ex

let read_response_headers buf =
  let status_line = Eio.Buf_read.line buf in
  let status = parse_status_line status_line in
  let header_buf = Buffer.create 256 in
  Buffer.add_string header_buf status_line;
  Buffer.add_string header_buf "\r\n";
  let rec collect () =
    let line = Eio.Buf_read.line buf in
    Buffer.add_string header_buf line;
    Buffer.add_string header_buf "\r\n";
    if line = "" then Buffer.contents header_buf else collect ()
  in
  let headers = collect () in
  let chunked = headers_contain ~needle:"transfer-encoding: chunked" headers in
  (status, headers, chunked)

let do_request_streaming_with_flow flow k =
  let buf =
    Eio.Buf_read.of_flow ~initial_size:4096 ~max_size:max_stream_buffer flow
  in
  let status, headers, chunked = read_response_headers buf in
  if status < 200 || status >= 300 then begin
    let body =
      try Eio.Buf_read.line buf with _ -> ""
    in
    raise (Http_status_error (status, body))
  end;
  let read_line =
    if chunked then begin
      let pending = Buffer.create 4096 in
      let done_ref = ref false in
      (fun () -> read_chunked_line buf pending done_ref)
    end else
      (fun () -> read_unchunked_line buf)
  in
  k ~status ~headers ~read_line

let do_request_streaming net url request k =
  let (req_path, req_headers, req_body) = parse_raw_request request in
  let scheme = if url.use_tls then "https" else "http" in
  let uri_str = Printf.sprintf "%s://%s:%d%s" scheme url.host url.port req_path in
  let uri = Uri.of_string uri_str in
  Eio.Switch.run (fun sw ->
    with_timeout sw (fun () ->
      let client = cohttp_client_of_net net in
      let cohttp_headers = Cohttp.Header.of_list req_headers in
      let body = Cohttp_eio.Body.of_string req_body in
      let resp, resp_body = Cohttp_eio.Client.call ~sw
        ~headers:cohttp_headers ~body client `POST uri in
      let status = Cohttp.Code.code_of_status (Http.Response.status resp) in
      let headers_str = String.concat "\r\n" (
        List.map (fun (k,v) -> k ^ ": " ^ v) (Cohttp.Header.to_list (Http.Response.headers resp))
      ) in
      let r = Eio.Buf_read.of_flow ~max_size:(100 * 1024 * 1024) resp_body in
      k ~status ~headers:headers_str ~read_line:(fun () ->
        try Some (Eio.Buf_read.line r) with _ -> None)))

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
