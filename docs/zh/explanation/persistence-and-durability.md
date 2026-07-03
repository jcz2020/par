<!-- language: zh -->

**[English](../explanation/persistence-and-durability.md)** · 简体中文

# 持久化与持久性

> **Note (v0.6.7):** 本文中对 `par ask` 的引用是历史性的（CLI 已移除）。SQLite 持久化层没有变化，仍是推荐的嵌入式存储——用法见 [SDK 概览](../sdk/overview.md)。

PAR 可以完全不使用持久化，也可以使用嵌入式 SQLite 数据库。本文解释*为什么*存在两个层级、它们在实践中*如何*不同，以及从运行时发布事件到事件落盘之间发生了什么。这是一篇解释性文章，不是配置参考。配置字段名请阅读 `lib/core/types.ml` 和 `docs/sdk/` 下的 SDK 参考。这里我们追踪写入路径、拆解 schema，并说明何时选择哪个层级。

## 持久化在 PAR 中的用途

Agent 运行时会产生事件。每次工具调用、每次任务状态变更、每次工作流检查点、每次 bash 命令及其风险分类，都作为 `Par.Types.event` 发出。这些事件有三个用途：审计（agent 做了什么、什么时候做的）、调试（为什么走那条路径）、恢复（崩溃后能否恢复这个工作流）。没有持久化，进程退出的瞬间三者全部丢失。

PAR 把持久化视为*最终一致的审计日志*，而非事务性状态存储。Agent 循环本身不会在持久化上阻塞。`Runtime.invoke` 发出 `Tool_invoked` 事件时，事件去往事件总线，再到批量写入器，最后到 SQLite，全程异步。写入失败时运行时记录日志并继续运行。Agent 的正确性不依赖审计日志的持久性，只依赖 LLM 响应和工具结果在内存中的正确性。这种分离让 PAR 在负载下保持快速，同时事后给你审计轨迹。

例外是工作流检查点。工作流状态存储在 `workflow_states` 表中，在工作流步骤完成时写入，以便崩溃后恢复。这条路径对延迟更敏感，但仍通过同一个批量写入器。如果你需要工作流恢复的严格持久性，就接受批量延迟。

## 两个持久化层级

PAR 提供两个持久化层级，通过 `runtime_config` 的 `persistence` 字段控制：

- `` `Sqlite `` 是唯一的持久化后端，也是默认值。单个文件（测试用 `:memory:`）。零外部依赖：`sqlite3` 库是 `par` 包的硬依赖。你得到 WAL 模式、完整 schema、保留期裁剪，全套功能。这就是 `par ask` 和 Python quickstart 使用的后端。公共配置类型是 `[ `Sqlite of string ]`，字符串是数据库路径。没有其他配置变体。
- `` `Noop `` 是测试用的内存后端。丢弃所有内容。无事件总线、无写入 fiber、无 I/O。只关心 agent 行为的测试运行更快且不留下文件。Noop 以内部持久化类型的变体形式在编程接口中可用，但不作为配置选项暴露：公共配置只携带 SQLite 路径。如果想从配置层面获得内存行为，把 SQLite 指向 `:memory:` 即可。

`` `Noop `` 层级也是一个微妙的架构声明。持久化为 noop 时，运行时完全跳过事件总线的接线。没有死总线喂给死写入器。`Persistence_writer` 和 `Event_bus` 实例在运行时记录上是 `None`。这让测试路径精简，也使单元测试中意外留下后台 drain fiber 运行变得不可能。

## Schema：三张表

SQLite 使用 `lib/persistence/sqlite_persistence.ml` 中定义的 schema。三张表：

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

`events` 是追加式审计日志。每个发布的事件被 JSON 序列化到 `payload`，标记 `task_id` 和 `timestamp`，通过 `idempotency_key` 去重。`session_id` 列让你按会话过滤事件，`actions_json` 携带结构化的副作用数据（比如 bash 调用的命令向量）。两个索引 `idx_events_task_id` 和 `idx_events_session_id` 保持常见查询路径的性能。

`task_states` 跟踪任务生命周期：排队、运行中、完成、失败。`workflow_states` 保存工作流检查点，使多步工作流在崩溃后可以恢复。两者都使用 `updated_at` 作为单调时钟排序。

Schema 借鉴自 LangGraph 的三表模型，它是对检查点系统需求的抽象：发生过什么的日志（`events`）、瞬时状态的快照（`task_states`）、长期运行状态的快照（`workflow_states`）。PAR 刻意没有发明第四种形态。三表模式在 agent 框架中经过实战检验，复用它意味着运维手册（如何查询会话历史、如何裁剪、如何恢复）可以直接迁移。

## 写入路径：从事件总线到磁盘

有趣的部分是事件如何从 `rt.publish_event_fn` 到 SQLite 而不阻塞 agent 循环。路径有三跳。

```
Runtime.publish_event
   │
   ▼
Event_bus（内存中，扇出到订阅者）
   │   └─ 订阅者: Persistence_writer.push
   │
   ▼
Persistence_writer.buffer（容量 1000，Mutex 保护的列表）
   │
   │  每 50ms，drain fiber 唤醒：
   ▼
grab_pending  ◄── 取走整个 buffer，重置为 []
   │
   ▼
save_fn(batch)  ◄── persistence.save_events_fn  ─►  SQLite
```

第一跳：`publish_event_fn` 是事件总线的发布函数。总线是内存中的扇出结构，带死信队列。每个订阅者收到每个事件。其中一个订阅者是调用 `Persistence_writer.push` 的闭包。

第二跳：写入器在 mutex 保护的列表中缓冲事件。容量 1000 个事件。新事件到来时缓冲已满，溢出函数触发，把事件路由到总线的 DLQ 而非静默丢弃。缓冲是列表，逆序前插，所以 `push` 是 O(1)，刷新时批量反转。

第三跳：一个 drain fiber，在运行时创建时通过 `Eio.Fiber.fork_daemon` 作为守护进程 fork 出来，永远循环。它 yield 两次（给其他 fiber 机会），取走整个待处理缓冲区，然后对批量调用 `save_fn`。刷新间隔是 50 毫秒，由 `Persistence_writer.create` 中的 `flush_interval: 0.05` 设置。这意味着在稳定负载下，事件在发布后 50 毫秒内落盘，批量写入而非每次 INSERT 一个事件。

这里有两个重要属性。第一，agent 循环从不在持久化上阻塞。`publish_event_fn` 立即返回；实际 I/O 在单独的 fiber 上发生。第二，关闭是干净的。`Runtime.close` 把写入器的 `running` 标志设为 false，调用 `flush_sync`，在运行时拆解前取走剩余事件并写入。drain fiber 发现 `running` 为 false 后以 `` `Stop_daemon `` 退出。因为它是守护 fiber，退出不会阻塞 switch 拆解。如果取消到达时正在刷新中，它会捕获 `Eio.Cancel.Cancelled`，执行最后一次同步刷新，然后停止。优雅关闭时不会丢失任何事件。

## WAL 模式与并发

SQLite 的 WAL（Write-Ahead Logging）模式让读者和单个写者可以并发进行而不互相阻塞。PAR 启用 WAL，因为典型负载是一个写者（批量 drain fiber）和多个读者（历史查询、恢复查找、`par history` CLI 命令）。不启用 WAL 的话，每次读取都要获取共享锁并阻塞写者。

WAL 有一个运维影响：数据库目录必须可写，因为 SQLite 会在主 `.db` 文件旁创建 `-wal` 和 `-shm` sidecar 文件。如果你把 PAR 指向只读目录，WAL 设置会失败，`Runtime.create` 时报错。临时或测试运行用 `:memory:` 可以完全规避这个问题。

WAL 加 SQLite 文件锁有一个约束：同一时间只有一个进程应该写入文件。单个 PAR 运行时拥有文件是支持的模型。两个运行时从不同进程指向同一个 `.db` 文件会在锁上竞争，负载下会看到 `SQLITE_BUSY` 错误。

## 保留期：7 天默认值

不加控制的话，events 表会无限增长。PAR 会裁剪它。默认保留 TTL 为 7 天（`default_retention_ttl = 7. *. 24. *. 60. *. 60.`，在 `lib/persistence/sqlite_persistence.ml` 中）。SQLite 后端打开时会运行一次裁剪，删除所有超过 TTL 的事件。你可以在创建时为每个后端覆盖 TTL。

裁剪基于时间戳，仅针对 `events` 表。`task_states` 和 `workflow_states` 不自动裁剪，因为它们的行代表可恢复状态而非历史噪音。如果你想清理它们，自己写 DELETE。假设是长期运行的服务关心审计历史的过期清理，但不关心丢失可能仍需恢复的工作流检查点。

## 何时选择哪个层级

| 场景 | 层级 | 原因 |
|------|------|------|
| 本地开发、单实例生产 | `` `Sqlite `` | 零配置，文件在磁盘上，WAL 处理读写混合负载。单个 SQLite 运行时通过批量写入器可以处理每秒数百个事件；瓶颈通常是 LLM provider 而非数据库。备份 `.db` 文件。 |
| 测试、CI、任何不需要磁盘审计轨迹的场景 | `` `Noop `` | 无 I/O、无残留文件、最快。 |

值得直说的诚实局限：SQLite 是单文件、单写者数据库。它的文件锁无法跨容器的多进程写入同一文件。如果你需要多个 PAR 进程同时访问相同数据，当前选项是在应用层分片（一个运行时，一个数据库文件，按租户或会话分区）或运行一个写者让其他实例读副本。跨实例共享状态在路线图上规划为未来的远程层，而非 SQLite 目前能提供的。见"即将到来"部分。

单个 SQLite 运行时足以应对大量真实负载。想超越它的原因是带共享状态的水平扩展，而这正是双层架构工作要填补的空白。

## 即将到来

当前模型是单层：事件去往一个后端，仅此而已。未来版本计划双层模型：快速本地层（SQLite，低延迟，短保留期）加远程层（未来的持久化后端或对象存储，持久化，长保留期）。本地层吸收突发流量，异步转发到远程层。这是标准的热/冷日志架构。在它落地之前，根据上面的矩阵选择你的层级，接受目前只有一层的事实。

双层设计在路线图上（bd issue `PAR-4dt`，目标 v0.6+），因为单层模型迫使你在延迟（SQLite，本地，快）和跨实例持久性（能承受多写者的远程层）之间做选择。一个同时需要两者的服务必须在每个实例本地运行 SQLite 并放弃跨实例共享查询，或者对自己的负载做分片。双层路径会让服务保留本地 SQLite 做亚毫秒级审计写入，同时复制到远程层做跨实例查询。理论上是这样。实现还没到。

## 另请参阅

- [架构](architecture.md) 持久化在模块结构中的位置和事件流图
- [并发模型](concurrency-model.md) drain fiber 如何与运行时 switch 和取消协作
- [Workflow API](../sdk/workflow.md) 工作流检查点如何与 `workflow_states` 交互
- [SDK 概览](../sdk/overview.md) 事件总线订阅 API（本写入路径的读取侧配套）
