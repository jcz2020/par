open Types

type subscription = {
  id : string;
  handler : event -> unit Eio.Fiber.t;
  nonce : string;
}

type t = {
  config : event_bus_config;
  subscribers : (string, subscription) protected_hashtbl;
  buffer : event_envelope Eio.Stream.t;
  dead_letters : dead_letter_entry list ref;
  mutex : Eio.Mutex.t;
}

let create config =
  let buffer = Eio.Stream.create config.buffer_capacity in
  {
    config;
    subscribers = {
      data = Hashtbl.create 16;
      mutex = Eio.Mutex.create ();
    };
    buffer;
    dead_letters = ref [];
    mutex = Eio.Mutex.create ();
  }

let publish bus event =
  let envelope = {
    id = Task_id.create ();
    metadata = {
      trace_id = None;
      span_id = None;
      timestamp = Unix.time ();
      source = "event_bus";
    };
    payload = event;
    idempotency_key = Task_id.create ();
    delivery_attempt = 0;
  } in
  Eio.Stream.add bus.buffer envelope

let subscribe bus handler =
  let sub_id = Task_id.create () in
  let nonce = Task_id.create () in
  let sub = { id = sub_id; handler; nonce } in
  htbl_set bus.subscribers sub_id sub;
  sub_id

let unsubscribe bus sub_id =
  htbl_remove bus.subscribers sub_id

let deliver_to_subscribers bus envelope =
  let handlers = ref [] in
  htbl_iter bus.subscribers (fun _id sub ->
    handlers := sub.handler :: !handlers
  );
  List.iter (fun handler ->
    match handler envelope.payload with
    | () -> ()
    | exception e ->
      let entry = {
        envelope;
        error = Printexc.to_string e;
        failure_reason = Internal (Printexc.to_string e);
        failed_at = Unix.time ();
        attempt_count = envelope.delivery_attempt + 1;
      } in
      Eio.Mutex.use_rw bus.mutex (fun () ->
        bus.dead_letters := entry :: !(bus.dead_letters)
      )
  ) !handlers

let rec start_dispatcher bus switch =
  Eio.Fiber.fork ~sw:switch (fun () ->
    let rec loop () =
      let envelope = Eio.Stream.take bus.buffer in
      let updated = { envelope with delivery_attempt = envelope.delivery_attempt + 1 } in
      deliver_to_subscribers bus updated;
      loop ()
    in
    loop ()
  )

let get_dead_letters bus =
  Eio.Mutex.use_ro bus.mutex (fun () -> !(bus.dead_letters))
