<!-- language: en -->

**English** · [简体中文](../zh/sdk/persistence.md)

# Persistence API

PAR ships with an embedded persistence layer that stores events, task states, workflow checkpoints, and conversation history in a local SQLite database. The persistence service is optional. When configured, it gives every `Runtime.invoke` call durable storage. When omitted, the runtime works in ephemeral mode, great for quick experiments and unit tests.

## Overview

The persistence layer follows the same closure-record pattern as `llm_service` and `memory_service`. A `persistence_service` record holds function pointers, one per operation. The default backend is SQLite. A Noop backend exists for testing.

```ocaml
type persistence_service = {
  save_events_fn : ?scope:string -> event_envelope list -> (unit, error_category) result;
  load_events_fn : Task_id.t -> (event list, error_category) result;
  load_events_by_session_fn : ?scope:string -> string -> (event list, error_category) result;
  load_sessions_fn : ?scope:string -> int -> (session_summary list, error_category) result;
  save_task_state_fn : task_state -> (unit, error_category) result;
  load_task_state_fn : Task_id.t -> (task_state option, error_category) result;
  save_workflow_state_fn : Workflow_run_id.t -> workflow_status -> workflow_checkpoint option -> (unit, error_category) result;
  load_workflow_state_fn : Workflow_run_id.t -> (workflow_checkpoint option, error_category) result;
  load_all_suspended_workflows_fn : unit -> ((Workflow_run_id.t * workflow_status) list, error_category) result;
  save_workflow_def_fn : string -> Yojson.Safe.t -> (unit, error_category) result;
  load_all_workflow_defs_fn : unit -> ((string * Yojson.Safe.t) list, error_category) result;
  save_conversation_fn : ?scope:string -> string -> conversation -> (unit, error_category) result;
  load_conversation_fn : string -> (conversation option, error_category) result;
  load_most_recent_conversation_fn : ?scope:string -> unit -> ((string * conversation) option, error_category) result;
  close_fn : unit -> unit;
}
```

## Backends

### SQLite (default)

`Sqlite_persistence` is the production backend. It stores everything in a single SQLite file with WAL mode for concurrent reads. The schema is created automatically on first open, and migrations run silently to add columns that newer versions introduce.

```ocaml
val Sqlite_persistence.create :
  ?retention_ttl:float -> string -> (Sqlite_persistence.t, error_category) result
```

The optional `retention_ttl` parameter sets how long old events are kept, in seconds. The default is 7 days (604800s). On creation, events older than the TTL are pruned.

### Noop (testing)

`Noop_persistence` does nothing. Every operation returns `Ok ()` or `Ok None`. Use it when you want the runtime to compile and run without touching disk.

```ocaml
val Noop_persistence.create : string -> (Noop_persistence.t, error_category) result
```

## The `scope` dimension

Many persistence functions accept an optional `?scope:string` parameter. Scope is a generic partition key. Applications decide what it means: workspace id, user id, tenant id, deployment environment, or any other grouping dimension. The runtime does not interpret the value.

When `scope` is `None`, the operation covers all scopes. When `scope` is `Some "workspace-123"`, the operation is scoped to that partition only.

```python
# Python: scope by workspace
config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": "par.db"},
})
with Runtime(config) as rt:
    rt.set_session_id("workspace-123")
    rt.invoke(agent, "Summarize the logs")  # stored with scope="workspace-123"

    rt.set_session_id("workspace-456")
    rt.invoke(agent, "Summarize the logs")  # stored with scope="workspace-456"
```

```ocaml
(* OCaml: load events scoped to a specific workspace *)
let events = rt.persistence.load_events_by_session_fn
  ~scope:"workspace-123" session_id
in ...
```

## CRUD functions

### Events

Events are the core audit log. Every task transition, LLM call, tool invocation, and workflow step publishes an event. The persistence layer stores these durably.

| Function | Scope param | Description |
|----------|-------------|-------------|
| `save_events_fn` | `?scope:string` | Append a batch of events to the event log |
| `load_events_fn` | none | Load all events for a given task id |
| `load_events_by_session_fn` | `?scope:string` | Load all events for a session id, optionally filtered by scope |
| `load_sessions_fn` | `?scope:string` | List recent sessions with event counts, optionally filtered by scope |

The `session_summary` type returned by `load_sessions_fn`:

```ocaml
type session_summary = {
  session_id : string;
  event_count : int;
  first_event_at : float;
  last_event_at : float;
}
```

### Task state

Task state snapshots let you resume or inspect a task's progress without replaying events.

| Function | Description |
|----------|-------------|
| `save_task_state_fn` | Upsert a task_state record |
| `load_task_state_fn` | Load a task_state by task id, or `None` if not found |

### Workflow state

Workflow persistence handles checkpoints, suspended workflows, and workflow definitions.

| Function | Description |
|----------|-------------|
| `save_workflow_state_fn` | Save workflow status and optional checkpoint |
| `load_workflow_state_fn` | Load the checkpoint for a workflow run |
| `load_all_suspended_workflows_fn` | List all suspended workflows (for resume after crash) |
| `save_workflow_def_fn` | Store a workflow definition by id |
| `load_all_workflow_defs_fn` | List all stored workflow definitions |

### Conversation history

Conversations store the full message history for a session. Each save replaces the previous conversation for that session id.

| Function | Scope param | Description |
|----------|-------------|-------------|
| `save_conversation_fn` | `?scope:string` | Save a conversation for a session id |
| `load_conversation_fn` | none | Load a conversation by session id |
| `load_most_recent_conversation_fn` | `?scope:string` | Load the most recently updated conversation, optionally filtered by scope |

## Configuring persistence

### OCaml SDK

```ocaml
open Par

let config = {
  Types.persistence = `Sqlite "par.db";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
}
```

The `persistence` field accepts:

- `` `Sqlite "path/to/db" `` for a file-backed database
- `` `Sqlite ":memory:" `` for an in-memory database (tests, demos)

### Python binding

```python
from par_runtime import Runtime
import json

config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": "par.db"},
})
with Runtime(config) as rt:
    agent = rt.make_agent(id="assistant", model="openai/gpt-4o-mini")
    rt.invoke(agent, "Hello")
```

## SQLite schema

The backend creates five tables on first open:

| Table | Purpose |
|-------|---------|
| `events` | Event log with task_id, session_id, scope, payload |
| `task_states` | Task state snapshots |
| `workflow_states` | Workflow checkpoints and status |
| `conversations` | Conversation messages and metadata |
| `workflow_definitions` | Workflow definitions by id |

Indexes are created on `task_id`, `session_id`, `scope`, and `updated_at` for efficient queries. The `scope` column is added via migration if upgrading from an older version that did not have it.

## Thread safety

All SQLite operations are serialized through an `Eio.Mutex.t`. Concurrent `Runtime.invoke` calls on the same runtime share the same persistence backend safely. Writes use `Eio.Mutex.use_rw` and reads use `Eio.Mutex.use_ro`.

## Limitations

- **Single-process scope.** Two `Runtime` instances in one process can open the same SQLite file, but concurrent writes from separate processes may cause `SQLITE_BUSY`. For multi-process setups, use a single runtime per process or an external database.
- **No network backends.** The persistence layer is local SQLite only. For distributed persistence, use a shared database and wire your own `persistence_service` record.
- **No vector storage.** Event payloads are stored as JSON text. Vector-based retrieval is handled by the separate `Memory_service` module.

## See also

- [Agent API](agent.md) - `Runtime.create`, `invoke`, and the lifecycle that generates events
- [Memory API](memory.md) - cross-session knowledge storage with FTS5 search
- [Observability](observability.md) - metrics counters and event bus for monitoring persistence activity
- [Architecture](../explanation/architecture.md) - how persistence fits into the overall runtime design
