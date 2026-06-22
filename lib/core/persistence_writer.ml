open Types

let string_of_error_category (e : error_category) =
  match e with
  | Timeout -> "Timeout"
  | Invalid_input msg -> Printf.sprintf "Invalid_input: %s" msg
  | External_failure msg -> Printf.sprintf "External_failure: %s" msg
  | Rate_limited -> "Rate_limited"
  | Permission_denied msg -> Printf.sprintf "Permission_denied: %s" msg
  | Internal msg -> Printf.sprintf "Internal: %s" msg
  | Embedding_unsupported -> "Embedding_unsupported"

type t = {
  mutable buffer : event_envelope list;
  buffer_capacity : int;
  flush_interval : float;
  save_fn : event_envelope list -> (unit, error_category) result;
  overflow_fn : event_envelope -> unit;
  mutex : Eio.Mutex.t;
  mutable running : bool;
} [@@warning "-69"]

let create ?(capacity = 1000) ?(flush_interval = 0.05) ?(overflow_fn = fun _ -> ()) save_fn =
  {
    buffer = [];
    buffer_capacity = capacity;
    flush_interval;
    save_fn;
    overflow_fn;
    mutex = Eio.Mutex.create ();
    running = false;
  }

let push writer envelope =
  Eio.Mutex.use_rw ~protect:false writer.mutex (fun () ->
    if List.length writer.buffer >= writer.buffer_capacity then begin
      writer.overflow_fn envelope
    end else
      writer.buffer <- envelope :: writer.buffer
  )

let flush_batch writer ?(prefix = "") batch =
  if batch <> [] then
    match writer.save_fn batch with
    | Ok () -> ()
    | Error e ->
      Logs.err (fun m ->
        m "persistence_writer:%s save failed: %s" prefix
          (string_of_error_category e))

let grab_pending writer =
  Eio.Mutex.use_rw ~protect:false writer.mutex (fun () ->
    let batch = List.rev writer.buffer in
    writer.buffer <- [];
    batch)

let start_drain_fiber writer switch =
  writer.running <- true;
  Eio.Fiber.fork_daemon ~sw:switch (fun () ->
    let rec loop () : [ `Stop_daemon ] =
      if not writer.running then `Stop_daemon
      else begin
        (try
          Eio.Fiber.yield ();
          Eio.Fiber.yield ();
          let batch = grab_pending writer in
          flush_batch writer batch;
          loop ()
        with Eio.Cancel.Cancelled _ ->
          writer.running <- false;
          let batch = grab_pending writer in
          flush_batch ~prefix:"cancel " writer batch;
          `Stop_daemon)
      end
    in
    loop ())

let flush_sync writer =
  writer.running <- false;
  let batch = grab_pending writer in
  flush_batch ~prefix:"flush_sync " writer batch
