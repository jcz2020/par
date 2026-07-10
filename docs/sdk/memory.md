<!-- language: en -->

**English** · [简体中文](../zh/sdk/memory.md)

# Memory API

PAR provides a first-class memory abstraction for cross-session agent knowledge. Every agent that needs to remember facts across sessions previously had to implement schema + FTS5 + CRUD + retrieval from scratch. The `Memory_service` module eliminates this duplication.

## Overview

The memory module mirrors the `llm_service` closure-record pattern:

```ocaml
type embedding_fn = string list -> (float array list, string) result

type search_mode =
  | Keyword_only  (* FTS5 keyword search only *)
  | Vector_only   (* Embedding vector KNN search only *)
  | Hybrid        (* Keyword + vector with RRF fusion *)
  | Auto          (* Smart default: Hybrid if embedding available, else Keyword_only *)

module type MEMORY_SERVICE = sig
  type t

  val create : string -> (t, Memory_error.memory_error) result

  val add :
    t ->
    content:string ->
    ?summary:string ->
    ?scope:string ->
    ?metadata:(string * Yojson.Safe.t) list ->
    ?categories:string list ->
    ?source:string ->
    unit ->
    (Memory_object.memory_object, Memory_error.memory_error) result

  val search :
    t ->
    ?mode:search_mode ->
    ?scope:string ->
    ?limit:int ->
    string ->
    (Memory_object.memory_object list, Memory_error.memory_error) result

  val update :
    t ->
    Memory_object.memory_object ->
    (Memory_object.memory_object, Memory_error.memory_error) result

  val delete :
    t ->
    string ->
    (unit, Memory_error.memory_error) result

  val list_all :
    t ->
    ?scope:string ->
    ?limit:int ->
    unit ->
    (Memory_object.memory_object list, Memory_error.memory_error) result

  val close : t -> unit

  val render_index :
    t ->
    ?max_entries:int ->
    ?scope:string ->
    unit ->
    string
end
```

The runtime holds an optional `memory_service` record (closure-based, like `llm_service`):

```ocaml
type memory_service = {
  add_fn :
    content:string ->
    ?summary:string ->
    ?scope:string ->
    ?metadata:(string * Yojson.Safe.t) list ->
    ?categories:string list ->
    ?source:string ->
    unit ->
    (Memory_object.memory_object, Memory_error.memory_error) result;
  search_fn :
    ?mode:search_mode ->
    ?scope:string ->
    ?limit:int ->
    string ->
    (Memory_object.memory_object list, Memory_error.memory_error) result;
  update_fn :
    Memory_object.memory_object ->
    (Memory_object.memory_object, Memory_error.memory_error) result;
  delete_fn :
    string ->
    (unit, Memory_error.memory_error) result;
  list_all_fn :
    ?scope:string ->
    ?limit:int ->
    unit ->
    (Memory_object.memory_object list, Memory_error.memory_error) result;
  close_fn : unit -> unit;
  render_index_fn :
    ?max_entries:int ->
    ?scope:string ->
    unit ->
    string;
}
```

## Types

### `embedding_fn`

A local type wrapping `Types.embedding_service.embed_fn`. Takes a list of strings and returns their embedding vectors:

```ocaml
type embedding_fn = string list -> (float array list, string) result
```

When provided, the memory service uses vector-based search. Without it, only FTS5 keyword search is available.

### `search_mode`

Controls how `search` retrieves memories:

| Mode | Behavior |
|------|----------|
| `Keyword_only` | FTS5 keyword search with BM25 ranking |
| `Vector_only` | Embedding vector KNN search (requires `embedding_fn`) |
| `Hybrid` | Keyword + vector with Reciprocal Rank Fusion (RRF) |
| `Auto` | Smart default: `Hybrid` if embedding is available, else `Keyword_only` |

The `?mode` parameter on `search` defaults to `Auto`, so callers get the best available strategy without explicit configuration.

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
| `source` | `string` | Origin label (`"manual"`, `"agent"`, `"tool"`, `"import"`) |

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

### Hybrid search with RRF

When an embedding function is provided, `Hybrid` mode combines FTS5 keyword results with vector KNN results using Reciprocal Rank Fusion:

```ocaml
val hybrid_search :
  t ->
  ?scope:string ->
  ?limit:int ->
  ?weight_fts:float ->
  ?weight_vec:float ->
  ?rrf_k:int ->
  query:string ->
  query_vec:float array ->
  unit ->
  (Memory_object.memory_object list, Memory_error.memory_error) result
```

RRF merges ranked lists from both sources: `score(d) = 1/(k + rank_fts(d)) + 1/(k + rank_vec(d))`, where `k` defaults to 60. The `?weight_fts` and `?weight_vec` parameters allow adjusting the relative importance of each source.

## Wiring into Runtime

### OCaml SDK

```ocaml
(* Keyword-only (no embeddings) *)
let memory = match Sqlite_memory.create "~/.par/memory.db" with
  | Ok t -> Some (Sqlite_memory.make_service t)
  | Error _ -> None
in
match Runtime.create ~config ~llm ?memory switch with
| Ok rt -> ...

(* With embeddings + hybrid search *)
let my_embedding text_list =
  (* call your embedding API here *)
  Ok (List.map (fun _ -> Array.make 1536 0.0) text_list)
in
let memory = match Sqlite_memory.create ~dimension:1536 ~embedding_fn:my_embedding "~/.par/memory.db" with
  | Ok t -> Some (Sqlite_memory.make_service ~dimension:1536 ~embedding_fn:my_embedding "~/.par/memory.db")
  | Error _ -> None
in
match Runtime.create ~config ~llm ?memory switch with
| Ok rt -> ...
```

`Sqlite_memory.create` accepts two optional parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `?dimension` | 1536 | Embedding vector dimension |
| `?embedding_fn` | `None` | Embedding function; when `None`, only keyword search is available |

`Sqlite_memory.make_service` accepts the same optional parameters and returns `(Memory_service.memory_service, Memory_error.memory_error) result`.

### Python binding

```python
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
| `remember_memory` | `{"content": "...", "summary": "...", "categories": [...]}` | Store a new memory, scoped by `invoke_context.session_id` |
| `search_history` | `{"query": "...", "limit": N}` | Search conversation history across sessions |

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

- **Cross-agent knowledge sharing**: each Runtime has its own memory service. Multi-agent knowledge sharing requires a shared SQLite file or a future remote backend.
