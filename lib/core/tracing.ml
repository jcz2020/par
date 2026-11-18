(* Trace-context carrier and span lifecycle.

   The runtime *produces* spans; export belongs to the host. [noop] is the
   default, so tracing costs one physical-equality check per boundary. A host
   that wants OpenTelemetry injects a tracer at [Runtime.create ?tracer] and
   adapts [on_start]/[on_end] to its SDK.

   Parent/child links live in an [Eio.Fiber.key]: fibers forked by the engine
   inherit the binding, so parallel tool calls attach to the span that started
   them without threading a context record through every signature. *)

type span_kind = [ `Internal | `Client | `Server ]

type span = {
  trace_id : string;
  span_id : string;
  parent_span_id : string option;
  name : string;
  kind : span_kind;
  started_at : float;
  attributes : (string * string) list;
}

type tracer = {
  on_start : span -> unit;
  on_end : span -> status:string -> unit;
}

let noop = {
  on_start = (fun _ -> ());
  on_end = (fun _ ~status:_ -> ());
}

let is_noop t = t == noop

type context = { tracer : tracer; span : span }

let context_key : context Eio.Fiber.key = Eio.Fiber.create_key ()

let now () = Unix.gettimeofday ()

(* A fresh seed per id. The value only needs to be unique, not secret; the
   timestamp and pid entropy in [make_self_init] keep cross-process collisions
   out of practical reach. *)
let random_hex bytes =
  let st = Random.State.make_self_init () in
  let digits = "0123456789abcdef" in
  String.init (bytes * 2) (fun _ ->
    digits.[Random.State.int st 16])

let make_span ~trace_id ?parent_span_id ~name ~kind ~attributes () =
  { trace_id;
    span_id = random_hex 8;
    parent_span_id;
    name;
    kind;
    started_at = now ();
    attributes;
  }

let span_to_yojson (s : span) : Yojson.Safe.t =
  `Assoc [
    ("trace_id", `String s.trace_id);
    ("span_id", `String s.span_id);
    ("parent_span_id",
     match s.parent_span_id with Some id -> `String id | None -> `Null);
    ("name", `String s.name);
    ("kind",
     `String (match s.kind with
       | `Internal -> "internal"
       | `Client -> "client"
       | `Server -> "server"));
    ("started_at", `Float s.started_at);
    ("attributes", `Assoc (List.map (fun (k, v) -> (k, `String v)) s.attributes));
  ]

let current () = Eio.Fiber.get context_key

(* S3 consumes these to inject W3C [traceparent] on outbound HTTP. *)
let current_trace_id () = Option.map (fun c -> c.span.trace_id) (current ())

let current_span_id () = Option.map (fun c -> c.span.span_id) (current ())

(* W3C Trace Context, version 00. Only the fields this runtime can honour
   are exposed: the trace id and the remote parent span id. A malformed header
   is ignored rather than fatal (the spec requires propagation to be
   best-effort). *)
let traceparent_header ~trace_id ~span_id =
  Printf.sprintf "00-%s-%s-01" trace_id span_id

let outgoing_headers () =
  match current () with
  | Some { span; _ } -> [("traceparent", traceparent_header ~trace_id:span.trace_id ~span_id:span.span_id)]
  | None -> []

let parse_traceparent value =
  match String.split_on_char '-' value with
  | ["00"; trace_id; parent_id; _flags]
    when String.length trace_id = 32 && String.length parent_id = 16
         && String.for_all (fun c ->
              (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) trace_id
         && String.for_all (fun c ->
              (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) parent_id
         && trace_id <> String.make 32 '0'
         && parent_id <> String.make 16 '0' ->
    Some (trace_id, parent_id)
  | _ -> None

let status_of_outcome = function
  | `Ok -> "ok"
  | `Error -> "error"
  | `Cancelled -> "cancelled"

let with_span_in _parent ?(kind : span_kind = `Internal)
    ?(attributes = []) ?(status = fun _ -> `Ok) ~name f =
  match current () with
  | None -> f ()
  | Some parent when is_noop parent.tracer -> f ()
  | Some parent ->
    let span =
      make_span ~trace_id:parent.span.trace_id
        ~parent_span_id:parent.span.span_id
        ~name ~kind ~attributes ()
    in
    parent.tracer.on_start span;
    let finish outcome = parent.tracer.on_end span ~status:(status_of_outcome outcome) in
    (try
       let value = Eio.Fiber.with_binding context_key { parent with span } f in
       finish (status value);
       value
     with
     | Eio.Cancel.Cancelled _ as exn -> finish `Cancelled; raise exn
     | exn -> finish `Error; raise exn)

let with_span ?kind ?attributes ?status ~name f =
  match current () with
  | None -> f ()
  | Some ctx ->
    with_span_in ctx ?kind ?attributes ?status ~name f

let with_root tracer ?(kind : span_kind = `Internal) ?(attributes = [])
    ?(status = fun _ -> `Ok) ~name f =
  if is_noop tracer then f ()
  else begin
    let span =
      make_span ~trace_id:(random_hex 16) ~name ~kind ~attributes ()
    in
    tracer.on_start span;
    let finish outcome = tracer.on_end span ~status:(status_of_outcome outcome) in
    (try
       let value =
         Eio.Fiber.with_binding context_key { tracer; span } f
       in
       finish (status value);
       value
     with
     | Eio.Cancel.Cancelled _ as exn -> finish `Cancelled; raise exn
     | exn -> finish `Error; raise exn)
  end
