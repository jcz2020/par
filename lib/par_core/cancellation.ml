open Types

type t = cancellation_token

let create_token switch = { switch; cancelled = false }

let is_cancelled token = token.cancelled

let check_cancel token =
  if token.cancelled then raise (Eio.Cancel.Cancelled (Failure "cancelled"))
  else Eio.Fiber.yield ()

let request_cancel token =
  token.cancelled <- true

let with_timeout _seconds token f =
  let result = ref None in
  Eio.Fiber.first
    (fun () ->
      let v = f token in
      result := Some (Ok v);
      Eio.Fiber.yield ())
    (fun () ->
      if token.cancelled then result := Some (Error `Cancelled)
      else result := Some (Error `Timeout));
  match !result with
  | Some r -> r
  | None -> Error `Timeout

let cancellable_handler token _check_interval handler input =
  if is_cancelled token then
    Types.Error { category = Timeout; message = "Cancelled"; retryable = false; metadata = [] }
  else
    handler input
