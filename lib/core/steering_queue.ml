(* Steering/Follow-up message queue — FIFO with bounded capacity.
   When a queue overflows, the oldest message is dropped and a warning logged.
   Mirrors pi-agent-core's PendingMessageQueue behavior. *)

let max_capacity = 100

type t = {
  mutable messages : string list;
  mutable dropped : int;
  capacity : int;
  mutable closed : bool;
}

let create ?(capacity = max_capacity) () = {
  messages = [];
  dropped = 0;
  capacity;
  closed = false;
}

let enqueue t msg =
  if t.closed then
    Logs.warn (fun m -> m "Steering_queue: enqueue on closed queue, message dropped")
  else begin
    t.messages <- t.messages @ [msg];
    let len = List.length t.messages in
    if len > t.capacity then begin
      let excess = len - t.capacity in
      let keep = List.filteri (fun i _ -> i >= excess) t.messages in
      t.messages <- keep;
      t.dropped <- t.dropped + excess;
      Logs.warn (fun m ->
        m "Steering_queue: dropped %d old message(s) (capacity=%d)"
          excess t.capacity)
    end
  end

let drain_all t =
  if t.messages = [] then []
  else begin
    let msgs = List.rev t.messages in
    t.messages <- [];
    msgs
  end

let has_items t = t.messages <> []

let count t = List.length t.messages

let close t = t.closed <- true
