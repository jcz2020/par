open Types

(* Raised by the engine's streaming accumulator when the token has been
   cancelled.  It lives here (not in Engine) so providers can re-raise it
   instead of swallowing it in their per-event parse handlers. *)
exception Stream_cancelled_by_token

type t = cancellation_token

let create_token switch =
  { switch; cancelled = Atomic.make false; reason = Atomic.make None }

let is_cancelled token = Atomic.get token.cancelled

let check_cancel token =
  if is_cancelled token then raise (Eio.Cancel.Cancelled (Failure "cancelled"))
  else Eio.Fiber.yield ()

(* First-cause-wins.  [cancelled] is published before [reason]; a reader that
   observes the flag before the reason falls back to [User_cancelled]. *)
let request_cancel token reason =
  let rec publish () =
    if Atomic.get token.cancelled then ()
    else if Atomic.compare_and_set token.cancelled false true then
      Atomic.set token.reason (Some reason)
    else publish ()
  in
  publish ()

let reason token = Atomic.get token.reason

let with_timeout seconds token f =
  let result = ref None in
  let deadline = Unix.gettimeofday () +. seconds in
  Eio.Fiber.first
    (fun () ->
      let v = f token in
      result := Some (Ok v))
    (fun () ->
      if is_cancelled token then result := Some (Error `Cancelled)
      else begin
        while Unix.gettimeofday () < deadline && not (is_cancelled token) do
          Eio.Fiber.yield ()
        done;
        if is_cancelled token then result := Some (Error `Cancelled)
        else result := Some (Error `Timeout)
      end);
  match !result with
  | Some r -> r
  | None -> Error `Timeout

let cancellable_handler token _check_interval handler input =
  if is_cancelled token then
    Types.Error { category = Cancelled (Option.value (reason token) ~default:User_cancelled); message = "Cancelled"; retryable = false; metadata = [] }
  else
    handler input
