<!-- language: en -->

# Persistence and Durability

PAR can run with no persistence at all, with an embedded SQLite database, or with PostgreSQL. This document explains *why* three backends exist, *how* they differ in practice, and what happens to your events between the moment the runtime publishes them and the moment they land on disk. It is an explanation article, not a config reference. For the config field names, read `lib/core/types.ml` and the SDK reference under `docs/sdk/`. Here we trace the write path, unpack the schema, and lay out the decision matrix for picking a backend.

## What persistence is for in PAR

An agent runtime generates events. Every tool invocation, every task state change, every workflow checkpoint, every bash command and its risk classification is emitted as a `Par.Types.event`. These events serve three purposes: audit (what did the agent do and when), debug (why did it take that path), and recovery (can we resume this workflow after a crash). Without persistence, all three are gone the instant the process exits.

PAR treats persistence as an *eventually-consistent audit log*, not as a transactional state store. The agent loop itself does not block on persistence. When `Runtime.invoke` emits a `Tool_invoked` event, that event goes to the event bus, and from there to a batched writer, and from there to SQLite or PostgreSQL, all asynchronously. If the write fails, the runtime logs it and keeps running. The agent's correctness does not depend on the audit log being durable, only on the LLM responses and tool results being correct in memory. This separation is what lets PAR stay fast under load while still giving you an audit trail after the fact.

The exception is workflow checkpoints. Workflow state, stored in the `workflow_states` table, is written when a workflow step completes so a crashed run can be resumed. That path is more latency-sensitive, but it still goes through the same batched writer. If you need strict durability for workflow resume, you accept the batch latency.

## Three backends, three audiences

PAR ships three persistence backends, selected by the `persistence` field in `runtime_config`:

- `` `Sqlite `` is the default. A single file (or `:memory:` for tests). Zero external dependencies. The `sqlite3` library is a hard dependency of the `par` package. You get WAL mode, the full schema, retention pruning, the works. This is what `par ask` and the Python quickstart use.
- `` `Postgresql `` is the production backend. It lives in a separate opam package, `par_postgres`, because it pulls in `pgwire` and TLS libraries that not every user wants. You point it at a Postgres instance and you get the same schema, but multi-process safe: several PAR runtimes can share one database. This matters for horizontally-scaled services.
- `` `Noop `` is the test backend. It discards everything. There is no event bus, no writer fiber, no I/O. Tests that only care about agent behavior run faster and do not leave files behind.

The `` `Noop `` backend is also a subtle architectural statement. When persistence is noop, the runtime skips wiring up the event bus entirely. There is no dead event bus feeding a dead writer. The `Persistence_writer` and `Event_bus` instances are `None` on the runtime record. This keeps the test path lean and makes it impossible to accidentally leave a background drain fiber running in a unit test.

## The schema: three tables

All real backends use the same schema, defined in `lib/persistence/sqlite_persistence.ml`. Three tables:

```sql
CREATE TABLE events (
  id              TEXT PRIMARY KEY,
  task_id         TEXT NOT NULL,
  payload         TEXT NOT NULL,
  timestamp       REAL NOT NULL,
  idempotency_key TEXT UNIQUE NOT NULL,
  session_id      TEXT NOT NULL DEFAULT '',
  actions_json    TEXT
);

CREATE TABLE task_states (
  id         TEXT PRIMARY KEY,
  state      TEXT NOT NULL,
  updated_at REAL NOT NULL
);

CREATE TABLE workflow_states (
  id          TEXT PRIMARY KEY,
  workflow_id TEXT NOT NULL,
  status      TEXT NOT NULL,
  checkpoint  TEXT,
  updated_at  REAL NOT NULL
);
```

`events` is the append-only audit log. Every published event is JSON-serialized into `payload`, tagged with `task_id` and `timestamp`, and deduplicated by `idempotency_key`. The `session_id` column lets you filter events by conversation, and `actions_json` carries structured side-effect data (the command vector for a bash invocation, for example). Two indexes, `idx_events_task_id` and `idx_events_session_id`, keep the common query paths fast.

`task_states` tracks the lifecycle of a task: queued, running, completed, failed. `workflow_states` holds workflow checkpoints so a multi-step workflow can resume after a crash. Both use `updated_at` as a monotonic clock for ordering.

The schema is borrowed from LangGraph's three-table model, which is itself an abstraction over what checkpointing systems need: a log of what happened (`events`), a snapshot of transient state (`task_states`), and a snapshot of long-running state (`workflow_states`). PAR deliberately did not invent a fourth shape. The three-table pattern is battle-tested across agent frameworks, and reusing it means the operational playbook (how you query for a session's history, how you prune, how you resume) transfers.

## The write path: event bus to disk

The interesting part is how an event gets from `rt.publish_event_fn` to SQLite without blocking the agent loop. The path has three hops.

```
Runtime.publish_event
   │
   ▼
Event_bus (in-memory, fan-out to subscribers)
   │   └─ subscriber: Persistence_writer.push
   │
   ▼
Persistence_writer.buffer  (capacity 1000, Mutex-protected list)
   │
   │  every 50ms, drain fiber wakes:
   ▼
grab_pending  ◄── takes whole buffer, resets to []
   │
   ▼
save_fn(batch)  ◄── persistence.save_events_fn  ─►  SQLite / Postgres
```

First hop: `publish_event_fn` is the event bus's publish function. The bus is an in-memory fan-out with a dead-letter queue. Every subscriber gets every event. One of those subscribers is a closure that calls `Persistence_writer.push`.

Second hop: the writer buffers events in a mutex-protected list. The capacity is 1000 events. If the buffer is full when a new event arrives, the overflow function fires, routing the event to the bus's DLQ instead of dropping it silently. The buffer is a list, prepended in reverse, so `push` is O(1) and the batch is reversed on flush.

Third hop: a drain fiber, forked as a daemon at runtime creation via `Eio.Fiber.fork_daemon`, loops forever. It yields twice (giving other fibers a turn), grabs the entire pending buffer, and calls `save_fn` on the batch. The flush interval is 50 milliseconds, set by `flush_interval: 0.05` in `Persistence_writer.create`. That means under steady load, events land on disk within 50 ms of being published, in batches rather than one INSERT per event.

Two properties matter here. First, the agent loop never blocks on persistence. `publish_event_fn` returns immediately; the actual I/O happens on a separate fiber. Second, shutdown is clean. `Runtime.close` sets the writer's `running` flag to false and calls `flush_sync`, which grabs any remaining events and writes them before the runtime tears down. The drain fiber, on noticing `running` is false, exits with `` `Stop_daemon ``. Because it is a daemon fiber, its exit does not block switch teardown. If it is mid-flush when cancellation arrives, it catches `Eio.Cancel.Cancelled`, does one final synchronous flush, and then stops. No events are lost on a graceful shutdown.

## WAL mode and concurrency

SQLite in WAL (Write-Ahead Logging) mode lets readers and a single writer proceed concurrently without blocking each other. PAR enables WAL because the typical workload is one writer (the batched drain fiber) and many readers (history queries, resume lookups, the `par history` CLI command). Without WAL, every read would take a shared lock and stall the writer.

WAL has one operational consequence: the database directory must be writable, because SQLite creates `-wal` and `-shm` sidecar files next to the main `.db` file. If you point PAR at a read-only directory, WAL setup fails and you get an error at `Runtime.create`. For ephemeral or test runs, `:memory:` sidesteps this entirely.

## Retention: the 7-day default

Left unchecked, the events table grows forever. PAR prunes it. The default retention TTL is 7 days (`default_retention_ttl = 7. *. 24. *. 60. *. 60.` in `lib/persistence/sqlite_persistence.ml`). When a SQLite backend is opened, it runs a prune that deletes every event older than the TTL. You can override the TTL per-backend at create time.

Pruning is timestamp-based, on the `events` table only. `task_states` and `workflow_states` are not pruned automatically, because their rows represent resumable state rather than historical noise. If you want to clean those up, you do it yourself with a DELETE. The assumption is that a long-running service cares about audit history aging out but not about losing a workflow checkpoint it might still resume.

## When to pick which backend

| Scenario | Backend | Why |
|----------|---------|-----|
| Local development, single process | `` `Sqlite `` | Zero setup, file on disk, WAL handles the read/write mix. |
| Tests, CI | `` `Noop `` | No I/O, no leftover files, fastest. |
| Single-instance production | `` `Sqlite `` | Still fine. WAL plus the batched writer handles moderate load. Back up the `.db` file. |
| Multi-instance production, HA | `` `Postgresql `` | SQLite's file locking does not survive multiple processes writing to the same file across containers. Postgres does. |
| Heavy audit query workload | `` `Postgresql `` | You want a real query planner, indexes you control, and concurrent readers that do not contend with the writer. |
| Regulated environment needing long retention | `` `Postgresql `` | Tune retention server-side, integrate with your existing backup pipeline. |

The upgrade trigger from SQLite to PostgreSQL is almost always one of two things: you need more than one PAR process hitting the same data, or your audit query patterns have outgrown what SQLite indexes give you. Until you hit one of those, SQLite is enough. A single PAR runtime with SQLite can handle hundreds of events per second through the batched writer; the bottleneck is usually the LLM provider, not the database.

## What is coming

The current model is single-layer: events go to one backend, full stop. PAR-4dt (deferred to v0.5.3) plans a dual-layer model: a fast local tier (SQLite, low latency, short retention) plus a remote tier (Postgres or object storage, durable, long retention). The local tier would absorb burst traffic and forward to the remote tier asynchronously. This is the standard hot/cold log architecture. Until it lands, pick your backend based on the matrix above and accept that one tier is what you have.

The dual-layer design exists on the roadmap because the single-tier model forces a choice between latency (SQLite) and durability across instances (Postgres). A service that wants both today has to run Postgres everywhere and eat the network round trip on every batch flush. The dual-layer path would let a service keep SQLite locally for sub-millisecond audit writes and replicate to Postgres for cross-instance queries. That is the theory. The implementation is not here yet.

## See also

- [Architecture](architecture.md) for where persistence sits in the module structure and the event flow diagram
- [Concurrency Model](concurrency-model.md) for how the drain fiber cooperates with the runtime switch and cancellation
- [Workflow API](../sdk/workflow.md) for how workflow checkpoints interact with `workflow_states`
- [CLI](../cli.md) for `par history`, the read-side companion to this write path
