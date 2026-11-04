<!-- language: en -->

# Persistence and Durability

> **Note (v0.6.7):** References to `par ask` in this article are historical (the CLI was removed). The SQLite persistence layer is unchanged and is the recommended embedded store — see [SDK overview](https://github.com/jcz2020/par/blob/main/sdk/overview.md) for current usage.

PAR can run with no persistence at all, or with an embedded SQLite database. This document explains *why* two tiers exist, *how* they differ in practice, and what happens to your events between the moment the runtime publishes them and the moment they land on disk. It is an explanation article, not a config reference. For the config field names, read `lib/core/types.ml` and the SDK reference under `docs/sdk/`. Here we trace the write path, unpack the schema, and lay out when to reach for each tier.

## What persistence is for in PAR

An agent runtime generates events. Every tool invocation, every task state change, every workflow checkpoint, every bash command and its risk classification is emitted as a `Par.Types.event`. These events serve three purposes: audit (what did the agent do and when), debug (why did it take that path), and recovery (can we resume this workflow after a crash). Without persistence, all three are gone the instant the process exits.

PAR treats persistence as an *eventually-consistent audit log*, not as a transactional state store. The agent loop itself does not block on persistence. When `Runtime.invoke` emits a `Tool_invoked` event, that event goes to the event bus, and from there to a batched writer, and from there to SQLite, all asynchronously. If the write fails, the runtime logs it and keeps running. The agent's correctness does not depend on the audit log being durable, only on the LLM responses and tool results being correct in memory. This separation is what lets PAR stay fast under load while still giving you an audit trail after the fact.

The exception is checkpoints. Workflow state, stored in the `workflow_states` table, is written after each step of a `Sequential` chain, together with the variables that step bound, so an interrupted run can resume where it stopped. Durable invoke checkpoints (`invoke_checkpoints`) are written synchronously on the invoke fiber, because a checkpoint that might still be in a buffer when the process dies is not a checkpoint. Workflow checkpoints are always on; invoke checkpoints are opt-in, because a long tool loop pays one conversation-sized write per batch. The rest of the audit log stays asynchronous.

## Recovering an interrupted workflow

A run whose process died is left in the store as `running`. `Runtime.create` loads those rows, puts them back in the in-memory table and emits `Workflow_orphaned` once per row. Nothing resumes automatically: re-running a step that already had a side effect is a decision for the caller, not something a library should do on startup.

`Runtime.recover_workflow rt run_id` re-enters at the checkpoint. Steps before it do not run again; steps after it do. The semantics are **at-least-once**: if the process died *during* a step, the checkpoint still points at the previous one, so that step runs again. Make steps that call the outside world idempotent, or check the effect before repeating it.

Control-flow nodes are atomic for recovery. `Parallel`, `Map_reduce` and `Sub_workflow` do not checkpoint their children, so a crash inside one leaves the checkpoint before the node and recovery re-runs the whole node. `Conditional` resumes into the branch it took, provided that branch is a `Sequential`. A checkpoint whose `schema_version` is newer than the runtime understands is refused rather than guessed at.

Sub-workflows are not independently recoverable yet: a crashed child leaves only its parent's checkpoint, so recovery re-runs the whole `Sub_workflow` step.

## Recovering an interrupted invoke

The agent loop has its own crash story, and it is opt-in. `Runtime.invoke ~durable:true` (or naming the run with `~invoke_id`) writes a checkpoint after iteration zero and after every completed tool batch, into the `invoke_checkpoints` table. The row exists only while the run is in flight: every terminal outcome removes it — success, failure, an intentional cancellation, and suspension for approval — so a row that outlives the process was left by a writer that stopped without finishing.

Name the run yourself when you need to recover it: `~invoke_id:"order-42"`. A minted id is only returned in `invoke_result.invoke_id`, which a crashed process never returns. After a restart, `Runtime.create` rehydrates leftover rows and emits `Invoke_orphaned` once per row; `Runtime.list_orphaned_invokes` lists them as `(invoke_id, agent_id)`. The event is published while `create` runs, so a subscriber must be attached before the runtime is created — or call `list_orphaned_invokes` after it. `Runtime.recover_invoke rt ~invoke_id` re-enters the loop with the checkpointed conversation, iteration count and elapsed execution budget.

The semantics match workflows:

- **at-least-once**: the iteration that was in progress runs again. The checkpoint is taken after a completed batch, so the assistant turn of the interrupted iteration was never persisted — the model is asked again and may choose a different tool call. Completed batches do not re-run.
- **explicit**: nothing resumes automatically, and only ids rehydrated at startup are eligible — a run still in flight in this process is refused, because recovering it would execute it twice. Re-using an orphan's id for a fresh invoke is refused too: recovery is explicit, and a new run must choose a new id.
- **atomic batches**: a parallel tool batch checkpoints once, after all its results are folded into the conversation, so a crash inside the batch re-runs that iteration as a whole.
- **schema-checked**: a checkpoint from a newer `schema_version` is refused rather than guessed at. If the newer shape cannot even be decoded, the row is preserved at startup and the refusal names the version — an older runtime must not destroy a newer writer's state.

The checkpoint records the agent that is actually running. After a handoff, that is the target agent, so recovery re-enters with the target's tools rather than the ones the caller named.

Three honest limits. The system prompt is replayed from the checkpoint rather than recomputed, and the static tool set is replayed as recorded (skill-driven filters included) — a skill or appendix change between the crash and the recovery does not take effect. Dynamic promotions from `tool_search` are not replayed: the recovered run starts from the checkpointed static set. A run suspended for approval is not recoverable this way: the `approvals` row owns that state, `resume_approval` is its resume path, and that row carries an expiry (300 seconds by default), after which the run cannot be resumed. And checkpoint writes are best-effort: a write failure is logged and published as `Invoke_checkpoint_failed`, but the run continues, so the step that could not be persisted is simply not recoverable.

Checkpoints are written synchronously on the invoke fiber, not through the batched event writer. That is deliberate — a checkpoint that might still be in a buffer when the process dies is not a checkpoint — and it is why durability is opt-in: a long tool loop pays one conversation-sized write per batch. It also means `Runtime.close` should be called when the runtime is idle: it closes the persistence handle, and a checkpoint write or delete that lands after that fails (and is reported as above).

Durability covers `invoke` and `invoke_content` (and `invoke_async`, which forwards). `invoke_structured`, `invoke_generate`, `invoke_parallel` and workflow `Agent_call` steps have their own paths or none; a durable checkpoint is created only by the entry points above. If a caller set `save=false`, a durable run still writes its conversation to the checkpoint table — durability is a separate persistence decision from conversation saving.

## Two persistence tiers

PAR ships two persistence tiers, controlled by the `persistence` field in `runtime_config`:

- `` `Sqlite `` is the only persistent backend and the default. A single file (or `:memory:` for tests). Zero external dependencies: the `sqlite3` library is a hard dependency of the `par` package. You get WAL mode, the full schema, retention pruning, the works. This is what `par ask` and the Python quickstart use. The public config type is `[ `Sqlite of string ]`, where the string is the database path. There is no other config variant.
- `` `Noop `` is the in-memory backend for tests. It discards everything. There is no event bus, no writer fiber, no I/O. Tests that only care about agent behavior run faster and do not leave files behind. Noop is available programmatically as a variant of the internal persistence type, but it is not exposed as a config option: the public config only carries the SQLite path. If you want the in-memory behavior from the config surface, point SQLite at `:memory:`.

The `` `Noop `` tier is also a subtle architectural statement. When persistence is noop, the runtime skips wiring up the event bus entirely. There is no dead event bus feeding a dead writer. The `Persistence_writer` and `Event_bus` instances are `None` on the runtime record. This keeps the test path lean and makes it impossible to accidentally leave a background drain fiber running in a unit test.

## The schema: four tables

SQLite uses the schema defined in `lib/persistence/sqlite_persistence.ml`. Four tables:

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

CREATE TABLE invoke_checkpoints (
  invoke_id  TEXT PRIMARY KEY,
  state_json TEXT NOT NULL,
  updated_at REAL NOT NULL
);
```

`events` is the append-only audit log. Every published event is JSON-serialized into `payload`, tagged with `task_id` and `timestamp`, and deduplicated by `idempotency_key`. The `session_id` column lets you filter events by conversation, and `actions_json` carries structured side-effect data (the command vector for a bash invocation, for example). Two indexes, `idx_events_task_id` and `idx_events_session_id`, keep the common query paths fast.

`task_states` tracks the lifecycle of a task: queued, running, completed, failed. `workflow_states` holds workflow checkpoints so a multi-step workflow can resume after a crash. `invoke_checkpoints` holds one in-flight conversation snapshot per durable invoke. All of them use `updated_at` as a monotonic clock for ordering.

The first three tables are borrowed from LangGraph's three-table model, which is itself an abstraction over what checkpointing systems need: a log of what happened (`events`), a snapshot of transient state (`task_states`), and a snapshot of long-running state (`workflow_states`). PAR deliberately did not invent a fourth *shape*. `invoke_checkpoints` is the same "snapshot of transient state" idea, but keyed by an invoke id: an `invoke` is not a `task_state` row, and putting a conversation-sized payload on the scheduler's state record would charge every task query for durability data it does not use. The table exists so the two concerns stay separate rather than sharing a row with a union of columns.

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
save_fn(batch)  ◄── persistence.save_events_fn  ─►  SQLite
```

First hop: `publish_event_fn` is the event bus's publish function. The bus is an in-memory fan-out with a dead-letter queue. Every subscriber gets every event. One of those subscribers is a closure that calls `Persistence_writer.push`.

Second hop: the writer buffers events in a mutex-protected list. The capacity is 1000 events. If the buffer is full when a new event arrives, the overflow function fires, routing the event to the bus's DLQ instead of dropping it silently. The buffer is a list, prepended in reverse, so `push` is O(1) and the batch is reversed on flush.

Third hop: a drain fiber, forked as a daemon at runtime creation via `Eio.Fiber.fork_daemon`, loops forever. It yields twice (giving other fibers a turn), grabs the entire pending buffer, and calls `save_fn` on the batch. The flush interval is 50 milliseconds, set by `flush_interval: 0.05` in `Persistence_writer.create`. That means under steady load, events land on disk within 50 ms of being published, in batches rather than one INSERT per event.

Two properties matter here. First, the agent loop never blocks on persistence. `publish_event_fn` returns immediately; the actual I/O happens on a separate fiber. Second, shutdown is clean. `Runtime.close` sets the writer's `running` flag to false and calls `flush_sync`, which grabs any remaining events and writes them before the runtime tears down. The drain fiber, on noticing `running` is false, exits with `` `Stop_daemon ``. Because it is a daemon fiber, its exit does not block switch teardown. If it is mid-flush when cancellation arrives, it catches `Eio.Cancel.Cancelled`, does one final synchronous flush, and then stops. No events are lost on a graceful shutdown.

## WAL mode and concurrency

SQLite in WAL (Write-Ahead Logging) mode lets readers and a single writer proceed concurrently without blocking each other. PAR enables WAL because the typical workload is one writer (the batched drain fiber) and many readers (history queries, resume lookups, the `par history` CLI command). Without WAL, every read would take a shared lock and stall the writer.

WAL has one operational consequence: the database directory must be writable, because SQLite creates `-wal` and `-shm` sidecar files next to the main `.db` file. If you point PAR at a read-only directory, WAL setup fails and you get an error at `Runtime.create`. For ephemeral or test runs, `:memory:` sidesteps this entirely.

One constraint follows from WAL plus SQLite's file locking: only one process should be writing the file at a time. A single PAR runtime owning the file is the supported model. Two runtimes pointed at the same `.db` file from separate processes will contend on the lock and you will see `SQLITE_BUSY` errors under load.

## Retention: the 7-day default

Left unchecked, the events table grows forever. PAR prunes it. The default retention TTL is 7 days (`default_retention_ttl = 7. *. 24. *. 60. *. 60.` in `lib/persistence/sqlite_persistence.ml`). When a SQLite backend is opened, it runs a prune that deletes every event older than the TTL. You can override the TTL per-backend at create time.

Pruning is timestamp-based, on the `events` table only. `task_states`, `workflow_states` and `invoke_checkpoints` are not pruned automatically, because their rows represent resumable state rather than historical noise. If you want to clean those up, you do it yourself with a DELETE. The assumption is that a long-running service cares about audit history aging out but not about losing a workflow checkpoint it might still resume.

## When to pick which tier

| Scenario | Tier | Why |
|----------|------|-----|
| Local development, single-instance production | `` `Sqlite `` | Zero setup, file on disk, WAL handles the read/write mix. A single PAR runtime with SQLite handles hundreds of events per second through the batched writer; the bottleneck is usually the LLM provider, not the database. Back up the `.db` file. |
| Tests, CI, anything that does not need an audit trail on disk | `` `Noop `` | No I/O, no leftover files, fastest. |

The honest limitation worth stating plainly: SQLite is a single-file, single-writer database. Its file locking does not survive multiple processes writing to the same file across containers. If you need more than one PAR process hitting the same data at once, the options today are to shard at the application level (one runtime, one database file, partitioned by tenant or session) or to run one writer and let other instances read replicas of the file. The cross-instance, shared-state story is on the roadmap as a future remote tier rather than something SQLite gives you now. See "What is coming".

A single PAR runtime with SQLite is enough for a great deal of real load. The reason to look past it is horizontal scaling with shared state, and that is exactly the gap the dual-layer work is meant to close.

## What is coming

The current model is single-layer: events go to one backend, full stop. A future version plans a dual-layer model: a fast local tier (SQLite, low latency, short retention) plus a remote tier (a future persistence backend or object storage, durable, long retention). The local tier would absorb burst traffic and forward to the remote tier asynchronously. This is the standard hot/cold log architecture. Until it lands, pick your tier based on the matrix above and accept that one tier is what you have.

The dual-layer design is on the roadmap (tracked as bd issue `PAR-4dt`, targeted at v0.6+) because the single-tier model forces a choice between latency (SQLite, local, fast) and durability across instances (a remote tier that survives multiple writers). A service that wants both today has to run SQLite locally per instance and forgo shared cross-instance queries, or shard its workload. The dual-layer path would let a service keep SQLite locally for sub-millisecond audit writes and replicate to a remote tier for cross-instance queries. That is the theory. The implementation is not here yet.

## See also

- [Architecture](architecture.md) for where persistence sits in the module structure and the event flow diagram
- [Concurrency Model](concurrency-model.md) for how the drain fiber cooperates with the runtime switch and cancellation
- [Workflow API](https://github.com/jcz2020/par/blob/main/sdk/workflow.md) for how workflow checkpoints interact with `workflow_states`
- [SDK overview](https://github.com/jcz2020/par/blob/main/sdk/overview.md) for the event-bus subscribe API (the read-side companion to this write path)
