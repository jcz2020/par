(* PAR-acj: raw HTTP request with explicit socket close on timeout.
   This bypasses cohttp-eio's connection management, giving direct control
   over the TCP flow so we can close it when the timeout fires. Closing
   the flow unblocks the read fiber, allowing Fiber.first to return before
   switch cleanup starts, avoiding the Eio switch-cleanup deadlock on
   uncancellable reads.

   This module has NO .mli — all values are public. *)

[@@@warning "-5-32"]

let clock_ref = ref None

let set_clock (c : 'a) = clock_ref := Some (Obj.repr c)

let get_clock () =
  match !clock_ref with
  | None -> failwith "Http_timeout clock not set"
  | Some c -> (Obj.obj c : _ Eio.Time.clock_ty Eio.Resource.t)

let resolve_host host =
  match Ipaddr.of_string host with
  | Ok ip -> Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets ip)
  | Error _ ->
    let entry = Unix.gethostbyname host in
    if Array.length entry.Unix.h_addr_list = 0 then failwith ("DNS: " ^ host)
    else Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets (Ipaddr.of_string_exn (Unix.string_of_inet_addr entry.Unix.h_addr_list.(0))))

let raw_request ~sw ~net ~host ~port ~use_tls ~method_ ~path ~req_headers ~req_body ~close_fn =
  let ip = resolve_host host in
  let tcp_flow = Eio.Net.connect ~sw net (`Tcp (ip, port)) in
  let flow : _ Eio.Flow.source = if use_tls then failwith "TLS in raw_request not yet supported" else tcp_flow in
  let sink : _ Eio.Flow.sink = tcp_flow in
  let _ = flow in
  close_fn := (fun () -> (try Eio.Flow.close tcp_flow with _ -> ()));
  let hdr = String.concat "\r\n" (List.map (fun (k, v) -> k ^ ": " ^ v) req_headers) in
  let req = Printf.sprintf "%s %s HTTP/1.1\r\nHost: %s\r\n%s\r\nConnection: close\r\n\r\n%s"
    method_ path host (if hdr = "" then "" else "\r\n" ^ hdr) req_body in
  Eio.Flow.copy (Eio.Flow.string_source req) sink;
  let reader = Eio.Buf_read.of_flow ~initial_size:4096 ~max_size:(100 * 1024 * 1024) tcp_flow in
  let status = match String.split_on_char ' ' (Eio.Buf_read.line reader) with
    | _ :: c :: _ -> (try int_of_string (String.trim c) with _ -> 0) | _ -> 0 in
  let hb = Buffer.create 256 in
  let rec read_hdrs () =
    let l = Eio.Buf_read.line reader in
    if String.trim l = "" then () else (Buffer.add_string hb l; Buffer.add_char hb '\n'; read_hdrs ())
  in
  read_hdrs ();
  (status, Buffer.contents hb, Eio.Buf_read.take_all reader)

let request_with_timeout ~timeout ~net ~host ~port ~use_tls ~method_ ~path ~request_headers ?(request_body = "") () =
  let clock = get_clock () in
  let result =
    Eio.Fiber.first
      (fun () ->
        `Ok (Eio.Switch.run (fun sw ->
          let cf = ref ignore in
          raw_request ~sw ~net ~host ~port ~use_tls ~method_ ~path ~req_headers:request_headers ~req_body:request_body ~close_fn:cf)))
      (fun () ->
        Eio.Time.sleep clock timeout;
        `Timeout)
  in
  match result with
  | `Ok r -> r
  | `Timeout ->
    raise (Failure (Printf.sprintf "HTTP request timed out after %.0fs" timeout))
