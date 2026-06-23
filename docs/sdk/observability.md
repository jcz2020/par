<!-- language: en -->

# Observability Reference

> Source-of-truth: `lib/core/metrics.mli`, `lib/event_bus/event_bus.mli`, `lib/core/runtime.ml`, and the FFI surface in `lib/ffi/par_ffi.h`. Covers v0.5.1. Phases B.2 (Python FFI fix for repeated `health`/`metrics`/`workflow_status` calls) and C.5 (this page) ship the documented surface.

This page documents what PAR exposes so you can watch a running runtime: counters for traffic and failures, an event bus for structured lifecycle signals, and a health snapshot for liveness probes. If you are wiring PAR into a dashboard, an SLO alert, or a `/healthz` endpoint, start here.

## What observability means in PAR

PAR splits observability into three layers, each with a different latency and a different audience.

**Metrics** are cheap, numeric, and aggregate over the lifetime of a runtime. They answer questions like "how many LLM calls have we made?" and "did any tasks fail?". Pull them on a timer for dashboards.

**The event bus** is structured, per-occurrence, and fan-out. Every task transition, every tool invocation, every workflow step publishes an event. Subscribe when you need a trace of what happened, not just a count.

**Health** is a single snapshot of "is this runtime still usable right now?" It bundles liveness, persistence reachability, and the outcome of the most recent LLM call. Hit it from a load balancer.

A fourth layer, logging, lives in the [Logging middleware](middleware.md#logging) rather than a dedicated module. It writes human-readable lines for every LLM and tool boundary. Use it for local debugging; use metrics and events for production signal.

## Metrics

The `Metrics` module is a small counter store. Each runtime owns one. The Engine bumps these counters as it runs, and you read them through `Runtime.metrics_snapshot`.

### The counters type

```ocaml
type counters

val Metrics.empty : unit -> counters
```

`counters` is opaque. You do not construct fields by hand. The runtime allocates one internally at `Runtime.create` and threads it through the Engine. The only operations on a `counters` value are the six incrementers and the snapshot.

### Incrementers

These are called from inside the Engine. You will not normally invoke them yourself unless you are extending the runtime, but knowing which one fires when helps you read the snapshot.

```ocaml
val Metrics.incr_llm : counters -> unit
val Metrics.incr_task_completed : counters -> unit
val Metrics.incr_task_failed : counters -> unit
val Metrics.incr_tool_invocations : counters -> unit
val Metrics.incr_events_published : counters -> unit
val Metrics.incr_events_dropped : counters -> unit
```

`incr_llm` fires on every LLM round trip, success or failure. `incr_task_completed` and `incr_task_failed` fire on terminal task transitions. `incr_tool_invocations` counts every handler call. The two event counters come from the event bus: `incr_events_published` for a successful dispatch, `incr_events_dropped` when an event hits the dead letter queue or overflow.

### Snapshot

```ocaml
val Metrics.snapshot : counters -> (string * int) list
```

`snapshot` returns the six counters as a stable list of `(key, value)` pairs. The keys are Prometheus-style `*_total` names so they line up with what a metrics scraper expects.

| Key | When it increments |
|-----|-------------------|
| `llm_requests_total` | Every LLM provider round trip |
| `task_completed_total` | Task reaches `Completed` |
| `task_failed_total` | Task reaches `Failed` |
| `tool_invocations_total` | Any registered tool handler is called |
| `events_published_total` | Event bus dispatches an event to subscribers |
| `events_dropped_total` | Event lands in the DLQ or is dropped on overflow |

The runtime exposes the snapshot without forcing you to touch the `counters` value directly:

```ocaml
val Runtime.metrics_snapshot : runtime -> (string * int) list
```

### What is not here

PAR's metrics surface is counters only. There are no gauges (no "current queue depth") and no histograms (no "LLM latency p99"). Latency and concurrency are observable today through the event bus: `Task_completed` carries `duration_ms`, `Llm_response_received` carries token `usage`, and so on. If your SLO needs percentiles, subscribe and compute them yourself. A richer metrics module is on the roadmap but not scheduled for v0.5.x.

## Event bus

The event bus is a publish/subscribe channel that every part of the runtime writes to. Subscribers get each event exactly once, wrapped in an envelope that carries metadata and retry state. Failed deliveries move to a dead letter queue instead of disappearing.

### Creating and subscribing

```ocaml
type t
type subscription = string

val Event_bus.create : Types.event_bus_config -> t

val Event_bus.subscribe :
  t -> (Types.event_envelope -> unit) -> subscription

val Event_bus.unsubscribe : t -> subscription -> unit

val Event_bus.start_dispatcher : t -> Eio.Switch.t -> unit
```

You usually do not call `create` yourself. The runtime builds the bus from `runtime_config.event_bus` and owns it internally for the lifetime of the runtime. What you call is `subscribe`, which returns an opaque `subscription` id. Keep it if you want to detach later; drop it if the subscriber should live as long as the runtime. If you need a bus outside a runtime (for tests, or for an embedded setup where you publish your own events), `Event_bus.create` plus `Event_bus.start_dispatcher` on a switch you control is the path.

`start_dispatcher` spawns the fiber that drains the bus. The runtime calls it during `Runtime.create`. If you build a bus outside the runtime, you must start the dispatcher yourself on a switch you control.

A subscriber is a single-argument callback that takes an `event_envelope`. Exceptions raised inside a subscriber are caught by the dispatcher and counted against that delivery's retry budget.

### Event envelope

Every event is wrapped before delivery.

```ocaml
type event_envelope = {
  id : string;
  metadata : event_metadata;
  payload : event;
  idempotency_key : string;
  delivery_attempt : int;
}
```

`id` is unique per published event. `payload` is the typed event itself (see the next section). `delivery_attempt` starts at 1 and climbs on each retry. `idempotency_key` lets a downstream subscriber dedupe if it is replaying from the DLQ. Match on `payload` for business logic, on `metadata` for tracing.

### Event types

The `event` variant is large because the bus covers the whole runtime lifecycle. The table groups the constructors by area. Field names are shortened here; see the `Types.event` definition for the full record shapes.

| Group | Constructors | Notable fields |
|-------|-------------|----------------|
| Task lifecycle | `Task_created`, `Task_started`, `Task_completed`, `Task_failed`, `Task_cancelled`, `Task_suspended`, `Task_resumed` | `task_id`, `duration_ms` (completed), `error` (failed), `reason` (cancelled) |
| LLM | `Llm_request_sent`, `Llm_response_received` | `model`, `usage` |
| Tools | `Tool_invoked`, `Tool_completed`, `Tool_failed`, `Tool_progress` | `tool_name`, `duration_ms`, `result_preview` |
| Bash tool | `Bash_invoked`, `Bash_completed` | `argv`, `cwd`, `exit_code`, `risk` |
| Workflows | `Workflow_started`, `Workflow_step_completed`, `Workflow_completed`, `Workflow_failed` | `workflow_run_id`, `step_id` |
| Approval | `Approval_requested`, `Approval_granted`, `Approval_timeout` | `prompt`, `allowed_roles`, `approver` |
| Shutdown | `Shutdown_initiated`, `Shutdown_completed` | `exit_code` |
| MCP | `Mcp_server_started`, `Mcp_server_failed`, `Mcp_server_stopped`, `Mcp_tool_invoked`, `Mcp_tool_completed`, `Mcp_resource_read`, `Mcp_prompt_rendered` | `server_id`, `tool_name`, `uri` |
| Other | `Agent_handoff`, `Structured_output_completed` | `from_agent`/`to_agent`, `schema_valid` |

If you only care about one slice, filter on the constructor inside your callback. There is no built-in topic filter. A common pattern is a small helper that pattern-matches and ignores everything else.

### Dead letter queue

When a subscriber throws, or when delivery exceeds the configured attempt budget, the envelope moves to the dead letter queue instead of being silently dropped.

```ocaml
val Event_bus.get_dead_letters : t -> Types.dead_letter_entry list
val Event_bus.dlq_entries : t -> Types.event list
val Event_bus.push_to_dlq :
  t -> Types.event_envelope -> string -> Types.error_category -> unit
```

A `dead_letter_entry` carries the original envelope, the error string, the typed `failure_reason`, the timestamp, and the attempt count at which it gave up. `dlq_entries` is a convenience that returns just the payloads. Read these from a monitoring hook if you want to alert on poison messages.

The DLQ is gated by `event_bus_config.dlq_enabled` and capped by `dlq_max_size`. When the queue is full, new entries push old ones out.

### Bus configuration

```ocaml
type event_bus_config = {
  buffer_capacity : int;
  delivery : event_delivery_config;
  dlq_enabled : bool;
  dlq_max_size : int;
  critical_event_types : string list;
}
```

`buffer_capacity` bounds the in-memory channel between publishers and the dispatcher. When full, publishers block, which applies backpressure to the Engine. `delivery` tunes retry behavior: `max_delivery_attempts`, `initial_retry_delay`, `retry_backoff`, and `delivery_timeout`. `critical_event_types` is a list of constructor names that bypass the buffer and dispatch synchronously; use it for shutdown signals that must not wait behind a backlog.

The runtime ships a sensible default:

```ocaml
Runtime.default_event_bus_config
(* buffer_capacity = 10000, DLQ enabled, exponential backoff *)
```

## Python FFI surface

PAR's Python binding exposes health, metrics, and workflow status as plain dict-returning methods. The C entrypoints live in `lib/ffi/par_ffi.h`; the OCaml implementations are in `lib/ffi/par_capi.ml`. Phase B.2 fixed a callback-handle bug that previously broke repeated calls to these methods from the same `Runtime`; the fix is verified by `bindings/python/tests/test_runtime.py::TestCallbackHandleSurvival`.

### `rt.health()`

```python
def health(self) -> dict: ...
```

Returns a dict shaped like:

```python
{
    "status": "ok",
    "runtime_alive": True,
    "persistence_ok": True,
    "last_llm_call_at": 1718230000.123,  # float or None
    "last_llm_call_status": "Success",   # see below
}
```

`runtime_alive` is false once shutdown has been requested. `persistence_ok` probes the configured backend with a trivial read. `last_llm_call_status` is one of `Success`, `Never_called`, `Error.Internal`, `Error.Timeout`, `Error.Invalid_input`, `Error.External_failure`, `Error.Rate_limited`, `Error.Permission_denied`, `Error.Embedding_unsupported`. Map `runtime_alive and persistence_ok` to a 200 and anything else to a 503 for a Kubernetes-style liveness probe.

### `rt.metrics()`

```python
def metrics(self) -> dict: ...
```

The binding unpacks the snapshot for you, so the return value is the metrics dict directly rather than a wrapper. Keys match the OCaml snapshot names.

```python
{
    "llm_requests_total": 42,
    "task_completed_total": 38,
    "task_failed_total": 1,
    "tool_invocations_total": 17,
    "events_published_total": 412,
    "events_dropped_total": 0,
}
```

Absent keys are zero. Poll on whatever cadence your scraper expects; the call is cheap and does not block the Engine.

### `rt.workflow_status(run_id)`

```python
def workflow_status(self, run_id: str) -> dict: ...
```

Returns `{"run_id": run_id, "status": "unknown"}` for any run id in v0.5.1. The workflow status lookup is stubbed: the OCaml side returns the literal `"unknown"` status string for every call. This is an acknowledged gap. The method exists so calling code can be written against the final shape now and will start receiving real statuses once the workflow state store is wired through. Treat any non-`"unknown"` value as a future-compat bonus.

### `par_event_subscribe`

The C symbol `par_event_subscribe` is declared in `lib/ffi/par_ffi.h` and registered on the OCaml side, but the implementation is a stub that returns `-1`. Event subscription from Python is not yet available. If you need event-level signal from Python today, poll `rt.metrics()` and diff `events_dropped_total`. Real event streaming from Python is tracked as future work.

## Worked examples

Two end-to-end patterns: one OCaml, one Python. Both are written to be pasted into a test or a small script.

### OCaml: subscribe to tool completions

This snippet builds a standalone bus, starts its dispatcher on a switch, subscribes a callback that prints a line for every `Tool_completed`, and returns the subscription id. The `match` ignores every other constructor so the callback stays quiet for LLM and workflow traffic. A runtime you create through `Runtime.create` owns its own bus internally; you would subscribe to that bus the same way, by obtaining the `Event_bus.t` from wherever your code holds runtime internals.

```ocaml
open Par

let watch_tools ~switch =
  let bus = Event_bus.create Runtime.default_event_bus_config in
  Event_bus.start_dispatcher bus switch;
  let sub =
    Event_bus.subscribe bus (fun envelope ->
      match envelope.Types.payload with
      | Types.Tool_completed { tool_name; duration_ms; _ } ->
        Printf.printf "[tool] %s in %.0fms\n" tool_name duration_ms
      | _ -> ())
  in
  sub
```

Pass `sub` to `Event_bus.unsubscribe bus sub` when the watcher should stop. If you want failures too, add a `Tool_failed` arm. If you want a full trace, log every arm.

### Python: poll health and metrics

A loop that hits `health()` and `metrics()` every few seconds and prints a one-line summary. Suitable for a sidecar that ships signal to your existing dashboard.

```python
import time
from par_runtime import Runtime

with Runtime(config_json) as rt:
    while True:
        h = rt.health()
        m = rt.metrics()
        ts = time.strftime("%H:%M:%S")
        print(
            f"{ts} alive={h['runtime_alive']} "
            f"persist={h['persistence_ok']} "
            f"last_llm={h['last_llm_call_status']} "
            f"llm_total={m['llm_requests_total']} "
            f"tasks_done={m['task_completed_total']} "
            f"tasks_failed={m['task_failed_total']} "
            f"events_dropped={m['events_dropped_total']}"
        )
        time.sleep(5)
```

The `events_dropped` counter is the one to alert on. Anything above zero means a subscriber is failing or the bus is overflowing, and either case warrants investigation. `tasks_failed` climbing without a corresponding `tasks_completed` climb usually points at a tool or provider regression.

## Limitations

- **Counters only.** No gauges, no histograms. Derive latency from `duration_ms` fields on events if you need it.
- **No Prometheus exposition.** PAR does not serve `/metrics`. Pipe the dict from `rt.metrics()` into your own exporter.
- **No distributed tracing spans.** Events carry `task_id` and `workflow_run_id` for correlation, but there is no OpenTelemetry exporter. Hook the event bus if you want to emit spans.
- **`par_event_subscribe` is a stub.** Python callers cannot yet receive events push-style. Poll metrics in the meantime.
- **`workflow_status` always returns `"unknown"`.** The method shape is stable; the implementation is not.
- **Single-process scope.** Metrics and the event bus live in the runtime that created them. Two `Runtime` instances in one process do not share counters. For multi-process aggregation, scrape each runtime and merge externally.

## See also

- [Agent API](agent.md) - `agent_config`, runtime creation, the surfaces a runtime exposes
- [Middleware API](middleware.md) - the Logging middleware that writes human-readable lines at every boundary
- [Streaming API](streaming.md) - chunked output, which is intentionally separate from the event bus
- [Architecture](../explanation/architecture.md) - how the Engine, event bus, and persistence fit together
