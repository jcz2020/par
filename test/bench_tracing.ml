(* Manual benchmark for the Noop tracing path (PAR-8a41).

   Not a test: timing assertions are flaky in CI. Run with
   `make bench-tracing` (or `dune exec test/bench_tracing.exe`). *)

open Par

let now = Unix.gettimeofday

let measure ~n f =
  Gc.full_major ();
  let start = now () in
  for _ = 1 to n do f () done;
  let elapsed = now () -. start in
  elapsed *. 1e9 /. float_of_int n

let () =
  Eio_main.run (fun _env ->
    let n = 1_000_000 in
    let baseline = measure ~n (fun () -> ()) in
    let root_noop =
      measure ~n (fun () ->
        Tracing.with_root Tracing.noop ~name:"invoke" (fun () -> ()))
    in
    let span_without_context =
      measure ~n (fun () ->
        Tracing.with_span ~name:"llm.complete" (fun () -> ()))
    in
    Printf.printf
      "Noop tracing benchmark (n=%d, ns/op)\n\
       plain call           %8.2f\n\
       with_root noop       %8.2f  (+%.2f ns, +%.1f%%)\n\
       with_span no context %8.2f  (+%.2f ns, +%.1f%%)\n%!"
      n baseline root_noop (root_noop -. baseline)
      ((root_noop -. baseline) /. baseline *. 100.)
      span_without_context (span_without_context -. baseline)
      ((span_without_context -. baseline) /. baseline *. 100.))
