(* Ownership of an in-flight durable invoke, for runtimes that share one
   database.

   Two runtimes over the same database each see the other's in-flight run as a
   leftover row. Recovering it would execute the same tools twice. The lease
   says who is running it, so recovery only happens once the holder is gone.

   Liveness has two signals, and the stronger one wins:

   - the holder's process: a process that died holds nothing. This is exact
     and immediate, so a crashed run is recoverable at once;
   - the expiry: the fallback for platforms without a process probe, and for
     the case where the pid was reused by an unrelated process.

   The holder refreshes its lease as it works, so the expiry stays ahead of a
   live run. *)

(** Is the process that holds a lease still running? *)
let process_alive pid =
  if pid <= 0 then false
  else if Sys.os_type = "win32" then
    (* No process probe here: fall back to the expiry. *)
    true
  else
    try
      Unix.kill pid 0;
      true
    with
    | Unix.Unix_error (Unix.ESRCH, _, _) -> false
    (* The process exists but belongs to another user: it is alive. *)
    | Unix.Unix_error _ -> true

(** A lease may be taken when it has expired, or when the process holding it
    is gone. A live holder keeps it. *)
let is_takeable ~now (lease : Types.invoke_lease) =
  lease.expires_at <= now || not (process_alive lease.pid)

(** The same lease is ours when we already hold it. *)
let is_owned_by ~owner (lease : Types.invoke_lease) =
  lease.owner = owner

(** [describe_holder lease] names who holds a lease, for a refusal message. *)
let describe_holder (lease : Types.invoke_lease) =
  Printf.sprintf "owner %s (pid %d) until %.0f"
    lease.owner lease.pid lease.expires_at
