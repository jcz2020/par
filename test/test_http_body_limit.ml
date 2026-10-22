open Par

(* test/test_http_body_limit.ml — verifies the download ceiling the web tools
   enforce is actually applied while reading the response.

   The ceiling used to be a dead constant: the tools advertised a 10MB limit
   that nothing enforced, and the body was buffered in memory with no bound
   beyond the shared 100MB reader default. The cap is now passed to the HTTP
   read, so an oversized response fails instead of being buffered. *)

let body_of_size n = String.make n 'x'

(* Server that answers exactly one request with a fixed body. *)
let with_body_server env ~body f =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  let server = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:5 addr in
  let port =
    match Eio.Net.listening_addr server with
    | `Tcp (_, p) -> p
    | _ -> failwith "expected TCP listening address"
  in
  let url = Printf.sprintf "http://127.0.0.1:%d/" port in
  Eio.Fiber.fork ~sw (fun () ->
    try
      let flow, _addr = Eio.Net.accept ~sw server in
      let reader = Eio.Buf_read.of_flow ~initial_size:1024 ~max_size:65536 flow in
      (try
         while String.trim (Eio.Buf_read.line reader) <> "" do () done
       with _ -> ());
      let header =
        Printf.sprintf
          "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
          (String.length body)
      in
      (try
         Eio.Flow.copy (Eio.Flow.string_source header) flow;
         Eio.Flow.copy (Eio.Flow.string_source body) flow;
       with _ -> ());
      (try Eio.Flow.close flow with _ -> ())
    with _ -> ());
  f url

let get env url ~max_body_size =
  let uri = Uri.of_string url in
  let host = match Uri.host uri with Some h -> h | None -> "localhost" in
  let port = match Uri.port uri with Some p -> p | None -> 80 in
  Http_timeout.request_with_timeout
    ~timeout:15.0 ~net:(Eio.Stdenv.net env) ~host ~port ~use_tls:false
    ~method_:"GET" ~path:"/" ~request_headers:[]
    ~max_body_size ()

let test_oversized_body_is_rejected () =
  Eio_main.run @@ fun env ->
  Http_client.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun _sw ->
  with_body_server env ~body:(body_of_size (64 * 1024)) (fun url ->
    let raised =
      match get env url ~max_body_size:(4 * 1024) with
      | exception Eio.Buf_read.Buffer_limit_exceeded -> true
      | _ -> false
    in
    Alcotest.(check bool) "oversized body is rejected while reading" true raised)

let test_body_within_cap_is_returned () =
  Eio_main.run @@ fun env ->
  Http_client.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun _sw ->
  with_body_server env ~body:(body_of_size (4 * 1024)) (fun url ->
    let status, _hdrs, body = get env url ~max_body_size:(64 * 1024) in
    Alcotest.(check int) "status" 200 status;
    Alcotest.(check int) "body length" (4 * 1024) (String.length body))

let () =
  Alcotest.run "http body limit" [
    "download cap", [
      Alcotest.test_case "body over the cap is rejected" `Quick test_oversized_body_is_rejected;
      Alcotest.test_case "body within the cap is returned" `Quick test_body_within_cap_is_returned;
    ];
  ]
