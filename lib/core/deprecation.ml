(* Process-wide deprecation signaling. See [deprecation.mli] for the
   contract. The two pieces of mutable state — the idempotency table and
   the optional emitter — are guarded by a single [Eio.Mutex], matching the
   [protected_hashtbl] pattern used elsewhere in lib/core. *)

open Types

let mutex : Eio.Mutex.t = Eio.Mutex.create ()

let warned : (string, unit) Hashtbl.t = Hashtbl.create 16

let emitter : (event -> unit) option ref = ref None

let register_event_emitter fn =
  Eio.Mutex.use_rw ~protect:false mutex (fun () ->
    emitter := Some fn)

let reset_for_tests () =
  Eio.Mutex.use_rw ~protect:false mutex (fun () ->
    Hashtbl.reset warned;
    emitter := None)

let warn_once ~since ~removed_in ~migration ~fn_name () =
  (* Decide + record under the lock, then fire the side effects outside it.
     Firing [Logs.warn] / the emitter inside the mutex would (a) risk
     deadlock if the emitter calls back into [Deprecation], and (b) hold the
     mutex across slow I/O. The [should_fire] flag and the [emit] snapshot
     are captured atomically, so two concurrent first-callers cannot both
     slip through — exactly one wins the [Hashtbl.add]. *)
  let should_fire, emit =
    Eio.Mutex.use_rw ~protect:false mutex (fun () ->
      let first_time = not (Hashtbl.mem warned fn_name) in
      if first_time then Hashtbl.add warned fn_name ();
      (first_time, !emitter))
  in
  if should_fire then begin
    Logs.warn (fun m ->
      m "%s is deprecated since %s and will be removed in %s. Migration: %s"
        fn_name since removed_in migration);
    match emit with
    | Some fn -> fn (Deprecated_api_called { fn_name; since; removed_in; migration })
    | None -> ()
  end
