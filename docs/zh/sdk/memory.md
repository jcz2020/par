<!-- language: zh -->

[English](https://github.com/jcz2020/par/blob/main/../sdk/memory.md) · **简体中文**

# Memory API

PAR 提供一等公民的记忆抽象，用于跨会话的 agent 知识存储。此前每个需要跨会话记忆的 agent 都得自己从零实现 schema + FTS5 + CRUD + 检索。`Memory_service` 模块消除了这种重复。

## 概览

记忆模块镜像了 `llm_service` 的闭包记录模式：

```ocaml
type embedding_fn = string list -> (float array list, string) result

type search_mode =
  | Keyword_only  (* 仅 FTS5 关键词搜索 *)
  | Vector_only   (* 仅嵌入向量 KNN 搜索 *)
  | Hybrid        (* 关键词 + 向量，RRF 融合 *)
  | Auto          (* 智能默认：有嵌入用 Hybrid，否则 Keyword_only *)

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

运行时持有一个可选的 `memory_service` 记录（闭包式，与 `llm_service` 相同）：

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
  get_fn :                                              (* v0.8.1：按 ext_id 精确匹配 *)
    string ->
    (Memory_object.memory_object option, Memory_error.memory_error) result;
  update_fn :
    Memory_object.memory_object ->
    (Memory_object.memory_object, Memory_error.memory_error) result;
  upsert_fn :                                           (* v0.8.1：基于稳定 ID 的更新（DELETE+INSERT）*)
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

### v0.8.1 新增字段：`get_fn` 与 `upsert_fn`

v0.8.1 新增两个字段，用于支持编码 agent 的 **plan-then-execute**（先规划后执行）模式——读取当前 plan，原地修改，再写回：

- **`get_fn ext_id`** —— 按 `memory_object.ext_id`（稳定的外部 ID，例如 `"plan:current"`）做精确匹配查找。命中返回 `Ok (Some obj)`，未命中返回 `Ok None`。用于直接取"当前 plan"或"运行中摘要"，无需关键词搜索。
- **`upsert_fn obj`** —— 基于稳定 ID 的更新，通过对 `ext_id` 执行 `DELETE + INSERT` 实现。若相同 `ext_id` 的条目已存在则替换；否则插入新行。**保留之前行的 `usage_count` 与 `last_used_at`**，分析计数在更新后仍然有效。

#### `update_fn` 与 `upsert_fn` 的区别

| 操作 | 身份标识 | 行为 | 适用场景 |
|------|----------|------|----------|
| `update_fn obj` | 每次调用都生成新 UUID | 始终插入新行，已有内容永不原地修改 | 审计历史、事件日志、append-only 记忆 |
| `upsert_fn obj` | 稳定的 `ext_id` | 按 `ext_id` 执行 `DELETE + INSERT`；保留 `usage_count` / `last_used_at` | "当前 plan"、"运行中摘要"、"活动 TODO 列表" |

每个快照都重要（审计场景）选 `update_fn`；需要按稳定外部 ID 标识的"当前值"选 `upsert_fn`。

## 类型

### `embedding_fn`

本地类型，封装 `Types.embedding_service.embed_fn`。接收字符串列表，返回嵌入向量：

```ocaml
type embedding_fn = string list -> (float array list, string) result
```

提供嵌入函数时，记忆服务使用向量搜索。未提供时仅支持 FTS5 关键词搜索。

### `search_mode`

控制 `search` 如何检索记忆：

| 模式 | 行为 |
|------|------|
| `Keyword_only` | FTS5 关键词搜索，BM25 排序 |
| `Vector_only` | 嵌入向量 KNN 搜索（需要 `embedding_fn`） |
| `Hybrid` | 关键词 + 向量，通过 RRF（倒数排名融合）合并 |
| `Auto` | 智能默认：有嵌入用 `Hybrid`，否则 `Keyword_only` |

`search` 的 `?mode` 参数默认为 `Auto`，调用方无需显式配置即可获得最佳策略。

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
| `last_used_at` | `float option` | 最后检索时间；首次搜索命中前为 `None`。自动维护 |
| `usage_count` | `int` | 检索次数，每次 search/list_all 命中自动递增。影响 `list_all` 排序 |
| `source` | `string` | 来源标签（`"manual"`、`"agent"`、`"tool"`、`"import"`） |

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

- **默认 ADD-only**：`update_fn` 始终创建带新 UUID 的新行，不会原地修改已有内容。这保留了审计历史。
- **基于稳定 ID 的更新 `upsert_fn`**（v0.8.1）：当你需要按稳定 `ext_id` 标识的"当前 plan"或"运行中摘要"时，使用 `upsert_fn`——它按 `ext_id` 执行 `DELETE + INSERT`，并保留之前行的 `usage_count` / `last_used_at`。
- **使用追踪**：`search_fn` 提升匹配条目的 `usage_count` 和 `last_used_at`。`render_index` 按 `last_used_at DESC, usage_count DESC` 排序。

### 混合搜索与 RRF

提供嵌入函数时，`Hybrid` 模式通过倒数排名融合（RRF）合并 FTS5 关键词结果与向量 KNN 结果：

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

RRF 合并两个来源的排序列表：`score(d) = 1/(k + rank_fts(d)) + 1/(k + rank_vec(d))`，其中 `k` 默认为 60。`?weight_fts` 和 `?weight_vec` 参数允许调整各来源的相对权重。

## 接入 Runtime

### OCaml SDK

```ocaml
(* 仅关键词搜索（无嵌入） *)
let memory = match Sqlite_memory.create "~/.par/memory.db" with
  | Ok t -> Some (Sqlite_memory.make_service t)
  | Error _ -> None
in
match Runtime.create ~config ~llm ?memory switch with
| Ok rt -> ...

(* 使用嵌入 + 混合搜索 *)
let my_embedding text_list =
  (* 调用你的嵌入 API *)
  Ok (List.map (fun _ -> Array.make 1536 0.0) text_list)
in
let memory = match Sqlite_memory.create ~dimension:1536 ~embedding_fn:my_embedding "~/.par/memory.db" with
  | Ok t -> Some (Sqlite_memory.make_service ~dimension:1536 ~embedding_fn:my_embedding "~/.par/memory.db")
  | Error _ -> None
in
match Runtime.create ~config ~llm ?memory switch with
| Ok rt -> ...
```

`Sqlite_memory.create` 接受两个可选参数：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `?dimension` | 1536 | 嵌入向量维度 |
| `?embedding_fn` | `None` | 嵌入函数；为 `None` 时仅支持关键词搜索 |

`Sqlite_memory.make_service` 接受相同的可选参数，返回 `(Memory_service.memory_service, Memory_error.memory_error) result`。

### Python 绑定

```python
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
| `remember_memory` | `{"content": "...", "summary": "...", "categories": [...]}` | 存储新记忆，按 `invoke_context.session_id` 分区 |
| `search_history` | `{"query": "...", "limit": N}` | 搜索跨会话的对话历史 |

所有工具从 `Invoke_context.get_current_exn().session_id` 读取每次调用的分区——记忆自动按会话隔离。

### 应用层 API：`get_fn` / `upsert_fn`（v0.8.1）

上面三个内置工具是 LLM 调用的。需要**确定性访问**记忆的应用层代码——例如 plan-then-execute 模式（"读取当前 plan，修改，再写回"）——应直接在 `memory_service` 记录上调用 `get_fn` 和 `upsert_fn`，而非走 LLM 调用工具。

- `get_fn "plan:current"`：当 `ext_id = "plan:current"` 的记忆存在时返回 `Ok (Some obj)`，否则返回 `Ok None`。
- `upsert_fn obj`：按 `obj.ext_id` 匹配——若相同 `ext_id` 的条目已存在则替换（`DELETE + INSERT`），并保留 `usage_count` 与 `last_used_at`；否则插入新行。

"当前状态"类模式（当前 plan、运行中摘要、活动 TODO 列表）适用此 API。审计类"每个快照都重要"的模式仍用 `update_fn`。

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

- **跨 agent 知识共享**：每个 Runtime 有自己的 memory 服务。多 agent 知识共享需要共享 SQLite 文件或未来的远程后端。
