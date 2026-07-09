<!-- language: zh -->

[English](../../sdk/memory.md) · **简体中文**

# Memory API

PAR 提供一等公民的记忆抽象，用于跨会话的 agent 知识存储。此前每个需要跨会话记忆的 agent 都得自己从零实现 schema + FTS5 + CRUD + 检索。`Memory_service` 模块消除了这种重复。

## 概览

记忆模块镜像了 `llm_service` 的闭包记录模式：

```ocaml
module type MEMORY_SERVICE = sig
  type t
  val create : string -> (t, memory_error) result
  val add : t -> memory_object -> (string, memory_error) result
  val search : t -> ?scope:string -> string -> (memory_object list, memory_error) result
  val update : t -> string -> memory_object -> (unit, memory_error) result
  val delete : t -> string -> (unit, memory_error) result
  val list_all : t -> ?scope:string -> unit -> (memory_object list, memory_error) result
  val close : t -> unit
end
```

运行时持有一个可选的 `memory_service` 记录（闭包式，与 `llm_service` 相同）：

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

## Memory 对象

每条记忆是一个 `memory_object` 记录：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `string` | UUID，`add` 时自动生成 |
| `content` | `string` | 完整文本内容 |
| `summary` | `string option` | 简短摘要（可选，FTS5 索引） |
| `scope` | `string option` | 分区键（workspace_id、user_id、tenant_id — 应用层自定义） |
| `metadata` | `(string * Yojson.Safe.t) list` | 任意键值对 |
| `categories` | `string list` | 分类标签 |
| `created_at` | `float` | Unix 时间戳 |
| `updated_at` | `float` | Unix 时间戳 |
| `source` | `string` | 来源标签（`"manual"`、`"agent"`、`"import"`） |

## 默认后端：SQLite + FTS5

默认的 `Sqlite_memory` 后端使用 SQLite FTS5（porter+unicode61 分词器）进行关键词搜索。通过 `ORDER BY rank` 实现 BM25 排序。

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

### 生命周期

- **只增不改（ADD-only）**：`update` 会创建带新 UUID 的新行，不会原地修改已有内容。这保留了审计历史。
- **使用追踪**：`search` 会提升匹配条目的 `usage_count` 和 `last_used_at`。`render_index` 按 `last_used_at DESC, usage_count DESC` 排序。

## 接入 Runtime

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
# Python 绑定
config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "memory": {"backend": "sqlite", "path": "~/.par/memory.db"},
})
with Runtime(config) as rt:
    ...
```

## 内置工具

配置 memory 后，自动注册 3 个内置工具：

| 工具 | 输入 | 说明 |
|------|------|------|
| `recall_memory` | `{"query": "...", "limit": N}` | 按关键词搜索记忆，按 `invoke_context.session_id` 分区 |
| `remember_memory` | `{"content": "...", "summary": "..."}` | 存储新记忆，按 `invoke_context.session_id` 分区 |
| `search_history` | `{"query": "..."}` | 搜索对话历史 |

所有工具从 `Invoke_context.get_current_exn().session_id` 读取每次调用的分区——记忆自动按会话隔离。

## 分区隔离

`scope` 字段是通用的——应用层自行决定其含义：

```python
# 按工作区分区
rt.set_session_id("workspace-123")
rt.invoke(agent, "记住：用 tabs 不用 spaces")  # 以 scope="workspace-123" 存储
rt.invoke(agent, "我跟你说了什么？")           # 搜索 scope="workspace-123"

# 不同会话 = 不同分区
rt.set_session_id("workspace-456")
rt.invoke(agent, "我跟你说了什么？")           # 搜索 scope="workspace-456"——什么都找不到
```

## 限制

- **向量化语义检索**推迟到后续版本。v0.7.1 仅提供关键词（FTS5）搜索。
- **跨 agent 知识共享**：每个 Runtime 有自己的 memory 服务。多 agent 知识共享需要共享 SQLite 文件或未来的远程后端。
