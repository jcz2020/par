<!-- language: zh -->
**[English](../sdk/observability.md)** · 简体中文

# 可观测性参考

> 源真相：`lib/core/metrics.mli`、`lib/event_bus/event_bus.mli`、`lib/core/runtime.ml` 以及 `lib/ffi/par_ffi.h` 中的 FFI 接口。覆盖 v0.5.1。Phase B.2（修复 Python FFI 重复调用 `health`/`metrics`/`workflow_status` 的回调句柄 bug）和 C.5（本页面）提供了文档化的接口。

本页面记录 PAR 暴露的可观测性接口，用于监控运行中的 runtime：流量和失败计数器、结构化生命周期信号的事件总线、以及用于存活探测的健康快照。如果你正在将 PAR 接入仪表盘、SLO 告警或 `/healthz` 端点，从这里开始。

## PAR 中的可观测性含义

PAR 将可观测性分为三层，每层有不同的延迟和不同的受众。

**指标（Metrics）** 是廉价的、数值型的，在 runtime 生命周期内聚合。它们回答诸如"我们做了多少次 LLM 调用？"和"有任务失败了吗？"这样的问题。定时拉取用于仪表盘。

**事件总线（Event bus）** 是结构化的、按次发生的、支持扇出的。每个任务转换、每次工具调用、每个工作流步骤都会发布事件。当你需要追踪发生了什么（而不仅仅是计数）时，订阅事件。

**健康（Health）** 是"这个 runtime 现在还能用吗？"的单次快照。它捆绑了存活状态、持久化可达性以及最近一次 LLM 调用的结果。从负载均衡器探测它。

第四层——日志，位于[日志中间件](middleware.md#logging)中而非独立模块。它为每个 LLM 和工具边界写入人类可读的行。本地调试用日志；生产信号用指标和事件。

## 指标

`Metrics` 模块是一个小型计数器存储。每个 runtime 拥有一个。Engine 运行时递增这些计数器，你通过 `Runtime.metrics_snapshot` 读取它们。

### counters 类型

```ocaml
type counters

val Metrics.empty : unit -> counters
```

`counters` 是不透明的。每个字段使用 `int Atomic.t`，因此递增是无锁且无竞争的。runtime 在 `Runtime.create` 时分配一个，并将其穿线到 Engine 中。每次调用的累加器使用单独的 `counters` 值，在 `invoke` 退出时折叠到 runtime 级别的计数器中。对 `counters` 值的唯一操作是六个递增器、快照和 `merge_into`。

### 线程安全

每个计数器都是 `Atomic.t`。`incr_*` 调用使用 `Atomic.incr`（无锁 CAS），因此并发的 `Runtime.invoke` fiber 永远不会在 mutex 上竞争。`snapshot` 使用 `Atomic.get` 读取每个计数器，返回最新值而不阻塞。这意味着指标始终是最终一致的：在递增过程中拍摄的快照可能看到部分更新的计数器集合，但每个单独的计数器值始终是最新的。

### 递增器

这些从 Engine 内部调用。除非你正在扩展 runtime，否则通常不会自己调用它们，但了解哪个在什么时候触发有助于你阅读快照。

```ocaml
val Metrics.incr_llm : counters -> unit
val Metrics.incr_task_completed : counters -> unit
val Metrics.incr_task_failed : counters -> unit
val Metrics.incr_tool_invocations : counters -> unit
val Metrics.incr_events_published : counters -> unit
val Metrics.incr_events_dropped : counters -> unit
```

`incr_llm` 在每次 LLM 往返（无论成功或失败）时触发。`incr_task_completed` 和 `incr_task_failed` 在任务终止转换时触发。`incr_tool_invocations` 计数每次处理器调用。两个事件计数器来自事件总线：`incr_events_published` 用于成功分发，`incr_events_dropped` 用于事件进入死信队列或溢出时。

### 快照

```ocaml
val Metrics.snapshot : counters -> (string * int) list
```

`snapshot` 返回六个计数器作为稳定的 `(key, value)` 对列表。键名是 Prometheus 风格的 `*_total` 名称，与指标抓取器期望的一致。

| 键名 | 递增时机 |
|------|---------|
| `llm_requests_total` | 每次 LLM provider 往返 |
| `task_completed_total` | 任务达到 `Completed` |
| `task_failed_total` | 任务达到 `Failed` |
| `tool_invocations_total` | 任何已注册的工具处理器被调用 |
| `events_published_total` | 事件总线向订阅者分发事件 |
| `events_dropped_total` | 事件进入 DLQ 或因溢出被丢弃 |

runtime 暴露快照，无需你直接操作 `counters` 值：

```ocaml
val Runtime.metrics_snapshot : runtime -> (string * int) list
```

### 合并计数器

`Runtime.invoke` 创建每次调用的 `counters` 累加器，使并发 invoke 不会在共享原子字段上竞争。invoke 退出时，使用 `merge_into` 将每次调用的计数器折叠到 runtime 级别的计数器中：

```ocaml
val Metrics.merge_into : target:counters -> source:counters -> unit
```

`merge_into` 将 `source` 中的每个计数器原子地添加到 `target` 中对应的计数器。两个操作数都使用 `Atomic` 字段，因此即使多个 invoke 并发退出，合并也是无竞争的。合并后，`source` 被丢弃。

你通常不会自己调用 `merge_into`，除非你正在构建自定义 runtime 或跨多个 runtime 实例聚合指标。标准路径是 `Runtime.metrics_snapshot`，它读取已经合并的 runtime 级别计数器。

### 不包含什么

PAR 的指标表面仅限计数器。没有 gauge（没有"当前队列深度"）和直方图（没有"LLM 延迟 p99"）。延迟和并发今天可通过事件总线观察：`Task_completed` 携带 `duration_ms`，`Llm_response_received` 携带 token `usage`，等等。如果你的 SLO 需要百分位数，订阅并自行计算。更丰富的指标模块在路线图上，但未安排在 v0.5.x。

## 事件总线

事件总线是 runtime 各部分都写入的发布/订阅通道。订阅者恰好收到每个事件一次，包装在携带元数据和重试状态的信封中。失败的投递移动到死信队列而不是消失。

### 创建和订阅

```ocaml
type t
type subscription = string

val Event_bus.create : Types.event_bus_config -> t

val Event_bus.subscribe :
  t -> (Types.event_envelope -> unit) -> subscription

val Event_bus.unsubscribe : t -> subscription -> unit

val Event_bus.start_dispatcher : t -> Eio.Switch.t -> unit
```

你通常不会自己调用 `create`。runtime 从 `runtime_config.event_bus` 构建总线，并在 runtime 生命周期内拥有它。你调用的是 `subscribe`，它返回一个不透明的 `subscription` id。如果你想稍后分离，保留它；如果订阅者应与 runtime 同生共存，丢弃它。如果你需要在 runtime 之外使用总线（用于测试，或用于你发布自己事件的嵌入式设置），`Event_bus.create` 加上在你控制的 switch 上调用 `Event_bus.start_dispatcher` 是路径。

`start_dispatcher` 生成排空总线的 fiber。runtime 在 `Runtime.create` 期间调用它。如果你在 runtime 之外构建总线，你必须在你控制的 switch 上自己启动分发器。

订阅者是接受 `event_envelope` 的单参数回调。订阅者内抛出的异常被分发器捕获并计入该投递的重试预算。

### 事件信封

每个事件在投递前被包装。

```ocaml
type event_envelope = {
  id : string;
  metadata : event_metadata;
  payload : event;
  idempotency_key : string;
  delivery_attempt : int;
}
```

`id` 对每个已发布事件唯一。`payload` 是类型化的事件本身（见下一节）。`delivery_attempt` 从 1 开始，每次重试递增。`idempotency_key` 让下游订阅者在从 DLQ 重放时去重。业务逻辑匹配 `payload`，追踪匹配 `metadata`。

### 事件类型

`event` 变体很大，因为总线覆盖整个 runtime 生命周期。下表按区域分组构造器。字段名称在此缩短；完整记录形状见 `Types.event` 定义。

| 分组 | 构造器 | 值得关注的字段 |
|------|--------|---------------|
| 任务生命周期 | `Task_created`、`Task_started`、`Task_completed`、`Task_failed`、`Task_cancelled`、`Task_suspended`、`Task_resumed` | `task_id`、`duration_ms`（完成时）、`error`（失败时）、`reason`（取消时） |
| LLM | `Llm_request_sent`、`Llm_response_received` | `model`、`usage` |
| 工具 | `Tool_invoked`、`Tool_completed`、`Tool_failed`、`Tool_progress` | `tool_name`、`duration_ms`、`result_preview` |
| Bash 工具 | `Bash_invoked`、`Bash_completed` | `argv`、`cwd`、`exit_code`、`risk` |
| 工作流 | `Workflow_started`、`Workflow_step_completed`、`Workflow_completed`、`Workflow_failed` | `workflow_run_id`、`step_id` |
| 审批 | `Approval_requested`、`Approval_granted`、`Approval_timeout` | `prompt`、`allowed_roles`、`approver` |
| 关闭 | `Shutdown_initiated`、`Shutdown_completed` | `exit_code` |
| MCP | `Mcp_server_started`、`Mcp_server_failed`、`Mcp_server_stopped`、`Mcp_tool_invoked`、`Mcp_tool_completed`、`Mcp_resource_read`、`Mcp_prompt_rendered` | `server_id`、`tool_name`、`uri` |
| 其他 | `Agent_handoff`、`Structured_output_completed` | `from_agent`/`to_agent`、`schema_valid` |

如果你只关心一个切片，在回调内按构造器过滤。没有内置的主题过滤。常见模式是一个小的辅助函数进行模式匹配并忽略其他一切。

### 死信队列

当订阅者抛出异常，或投递超过配置的尝试预算时，信封移动到死信队列而不是被静默丢弃。

```ocaml
val Event_bus.get_dead_letters : t -> Types.dead_letter_entry list
val Event_bus.dlq_entries : t -> Types.event list
val Event_bus.push_to_dlq :
  t -> Types.event_envelope -> string -> Types.error_category -> unit
```

`dead_letter_entry` 携带原始信封、错误字符串、类型化的 `failure_reason`、时间戳以及放弃时的尝试次数。`dlq_entries` 是只返回 payload 的便捷方法。如果你想对毒消息告警，从监控钩子读取这些。

DLQ 由 `event_bus_config.dlq_enabled` 控制，由 `dlq_max_size` 上限。队列满时，新条目挤出旧条目。

### 总线配置

```ocaml
type event_bus_config = {
  buffer_capacity : int;
  delivery : event_delivery_config;
  dlq_enabled : bool;
  dlq_max_size : int;
  critical_event_types : string list;
}
```

`buffer_capacity` 限制发布者和分发器之间的内存通道。满时发布者阻塞，这向 Engine 施加背压。`delivery` 调优重试行为：`max_delivery_attempts`、`initial_retry_delay`、`retry_backoff` 和 `delivery_timeout`。`critical_event_types` 是绕过缓冲区同步分发的构造器名称列表；用于不能等待积压的关闭信号。

runtime 提供合理的默认值：

```ocaml
Runtime.default_event_bus_config
(* buffer_capacity = 10000, DLQ enabled, exponential backoff *)
```

## Python FFI 接口

PAR 的 Python 绑定将健康、指标和工作流状态暴露为返回 dict 的普通方法。C 入口点在 `lib/ffi/par_ffi.h` 中；OCaml 实现在 `lib/ffi/par_capi.ml` 中。Phase B.2 修复了一个回调句柄 bug，该 bug 之前导致从同一个 `Runtime` 重复调用这些方法失败；修复由 `bindings/python/tests/test_runtime.py::TestCallbackHandleSurvival` 验证。

### `rt.health()`

```python
def health(self) -> dict: ...
```

返回形如以下的 dict：

```python
{
    "status": "ok",
    "runtime_alive": True,
    "persistence_ok": True,
    "last_llm_call_at": 1718230000.123,  # float 或 None
    "last_llm_call_status": "Success",   # 见下文
}
```

`runtime_alive` 在请求关闭后为 false。`persistence_ok` 用一个简单的读操作探测配置的后端。`last_llm_call_status` 是 `Success`、`Never_called`、`Error.Internal`、`Error.Timeout`、`Error.Invalid_input`、`Error.External_failure`、`Error.Rate_limited`、`Error.Permission_denied`、`Error.Embedding_unsupported` 之一。将 `runtime_alive and persistence_ok` 映射到 200，其他映射到 503，用于 Kubernetes 风格的存活探测。

### `rt.metrics()`

```python
def metrics(self) -> dict: ...
```

绑定为你解包快照，所以返回值直接是指标 dict 而不是包装器。键名与 OCaml 快照名称匹配。

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

缺失的键为零。按你的抓取器期望的频率轮询；调用开销小且不阻塞 Engine。

### `rt.workflow_status(run_id)`

```python
def workflow_status(self, run_id: str) -> dict: ...
```

在 v0.5.1 中对任何 run id 返回 `{"run_id": run_id, "status": "unknown"}`。工作流状态查找是桩实现：OCaml 端对每次调用返回字面量 `"unknown"` 状态字符串。这是一个已知的差距。该方法存在以便调用代码可以现在就针对最终形状编写，一旦工作流状态存储被接入，就会开始接收真实状态。将任何非 `"unknown"` 值视为未来兼容的额外奖励。

### `par_event_subscribe`

C 符号 `par_event_subscribe` 在 `lib/ffi/par_ffi.h` 中声明并在 OCaml 端注册，但实现是返回 `-1` 的桩。从 Python 的事件订阅尚不可用。如果你今天需要从 Python 获取事件级信号，轮询 `rt.metrics()` 并 diff `events_dropped_total`。从 Python 的真正事件流式传输作为未来工作跟踪。

## 示例

两个端到端模式：一个 OCaml，一个 Python。两者都写成可以直接粘贴到测试或小脚本中的形式。

### OCaml：订阅工具完成事件

这个代码片段构建一个独立的总线，在 switch 上启动其分发器，订阅一个为每个 `Tool_completed` 打印一行的回调，并返回 subscription id。`match` 忽略所有其他构造器，所以回调对 LLM 和工作流流量保持安静。通过 `Runtime.create` 创建的 runtime 内部拥有自己的总线；你可以用同样的方式订阅该总线，从你的代码持有 runtime 内部的地方获取 `Event_bus.t`。

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

当监视器应停止时，将 `sub` 传给 `Event_bus.unsubscribe bus sub`。如果你也想要失败事件，添加一个 `Tool_failed` 分支。如果你想要完整追踪，记录每个分支。

### Python：轮询健康和指标

一个循环，每隔几秒调用 `health()` 和 `metrics()` 并打印一行摘要。适合将信号发送到现有仪表盘的 sidecar。

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

`events_dropped` 是需要告警的计数器。任何大于零的值意味着订阅者失败或总线溢出，两种情况都值得调查。`tasks_failed` 上升而 `tasks_completed` 没有相应上升通常指向工具或 provider 回归。

## 限制

- **仅计数器。** 没有 gauge，没有直方图。如果需要延迟，从事件的 `duration_ms` 字段派生。
- **没有 Prometheus 暴露。** PAR 不提供 `/metrics`。将 `rt.metrics()` 的 dict 管道到你自己的 exporter。
- **没有分布式追踪 span。** 事件携带 `task_id` 和 `workflow_run_id` 用于关联，但没有 OpenTelemetry exporter。如果你想发射 span，钩住事件总线。
- **`par_event_subscribe` 是桩。** Python 调用者还不能以推送方式接收事件。同时轮询指标。
- **`workflow_status` 始终返回 `"unknown"`。** 方法形状稳定；实现不稳定。
- **单进程范围。** 指标和事件总线存在于创建它们的 runtime 中。一个进程中的两个 `Runtime` 实例不共享计数器。对于多进程聚合，抓取每个 runtime 并外部合并。

## 另请参阅

- [Agent API](agent.md) - `agent_config`、runtime 创建、runtime 暴露的接口
- [中间件 API](middleware.md) - 在每个边界写入人类可读行的日志中间件
- [Streaming API](streaming.md) - 分块输出，有意与事件总线分离
- [架构](../explanation/architecture.md) - Engine、事件总线和持久化如何配合
