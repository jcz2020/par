(** Process-wide deprecation signaling for the PAR SDK.

    Addresses issue #6: breaking API changes used to happen silently — no
    compile-time warning, no runtime signal, no event for operators. This
    module gives every deprecated call site two signals:

    {ul
    {- A [Logs.warn] entry, fired {b once per process} per [fn_name]
       (idempotent).}
    {- A [Deprecated_api_called] event on the registered emitter, fired the
       first time a given [fn_name] is used. Wire the emitter to
       [Runtime.publish_event] at startup so the event reaches the bus,
       persistence, and any audit consumers.}}

    Outside a runtime (e.g. in a library consumer that has not constructed a
    [Runtime.t] yet), the event is simply dropped — the log warning still
    fires. Both contexts are supported by design.

    This module is thread-safe: the idempotency table and the emitter
    reference are guarded by an [Eio.Mutex]. The mutex is uncontended in the
    common case (deprecation hits are rare), so it never suspends an Eio
    fiber when uncontested.

    Usage at a deprecated call site:

    {[
      let old_api x =
        Deprecation.warn_once
          ~since:"v0.6.9" ~removed_in:"v0.8"
          ~migration:"use Runtime.install_bash_tool ~fs:(Eio.Stdenv.fs env)"
          ~fn_name:"Module.old_api" ();
        new_api x
    ]}

    Pair the runtime warning with an OCaml [@@deprecated] attribute on the
    [.mli] so callers also get a compile-time signal:

    {[
      val old_api : int -> unit
        [@@deprecated "since v0.6.9, use new_api; removed in v0.8"]
    ]} *)

val warn_once :
  since:string ->
  removed_in:string ->
  migration:string ->
  fn_name:string ->
  unit -> unit
(** Emit a deprecation signal for [fn_name] exactly once per process.

    - [since] is the PAR version that deprecated the API (e.g. ["v0.6.9"]).
    - [removed_in] is the version that will delete it (e.g. ["v0.8"]).
    - [migration] is a one-line fix description pointing at the replacement.
    - [fn_name] is the fully-qualified identifier (e.g.
      ["Runtime.install_bash_tool"]) used as the idempotency key.

    On the first call for a given [fn_name]: logs at [Logs.Warn] and, if an
    emitter is registered, fires a [Deprecated_api_called] event. Subsequent
    calls with the same [fn_name] are silent (no log, no event). Distinct
    [fn_name]s each get their own first-call signal. *)

val register_event_emitter : (Types.event -> unit) -> unit
(** Register the sink that receives [Deprecated_api_called] events.

    Intended to be wired to [Runtime.publish_event] once at runtime startup
    so deprecation hits reach the event bus, the SQLite audit log, and any
    downstream consumers. Calling it again replaces the previous emitter;
    pass the identity function to inspect events in tests. The callback is
    invoked {i outside} the module's mutex, so it may call back into
    [Deprecation] without deadlocking. *)

val reset_for_tests : unit -> unit
(** Clear the idempotency table and drop the registered emitter.

    Tests only: lets a single test process exercise the first-call path for
    the same [fn_name] repeatedly. Never call this in production code — it
    defeats the idempotency guarantee. *)
