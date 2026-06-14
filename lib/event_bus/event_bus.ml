open Types

type internal_subscription = {
  id : string;
  handler : event_envelope -> unit;
  nonce : string;
} [@@warning "-69"]

type subscription = string

type t = {
  config : event_bus_config;
  subscribers : (string, internal_subscription) protected_hashtbl;
  buffer : event_envelope Eio.Stream.t;
  dead_letters : dead_letter_entry list ref;
  mutex : Eio.Mutex.t;
  mutable current_session_id : string;
} [@@warning "-69"]

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
    current_session_id = "";
  }

let publish bus event =
  let id = Task_id.to_string (Task_id.create ()) in
  let envelope = {
    id;
    metadata = {
      trace_id = None;
      span_id = None;
      timestamp = Unix.time ();
      source = "event_bus";
      session_id = bus.current_session_id;
    };
    payload = event;
    idempotency_key = Task_id.to_string (Task_id.create ());
    delivery_attempt = 0;
  } in
  if Eio.Stream.length bus.buffer >= bus.config.buffer_capacity then begin
    let entry = {
      envelope;
      error = "buffer full: backpressure";
      failure_reason = Internal "buffer full: backpressure";
      failed_at = Unix.time ();
      attempt_count = 0;
    } in
    Eio.Mutex.use_rw ~protect:false bus.mutex (fun () ->
      bus.dead_letters := entry :: !(bus.dead_letters)
    )
  end else
    Eio.Stream.add bus.buffer envelope

let subscribe bus handler =
  let sub_id = Task_id.to_string (Task_id.create ()) in
  let nonce = Task_id.to_string (Task_id.create ()) in
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
    match handler envelope with
    | () -> ()
    | exception e ->
      let entry = {
        envelope;
        error = Printexc.to_string e;
        failure_reason = Internal (Printexc.to_string e);
        failed_at = Unix.time ();
        attempt_count = envelope.delivery_attempt + 1;
      } in
      Eio.Mutex.use_rw ~protect:false bus.mutex (fun () ->
        bus.dead_letters := entry :: !(bus.dead_letters)
      )
  ) !handlers

let start_dispatcher bus switch =
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

let dlq_entries bus =
  List.map (fun (entry : dead_letter_entry) -> entry.envelope.payload)
    (get_dead_letters bus)

let to_service (bus : t) : Types.event_bus_service = {
  publish_fn = (fun evt -> publish bus evt);
  subscribe_fn = (fun handler -> subscribe bus handler);
  unsubscribe_fn = (fun sub -> unsubscribe bus sub);
  set_session_id_fn = (fun sid -> bus.current_session_id <- sid);
  start_dispatcher_fn = (fun sw -> ignore (start_dispatcher bus sw));
}

let set_session_id (bus : t) (sid : string) =
  bus.current_session_id <- sid
