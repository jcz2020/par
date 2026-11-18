(** Typed tracing spans produced by the runtime.

    This module is the production side of W2: the runtime emits spans at
    engine boundaries and never chooses an exporter. {!noop} is the default;
    pass a custom {!tracer} to [Runtime.create] to receive the tree.

    All functions degrade to a plain call when no tracer is injected, so the
    Noop path is one physical-equality check per boundary. *)

type span_kind = [ `Internal | `Client | `Server ]

type span = {
  trace_id : string;               (** 32 lowercase hex characters (W3C). *)
  span_id : string;                (** 16 lowercase hex characters (W3C). *)
  parent_span_id : string option;
  name : string;                   (** invoke / llm.complete / tool.call / mcp.call / workflow.step *)
  kind : span_kind;
  started_at : float;              (** Unix epoch seconds. *)
  attributes : (string * string) list;
}

type tracer = {
  on_start : span -> unit;
  on_end : span -> status:string -> unit;
}
(** [status] is ["ok"], ["error"] or ["cancelled"]. Hosts map these to their
    SDK's status type. *)

val noop : tracer
(** Discards every span. This is the runtime default. *)

val is_noop : tracer -> bool

type context = { tracer : tracer; span : span }
(** The fiber-local carrier: the active tracer plus the enclosing span. *)

val context_key : context Eio.Fiber.key

val current : unit -> context option
(** The span bound to the current fiber, if any. *)

val current_trace_id : unit -> string option
val current_span_id : unit -> string option
(** W3C Trace Context propagation helpers for outbound HTTP. *)

val traceparent_header : trace_id:string -> span_id:string -> string
(** [00-<trace_id>-<span_id>-01]. *)

val outgoing_headers : unit -> (string * string) list
(** [("traceparent", ...)] when a span is active, otherwise [[]]. Callers
    prepend these to their outbound request headers. *)

val parse_traceparent : string -> (string * string) option
(** Parse an inbound W3C [traceparent] into [(trace_id, parent_span_id)].
    Malformed or all-zero ids are ignored. *)

val span_to_yojson : span -> Yojson.Safe.t
(** Wire form used by the C bridge for Python tracers. *)

val make_span :
  trace_id:string ->
  ?parent_span_id:string ->
  name:string ->
  kind:span_kind ->
  attributes:(string * string) list ->
  unit ->
  span

val with_span :
  ?kind:span_kind ->
  ?attributes:(string * string) list ->
  ?status:('a -> [ `Ok | `Error | `Cancelled ]) ->
  name:string ->
  (unit -> 'a) ->
  'a
(** [with_span ~name f] runs [f] under a child of the current span. Outside a
    root span it just runs [f] (there is no tracer to report to). Exceptions
    end the span with ["error"]; Eio cancellation ends it with ["cancelled"]. *)

val with_root :
  tracer ->
  ?kind:span_kind ->
  ?attributes:(string * string) list ->
  ?status:('a -> [ `Ok | `Error | `Cancelled ]) ->
  name:string ->
  (unit -> 'a) ->
  'a
(** [with_root tracer ~name f] starts a new trace. Used by the runtime at
    [invoke] entry; hosts normally never call it directly. *)
