<!-- language: zh -->

[English](../sdk/persistence.md) · **简体中文**

# Persistence API

PAR 内置一个持久化层，将事件、任务状态、工作流检查点和对话历史存储在本地 SQLite 数据库中。持久化服务是可选的。配置后，每次 `Runtime.invoke` 调用都会获得持久存储。不配置时，runtime 以临时模式运行，适合快速实验和单元测试。

## 概览

持久化层遵循与 `llm_service` 和 `memory_service` 相同的闭包记录模式。`persistence_service` 记录持有函数指针，每个操作一个。默认后端是 SQLite。Noop 后端用于测试。

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

## 后端

### SQLite（默认）

`Sqlite_persistence` 是生产后端。它将所有内容存储在单个 SQLite 文件中，使用 WAL 模式支持并发读取。Schema 在首次打开时自动创建，迁移会在新版本引入新列时静默运行。

```ocaml
val Sqlite_persistence.create :
  ?retention_ttl:float -> string -> (Sqlite_persistence.t, error_category) result
```

可选的 `retention_ttl` 参数设置旧事件保留时长（秒）。默认值为 7 天（604800 秒）。创建时，超过 TTL 的事件会被清理。

### Noop（测试）

`Noop_persistence` 什么都不做。每个操作返回 `Ok ()` 或 `Ok None`。当你想让 runtime 编译运行但不触碰磁盘时使用它。

```ocaml
val Noop_persistence.create : string -> (Noop_persistence.t, error_category) result
```

## `scope` 维度

许多持久化函数接受可选的 `?scope:string` 参数。Scope 是一个通用的分区键。应用层决定它的含义：workspace id、user id、tenant id、部署环境或任何其他分组维度。runtime 不解释这个值。

当 `scope` 为 `None` 时，操作覆盖所有 scope。当 `scope` 为 `Some "workspace-123"` 时，操作仅限于该分区。

```python
# Python：按 workspace 分区
config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": "par.db"},
})
with Runtime(config) as rt:
    rt.set_session_id("workspace-123")
    rt.invoke(agent, "总结日志")  # 以 scope="workspace-123" 存储

    rt.set_session_id("workspace-456")
    rt.invoke(agent, "总结日志")  # 以 scope="workspace-456" 存储
```

```ocaml
(* OCaml：加载特定 workspace 的事件 *)
let events = rt.persistence.load_events_by_session_fn
  ~scope:"workspace-123" session_id
in ...
```

## CRUD 函数

### 事件

事件是核心审计日志。每次任务转换、LLM 调用、工具调用和工作流步骤都会发布事件。持久化层持久存储这些事件。

| 函数 | Scope 参数 | 说明 |
|------|-----------|------|
| `save_events_fn` | `?scope:string` | 向事件日志追加一批事件 |
| `load_events_fn` | 无 | 加载指定 task id 的所有事件 |
| `load_events_by_session_fn` | `?scope:string` | 加载 session id 的所有事件，可按 scope 过滤 |
| `load_sessions_fn` | `?scope:string` | 列出最近的会话及事件计数，可按 scope 过滤 |

`load_sessions_fn` 返回的 `session_summary` 类型：

```ocaml
type session_summary = {
  session_id : string;
  event_count : int;
  first_event_at : float;
  last_event_at : float;
}
```

### 任务状态

任务状态快照让你可以恢复或检查任务进度，无需重放事件。

| 函数 | 说明 |
|------|------|
| `save_task_state_fn` | 更新 task_state 记录 |
| `load_task_state_fn` | 按 task id 加载 task_state，不存在则返回 `None` |

### 工作流状态

工作流持久化处理检查点、挂起的工作流和工作流定义。

| 函数 | 说明 |
|------|------|
| `save_workflow_state_fn` | 保存工作流状态和可选检查点 |
| `load_workflow_state_fn` | 加载工作流运行的检查点 |
| `load_all_suspended_workflows_fn` | 列出所有挂起的工作流（用于崩溃后恢复） |
| `save_workflow_def_fn` | 按 id 存储工作流定义 |
| `load_all_workflow_defs_fn` | 列出所有已存储的工作流定义 |

### 对话历史

对话存储一个 session id 的完整消息历史。每次保存会替换该 session id 之前的对话。

| 函数 | Scope 参数 | 说明 |
|------|-----------|------|
| `save_conversation_fn` | `?scope:string` | 为 session id 保存对话 |
| `load_conversation_fn` | 无 | 按 session id 加载对话 |
| `load_most_recent_conversation_fn` | `?scope:string` | 加载最近更新的对话，可按 scope 过滤 |

## 配置持久化

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

`persistence` 字段接受：

- `` `Sqlite "path/to/db" `` 用于文件数据库
- `` `Sqlite ":memory:" `` 用于内存数据库（测试、演示）

### Python 绑定

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

## SQLite Schema

后端在首次打开时创建五张表：

| 表 | 用途 |
|----|------|
| `events` | 事件日志，包含 task_id、session_id、scope、payload |
| `task_states` | 任务状态快照 |
| `workflow_states` | 工作流检查点和状态 |
| `conversations` | 对话消息和元数据 |
| `workflow_definitions` | 按 id 存储的工作流定义 |

索引创建在 `task_id`、`session_id`、`scope` 和 `updated_at` 上以支持高效查询。`scope` 列通过迁移添加，如果从旧版本升级。

## 线程安全

所有 SQLite 操作通过 `Eio.Mutex.t` 序列化。同一个 runtime 上的并发 `Runtime.invoke` 调用安全共享同一个持久化后端。写操作使用 `Eio.Mutex.use_rw`，读操作使用 `Eio.Mutex.use_ro`。

## 限制

- **单进程范围。** 一个进程中的两个 `Runtime` 实例可以打开同一个 SQLite 文件，但来自不同进程的并发写入可能导致 `SQLITE_BUSY`。对于多进程环境，每个进程使用一个 runtime 或使用外部数据库。
- **无网络后端。** 持久化层仅支持本地 SQLite。对于分布式持久化，使用共享数据库并编写你自己的 `persistence_service` 记录。
- **无向量存储。** 事件 payload 以 JSON 文本存储。向量化检索由单独的 `Memory_service` 模块处理。

## 另请参阅

- [Agent API](agent.md) - `Runtime.create`、`invoke` 以及生成事件的生命周期
- [Memory API](memory.md) - 带 FTS5 搜索的跨会话知识存储
- [可观测性](observability.md) - 用于监控持久化活动的指标计数器和事件总线
- [架构](../explanation/architecture.md) - 持久化如何融入整体 runtime 设计
