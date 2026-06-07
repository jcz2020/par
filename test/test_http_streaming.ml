(* test/test_http_streaming.ml — v0.3.5 HTTP streaming response parser tests.

   Pins the behaviour of [Http_client.do_request_streaming_with_flow]:
   - chunked transfer encoding is decoded line-by-line
   - non-chunked responses are streamed as lines until EOF
   - the parser correctly reassembles lines when the underlying source
     returns data in small chunks (small-buffer fragmentation)
   - non-2xx responses surface as [Http_status_error (int * string)]

   The tests feed raw HTTP response bytes through an [Eio.Flow.string_source]
   or a custom small-chunk source, so no real network is involved. *)

module Http_client = Par__Http_client

let () = Logs.set_level (Some Logs.Warning) |> ignore

(* -------------------------------------------------------------------------- *)
(* Custom small-chunk source                                                   *)
(* -------------------------------------------------------------------------- *)

(* A [Flow.source] that returns at most [chunk_size] bytes per [single_read].
   Used to verify that [Eio.Buf_read.of_flow] and our chunked decoder
   correctly reassemble data split across many small reads. *)
module Chunked_source = struct
  type t = { data : string; mutable pos : int; chunk_size : int }

  let single_read t buf =
    let remaining = String.length t.data - t.pos in
    if remaining = 0 then 0
    else begin
      let to_read =
        min (min (Cstruct.length buf) t.chunk_size) remaining
      in
      Cstruct.blit_from_string t.data t.pos buf 0 to_read;
      t.pos <- t.pos + to_read;
      to_read
    end

  let read_methods = []
end

let make_small_chunk_flow ~chunk_size data =
  let state = { Chunked_source.data; pos = 0; chunk_size } in
  let ops = Eio.Flow.Pi.source (module Chunked_source) in
  Eio.Resource.T (state, ops)

(* -------------------------------------------------------------------------- *)
(* Helper: drain read_line into a list                                        *)
(* -------------------------------------------------------------------------- *)

let drain_lines read_line =
  let acc = ref [] in
  let rec loop () =
    match read_line () with
    | Some line -> acc := line :: !acc; loop ()
    | None -> List.rev !acc
  in
  loop ()

(* -------------------------------------------------------------------------- *)
(* Test 1: chunked SSE                                                         *)
(* -------------------------------------------------------------------------- *)

let test_chunked_sse_single_chunk () =
  Eio_main.run @@ fun _env ->
  let raw =
    "HTTP/1.1 200 OK\r\n\
     Content-Type: text/event-stream\r\n\
     Transfer-Encoding: chunked\r\n\
     \r\n\
     8\r\n\
     data: hi\r\n\
     0\r\n\
     \r\n"
  in
  let flow = Eio.Flow.string_source raw in
  let status, lines =
    Http_client.do_request_streaming_with_flow flow
      (fun ~status ~headers:_ ~read_line -> status, drain_lines read_line)
  in
  Alcotest.(check int) "status" 200 status;
  Alcotest.(check (list string)) "lines" ["data: hi"] lines

(* -------------------------------------------------------------------------- *)
(* Test 2: non-chunked SSE                                                     *)
(* -------------------------------------------------------------------------- *)

let test_non_chunked_two_lines () =
  Eio_main.run @@ fun _env ->
  let raw =
    "HTTP/1.1 200 OK\r\n\
     Content-Type: text/event-stream\r\n\
     \r\n\
     data: hello\n\
     data: world\n"
  in
  let flow = Eio.Flow.string_source raw in
  let status, lines =
    Http_client.do_request_streaming_with_flow flow
      (fun ~status ~headers:_ ~read_line -> status, drain_lines read_line)
  in
  Alcotest.(check int) "status" 200 status;
  Alcotest.(check (list string)) "lines" ["data: hello"; "data: world"] lines

(* -------------------------------------------------------------------------- *)
(* Test 3: small-chunk fragmented reads                                       *)
(* -------------------------------------------------------------------------- *)

let test_fragmented_chunked_reads () =
  Eio_main.run @@ fun _env ->
  let raw =
    "HTTP/1.1 200 OK\r\n\
     Content-Type: text/event-stream\r\n\
     Transfer-Encoding: chunked\r\n\
     \r\n\
     8\r\n\
     data: hi\r\n\
     0\r\n\
     \r\n"
  in
  (* Feed the response 3 bytes at a time so the buffered reader is forced
     to call the source many times to assemble each line. *)
  let flow = make_small_chunk_flow ~chunk_size:3 raw in
  let status, lines =
    Http_client.do_request_streaming_with_flow flow
      (fun ~status ~headers:_ ~read_line -> status, drain_lines read_line)
  in
  Alcotest.(check int) "status" 200 status;
  Alcotest.(check (list string)) "lines" ["data: hi"] lines

(* -------------------------------------------------------------------------- *)
(* Test 4: non-200 status raises Http_status_error                            *)
(* -------------------------------------------------------------------------- *)

let test_non_200_raises () =
  Eio_main.run @@ fun _env ->
  let raw =
    "HTTP/1.1 429 Too Many Requests\r\n\
     \r\n\
     rate limited"
  in
  let flow = Eio.Flow.string_source raw in
  let caught_status = ref None in
  let caught_other = ref None in
  (try
     ignore
       (Http_client.do_request_streaming_with_flow flow
          (fun ~status ~headers:_ ~read_line:_ -> status))
   with
   | Http_client.Http_status_error (s, _body) -> caught_status := Some s
   | exn -> caught_other := Some (Printexc.to_string exn));
  match !caught_status, !caught_other with
  | Some 429, _ -> ()
  | Some s, _ -> Alcotest.failf "expected status 429, got %d" s
  | _, Some msg -> Alcotest.failf "expected Http_status_error, got %s" msg
  | None, None -> Alcotest.fail "expected Http_status_error, got no exception"

(* -------------------------------------------------------------------------- *)
(* Main                                                                        *)
(* -------------------------------------------------------------------------- *)

let () =
  let open Alcotest in
  run "http_streaming" [
    "chunked", [
      test_case "single chunk decodes line" `Quick test_chunked_sse_single_chunk;
    ];
    "non_chunked", [
      test_case "two lines, EOF after last" `Quick test_non_chunked_two_lines;
    ];
    "fragmented", [
      test_case "3-byte reads, chunked"  `Quick test_fragmented_chunked_reads;
    ];
    "error_paths", [
      test_case "429 raises Http_status_error" `Quick test_non_200_raises;
    ];
  ]
