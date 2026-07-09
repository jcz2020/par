<!-- language: en -->

**English** · [简体中文](../zh/sdk/memory.md)

# Memory API

PAR provides a first-class memory abstraction for cross-session agent knowledge. Every agent that needs to remember facts across sessions previously had to implement schema + FTS5 + CRUD + retrieval from scratch. The `Memory_service` module eliminates this duplication.

## Overview

The memory module mirrors the `llm_service` closure-record pattern:

```ocaml
module type MEMORY_SERVICE = sig
  type t
  val create : string -> (t, memory_error) result
  val add : t -> memory_object -> (string, memory_errors) result
  val search : t -> ?scope:string -> string -> (memory_object list, memory_errors) result
  val update : t -> string -> memory_object -> (unit, memory_errors) result
  val delete : t -> string -> (unit, memory_errors) result
  val list_all : t -> ?scope:string -> unit -> (memory_object list, memory_errors) result
  val close : t -> unit
end
```

The runtime holds an optional `memory_service` record (closure-based, like `llm_service`):

```ocaml
type memory_service = {
  add_fn : memory_object -> (string, error_category) result;
  search_fn : ?scope:string -> string -> (memory_object list, error_category) result;
  update_fn : string -> memory_object -> (unit, error_category) result;
  delete_fn : string -> (unit, error_category) result;
  list_all_fn : ?scope:string -> unit -> (memory_object list, error_category) result;
  close_fn : unit -> unit;
  render_index_fn : ?max_entries:int -> ?scope:string -> unit -> string;
}
```

## Memory object

Each memory is a `memory_object` record:

| Field | Type | Description |
|-------|------|-------------|
| `id` | `string` | UUID, auto-generated on `add` |
| `content` | `string` | Full text content |
| `summary` | `string option` | Short summary (optional, indexed by FTS5) |
| `scope` | `string option` | Partition key (workspace_id, user_id, tenant_id — application-defined) |
| `metadata` | `(string * Yojson.Safe.t) list` | Arbitrary key-value pairs |
| `categories` | `string list` | Category tags |
| `created_at` | `float` | Unix timestamp |
| `updated_at` | `float` | Unix timestamp |
| `source` | `string` | Origin label (`"manual"`, `"agent"`, `"import"`) |

## Default backend: SQLite + FTS5

The default `Sqlite_memory` backend uses SQLite FTS5 with porter+unicode61 tokenizer for keyword search. BM25 ranking is used via `ORDER BY rank`.

### Schema

```sql
CREATE TABLE memory_entries (
    id TEXT PRIMARY KEY,
    content TEXT NOT NULL,
    summary TEXT,
    scope TEXT,
    metadata TEXT NOT NULL DEFAULT '{}',
    categories TEXT NOT NULL DEFAULT '[]',
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    last_used_at REAL,
    usage_count INTEGER NOT NULL DEFAULT 0,
    source TEXT NOT NULL DEFAULT 'manual'
);

CREATE VIRTUAL TABLE memory_entries_fts USING fts5(
    content, summary, scope,
    content='memory_entries', content_rowid='id',
    tokenize='porter unicode61'
);
```

### Lifecycle

- **ADD-only**: `update` creates a new row with a new UUID. Existing content is never mutated in place. This preserves audit history.
- **Usage tracking**: `search` bumps `usage_count` and `last_used_at` on matched entries. `render_index` sorts by `last_used_at DESC, usage_count DESC`.

## Wiring into Runtime

```ocaml
(* OCaml SDK *)
let memory = match Sqlite_memory.create "~/.par/memory.db" with
  | Ok t -> Some (Sqlite_memory.make_service t)
  | Error _ -> None
in
match Runtime.create ~config ~llm ?memory switch with
| Ok rt -> ...
```

```python
# Python binding
config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "memory": {"backend": "sqlite", "path": "~/.par/memory.db"},
})
with Runtime(config) as rt:
    ...
```

## Builtin tools

When memory is configured, 3 builtin tools are auto-registered:

| Tool | Input | Description |
|------|-------|-------------|
| `recall_memory` | `{"query": "...", "limit": N}` | Search memories by keyword, scoped by `invoke_context.session_id` |
| `remember_memory` | `{"content": "...", "summary": "..."}` | Store a new memory, scoped by `invoke_context.session_id` |
| `search_history` | `{"query": "..."}` | Search conversation history |

All tools read the per-call scope from `Invoke_context.get_current_exn().session_id` — memories are automatically isolated by session.

## Scope isolation

The `scope` field is generic — applications decide what it means:

```python
# Scope by workspace
rt.set_session_id("workspace-123")
rt.invoke(agent, "Remember: use tabs not spaces")  # stored with scope="workspace-123"
rt.invoke(agent, "What did I tell you?")           # searches scope="workspace-123"

# Different session = different scope
rt.set_session_id("workspace-456")
rt.invoke(agent, "What did I tell you?")           # searches scope="workspace-456" — finds nothing
```

## Limitations

- **Vector-based semantic recall** is deferred to a future release. v0.7.1 ships keyword (FTS5) search only.
- **Cross-agent knowledge sharing**: each Runtime has its own memory service. Multi-agent knowledge sharing requires a shared SQLite file or a future remote backend.
