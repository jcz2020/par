# P-A-R (Programmable Agent Runtime) 完整设计 v1.2

> 一个类型安全、可嵌入、支持严格工作流与可插拔校验的 Agent 运行时，基于 OCaml + Eio 实现。

**版本**: v1.2（实现修订版）
**日期**: 2026-05-26
**状态**: Draft

### v1.2 修订记录

| 编号 | 级别 | 修复内容 | 章节 |
|------|------|---------|------|
| R1-1 | HIGH | 移除所有 `Eio.Fiber.t` 返回类型包装（Eio协作式调度，无类型级纤程） | §2.2, §2.7, §3 |
| R1-2 | HIGH | `service_registry.llm` 改为 `llm_service` record 类型 | §2.8 |
| R1-3 | HIGH | `runtime.create` 支持可选 `persistence`/`event_bus` 参数（no-op 默认值） | §9.1 |
| R1-4 | HIGH | `model_config.provider` 改为闭包变体（yojson 派生兼容） | §2.4 |
| R1-5 | HIGH | `tool_binding.handler` 直接返回（移除纤程包装） | §2.4 |
| R1-6 | MED | 添加 `ppx_compare` 到 par_core preprocessors | §1 |
| R1-7 | MED | `error_category` 移除 `sexp_of`（仅保留 `yojson` + `compare`） | §2.2 |

### v1.1 修订记录

| 编号 | 级别 | 修复内容 | 章节 |
|------|------|---------|------|
| P0-1 | HIGH | Tool Handler 加入 Result 错误通道 | §2.2 |
| P0-2 | HIGH | LLM Response 改为 record（支持文本+工具调用并存） | §2.3 |
| P0-3 | HIGH | 补全 Agent.t 类型定义 | §2.4 |
| P0-4 | HIGH | 定义 Eio 取消协议与协作式取消 | §2.7 |
| P0-5 | HIGH | 穷举状态转换表 + Waiting/Paused 语义分离 | §2.6 |
| P0-6 | HIGH | runtime_context 改为抽象服务注册表 | §2.8 |
| P1-1 | MED | 事件总线重试协议 + DLQ + 幂等性 | §6.2 |
| P1-2 | MED | 工作流调度器改为事件驱动 | §11.2 |
| P1-3 | MED | Eio.Condition 虚假唤醒防护 | §4.4 |
| P1-4 | MED | 优雅关闭策略（6 阶段） | §5 |
| P1-5 | MED | 全局资源配额 + 信号量控制 | §4.2 |
| P1-6 | MED | SQLite 单写者 / PostgreSQL 推荐生产 | §7 |
| P1-7 | MED | Hashtbl 并发安全（Eio.Mutex 保护） | §4.3 |
| P1-8 | MED | Human Approval 鉴权/超时/审计 | §13.1 |
| P2-1 | LOW | 仅用 Base（排除 Core） | §1 |
| P2-2 | LOW | retry_policy.retry_on 改为 ADT 变体 | §2.5 |
| P2-3 | LOW | Waiting/Paused 合并为 Waiting_input/Suspended | §2.6 |
| P2-4 | LOW | Middleware 解耦为独立可选钩子单元 | §10.1 |
| P2-5 | LOW | 完整 Streaming 设计 | §8.2 |
| P2-6 | LOW | 上下文窗口管理策略 | §8.3 |
| P2-7 | LOW | 表达式求值器安全化 | §12 |

---

## 目录

1. [项目目标与边界](#1-项目目标与边界)
2. [核心类型系统](#2-核心类型系统)
3. [核心引擎设计](#3-核心引擎设计)
4. [并发模型](#4-并发模型)
5. [优雅关闭](#5-优雅关闭)
6. [事件系统](#6-事件系统)
7. [持久化设计](#7-持久化设计)
8. [LLM 客户端](#8-llm-客户端)
9. [SDK 设计](#9-sdk-设计)
10. [中间件系统](#10-中间件系统)
11. [工作流引擎](#11-工作流引擎)
12. [条件表达式](#12-条件表达式)
13. [安全性](#13-安全性)
14. [项目结构](#14-项目结构)
15. [测试策略](#15-测试策略)
16. [开发路线](#16-开发路线)
17. [交付物清单](#17-交付物清单)

---

## 1. 项目目标与边界

P-A-R (Programmable Agent Runtime) 是一个基于 OCaml + Eio 构建的可编程 Agent 运行时，旨在为 AI 工作流提供企业级的类型安全任务调度、灵活的工具系统和可扩展的中间件架构。

### 项目目标

- **类型安全的任务与工作流**：通过强类型系统确保任务状态、转换和输出的编译期安全
- **可插拔工具系统**：统一的 Schema/Handler/check_fn 接口，支持运行时工具注册与权限控制
- **灵活的中间件链**：支持在 LLM 调用、工具调用、错误处理等关键节点插入自定义逻辑
- **严格的 DAG 工作流**：基于依赖表的工作流执行，保证执行顺序和容错策略
- **可选的验证中间件**：提供反思修复、多模型共识等可选组件
- **可嵌入的 SDK**：轻量级嵌入到现有应用，最小化外部依赖
- **OpenTelemetry 集成**：开箱即用的 tracing、metrics 和日志

### v1 范围边界

以下功能不在 v1 范围内，将在后续版本迭代：

- 多租户支持
- Planner（自动 DAG 生成）
- 成本感知调度
- 自动依赖推断
- 动态上下文压缩

### 依赖表

v1.0 仅依赖以下基础库，**不引入 `Core`**（Eio 纤程模型与 Core IO 抽象冲突）：

| 包名 | 用途 |
|------|------|
| `base` | 标准库扩展（非 Core，仅数据结构增强） |
| `eio` | 并发运行时（结构化并发、纤程、定时器） |
| `yojson` | JSON 序列化/反序列化 |
| `caqti-eio` | 数据库连接池（SQLite/PostgreSQL） |
| `logs` | 结构化日志 |
| `cmdliner` | CLI 参数解析 |
| `ounit2` / `tezt` | 单元/集成测试 |
| `tls-eio` | TLS 加密通信 |

### 架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                SDK Layer                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                 │
│  │   Client    │    │   Server    │    │  Embedded   │                 │
│  └─────────────┘    └─────────────┘    └─────────────┘                 │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                            Engine Core                                   │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                 │
│  │   Agent     │    │  Workflow   │    │ToolPipeline │                 │
│  │   Engine    │    │  Executor   │    │             │                 │
│  └─────────────┘    └─────────────┘    └─────────────┘                 │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          ▼                         ▼                         ▼
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│   LLM Service   │      │   Persistence   │      │    EventBus     │
│                 │      │                 │      │                 │
│  ┌───────────┐  │      │  ┌───────────┐  │      │  ┌───────────┐  │
│  │ OpenAI    │  │      │  │  SQLite   │  │      │  │  In-Mem   │  │
│  │ Anthropic │  │      │  │ PostgreSQL│  │      │  │  Redis    │  │
│  │ Ollama    │  │      │  └───────────┘  │      │  └───────────┘  │
│  └───────────┘  │      └─────────────────┘      └─────────────────┘
└─────────────────┘
```

---

## 2. 核心类型系统

本节定义 P-A-R v1 的核心类型系统。所有类型均使用 `yojson` 派生支持序列化，便于日志、调试和跨服务通信。

### 2.1 基础标识符类型

标识符是系统中的基本寻址单元。每个标识符类型都使用 UUID v4 作为底层实现，确保全局唯一性和不可预测性。

```ocaml
(* Task_id — 任务的唯一标识 *)
module Task_id : sig
  type t [@@deriving yojson, compare, sexp_of]

  val create : unit -> t
  val to_string : t -> string
  val of_string : string -> (t, [> `Invalid_id of string]) result
end

(* Workflow_run_id — 工作流执行的唯一标识 *)
module Workflow_run_id : sig
  type t [@@deriving yojson]
  val create : unit -> t
  val to_string : t -> string
end

(* Session_id — 会话的唯一标识，用于追踪用户交互 *)
module Session_id : sig
  type t [@@deriving yojson]
  val create : unit -> t
  val to_string : t -> string
end
```

### 2.2 工具结果类型 (handler_result) — **[P0-1 修复]**

工具执行结果需要同时表达成功/失败状态，并为重试策略提供决策依据。

```ocaml
(* 错误分类 — ADT，用于模式匹配和差异化处理 *)
type error_category =
  | Timeout                          (* operation exceeded time limit *)
  | Invalid_input of string          (* input validation failure *)
  | External_failure of string       (* upstream service error *)
  | Rate_limited                     (* API rate limit hit *)
  | Permission_denied of string      (* authorization failure *)
  | Internal of string               (* unexpected runtime error *)
[@@deriving yojson, compare]

(* 工具执行结果 *)
type handler_result =
  | Success of Yojson.Safe.t
  | Error of {
      category : error_category;      (* drives retry policy decisions *)
      message : string;
      retryable : bool;               (* feeds retry policy engine *)
      metadata : (string * Yojson.Safe.t) list;  (* structured context *)
    }
[@@deriving yojson]
```

**设计决策**：

- `error_category` 使用 ADT 而非字符串，支持编译期穷举检查
- `retryable` 字段从错误分类中独立出来，因为同一分类在不同场景下可能行为不同
- `metadata` 使用 `(string * json) list` 而非记录，保留扩展灵活性

### 2.3 LLM 响应类型 (llm_response) — **[P0-2 修复]**

LLM 响应类型需要准确反映真实 LLM 行为。Claude 和 GPT-4o 可能**同时**返回文本和工具调用。

```ocaml
(* 工具调用请求 *)
type tool_call = {
  id : string;                       (* tool call ID from provider *)
  name : string;                     (* tool function name *)
  arguments : Yojson.Safe.t;         (* parsed JSON arguments *)
}
[@@deriving yojson]

(* 完成原因 *)
type finish_reason =
  | Stop               (* normal completion *)
  | Tool_calls         (* model wants to call tools *)
  | Max_tokens         (* hit token limit *)
  | Content_filter     (* filtered by safety *)
[@@deriving yojson]

(* token 使用统计 *)
type usage_stats = {
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
}
[@@deriving yojson]

(* LLM 完整响应 — 允许 text 和 tool_calls 同时存在 *)
type llm_response = {
  text : string option;              (* may be absent when tool_calls present *)
  tool_calls : tool_call list option; (* may be absent when text present *)
  finish_reason : finish_reason;
  usage : usage_stats;
  model : string;                    (* actual model used *)
}
[@@deriving yojson]
```

**关键约束**：至少 `text` 或 `tool_calls` 其中之一必须为 `Some`。

```ocaml
val llm_response_validate : llm_response -> (unit, string) result
```

**修复说明**：原设计使用 `Text | Tool_calls` 的并集类型，导致数据丢失（真实 LLM 可同时返回两者）、验证复杂、扩展困难。

### 2.4 Agent 类型定义 (Agent.t) — **[P0-3 修复]**

Agent 是 P-A-R 的核心执行单元。原设计引用 14+ 次但从未定义。

```ocaml
(* 模型配置 *)
type model_config = {
  provider : [ `Openai | `Anthropic | `Ollama | `Custom of string ];
  model_name : string;
  api_base : string option;          (* override default endpoint *)
  temperature : float;               (* 0.0 - 2.0 *)
  max_tokens : int option;           (* None = provider default *)
  top_p : float option;
  stop_sequences : string list option;
}
[@@deriving yojson]

(* 工具权限级别 *)
type tool_permission =
  | Allow                            (* always allowed *)
  | Confirm                          (* require user confirmation *)
  | Deny                             (* always denied *)
  | Role_based of { allowed_roles : string list }
  | Condition_based of expression    (* evaluate condition *)
[@@deriving yojson]

(* 工具绑定 — 链接 schema 和 handler *)
type tool_binding = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;      (* JSON Schema for parameters *)
  handler : Yojson.Safe.t -> cancellation_token -> handler_result;
  permission : tool_permission;
  timeout : float option;            (* per-tool timeout in seconds *)
  concurrency_limit : int option;    (* max parallel invocations *)
}
(* Note: handler is function type, not derivable *)

(* 中间件钩子 — 在关键生命周期点注入逻辑 *)
type middleware_hook = {
  name : string;
  on_before_llm : (conversation -> conversation option) option;
  on_after_llm : (llm_response -> llm_response option) option;
  on_before_tool : (tool_call -> tool_call option) option;
  on_after_tool : (tool_call * handler_result -> handler_result option) option;
  on_error : (error_category -> handler_result option) option;
}

(* 上下文管理策略 — full definition in §8.3 *)
type context_strategy =
  | Truncate_oldest of { keep_system : bool; min_messages : int }
  | Summarize of { max_tokens : int; summary_model : model_config option }
  | Sliding_window of { max_messages : int; max_tokens : int }
[@@deriving yojson]

(* Agent 配置 — 完整定义 *)
type agent_config = {
  id : string;
  system_prompt : string;
  model : model_config;
  tools : tool_binding list;
  max_iterations : int;              (* max ReAct loop iterations *)
  middleware : middleware_hook list;
  retry_policy : retry_policy option;
  context_strategy : context_strategy option;
  resource_quota : resource_quota option;
}
```

### 2.5 重试策略 (retry_policy) — **[P2-2 修复]**

```ocaml
(* 可重试的错误条件 — ADT 防止字符串匹配错误 *)
type retryable_condition =
  | Timeout
  | Rate_limited
  | External_failure
  | Connection_error
  | Any_retryable
[@@deriving yojson]

(* 退避策略 *)
type backoff_strategy =
  | Exponential of { base : float; max_delay : float }
  | Fixed of float
  | Linear of { increment : float; max_delay : float }
[@@deriving yojson]

(* 完整重试策略 *)
type retry_policy = {
  max_attempts : int;               (* including first attempt *)
  initial_delay : float;            (* seconds before first retry *)
  backoff : backoff_strategy;
  retry_on : retryable_condition list;  (* ADT, not string *)
  jitter : float option;            (* 0.0-1.0, prevents thundering herd *)
}
[@@deriving yojson]
```

**修复说明**：原设计使用 `retry_on : string list`，字符串拼写错误导致静默失败且无法编译期穷举。

### 2.6 任务状态机 (task_status) — **[P0-5 + P2-3 修复]**

```ocaml
(* 任务状态 — Waiting/Paused 语义分离 *)
type task_status =
  | Pending           (* created, not yet scheduled *)
  | Scheduled         (* ready to run, waiting for worker *)
  | Running           (* actively processing *)
  | Waiting_input     (* blocked on external input: human approval, API callback *)
  | Suspended         (* paused by user/system, not waiting on anything *)
  | Completed         (* terminal: finished successfully *)
  | Failed            (* terminal: unrecoverable error *)
  | Cancelled         (* terminal: cancelled by user or system *)
[@@deriving yojson]

type task_type =
  | Agent_call
  | Tool_call
  | Human_approval
  | Workflow
[@@deriving yojson]
```

**状态语义说明**：

| 状态 | 含义 | 典型场景 |
|------|------|----------|
| `Pending` | 等待调度 | 任务刚创建，依赖未满足 |
| `Scheduled` | 就绪待执行 | 依赖已满足，等待工作线程 |
| `Running` | 执行中 | 正在运行 |
| `Waiting_input` | 等待外部输入 | 人工审批、API 回调 |
| `Suspended` | 暂停 | 用户主动暂停，可恢复 |
| `Completed` | 成功结束 | 终端状态 |
| `Failed` | 失败结束 | 终端状态 |
| `Cancelled` | 已取消 | 终端状态 |

**合法状态转换表**（✓ = 允许，✗ = 禁止）：

```
从 \ 到         | Pend | Sched | Run  | Wait | Susp | Done | Fail | Cancel
----------------|------|-------|------|------|------|------|------|-------
Pending         |  ✗   |   ✓   |  ✗   |  ✗   |  ✗   |  ✗   |  ✗   |  ✓
Scheduled       |  ✗   |   ✗   |  ✓   |  ✗   |  ✗   |  ✗   |  ✗   |  ✓
Running         |  ✗   |   ✗   |  ✗   |  ✓   |  ✓   |  ✓   |  ✓   |  ✓
Waiting_input   |  ✗   |   ✗   |  ✓   |  ✗   |  ✗   |  ✓   |  ✓   |  ✓
Suspended       |  ✗   |   ✓   |  ✓   |  ✗   |  ✗   |  ✓   |  ✓   |  ✓
Completed       |  ✗   |   ✗   |  ✗   |  ✗   |  ✗   |  ✗   |  ✗   |  ✗
Failed          |  ✗   |   ✗   |  ✗   |  ✗   |  ✗   |  ✗   |  ✗   |  ✗
Cancelled       |  ✗   |   ✗   |  ✗   |  ✗   |  ✗   |  ✗   |  ✗   |  ✗
```

```ocaml
val validate_transition : task_status -> task_status -> (unit, string) result
```

### 2.7 取消协议 (cancellation_token) — **[P0-4 修复]**

Eio 使用协作式取消。长时间运行的工具处理器必须定期检查取消请求。

```ocaml
type cancellation_token

val create_token : Eio.Switch.t -> cancellation_token
(* Token bound to Switch lifecycle — auto-cancelled when Switch closes *)

val is_cancelled : cancellation_token -> bool
val check_cancel : cancellation_token -> unit
(* Raises Eio.Cancelled if cancellation requested *)

val with_timeout :
  float ->                           (* timeout in seconds *)
  cancellation_token ->
  (cancellation_token -> 'a) ->
  ('a, [> `Timeout | `Cancelled ]) result

val cancellable_handler :
  cancellation_token ->
  float ->                           (* check interval in seconds *)
  (Yojson.Safe.t -> handler_result) ->
  (Yojson.Safe.t -> handler_result)
(* Wraps handler to periodically check_cancel *)
```

**三层取消层次**：

```
Engine cancel → cancels all task fibers
  └── Task cancel → cancels tool calls within task
        └── Tool-level timeout → cancel single tool call, not parent
```

### 2.8 服务注册表 (service_registry) — **[P0-6 修复]**

工具不应直接依赖具体基础设施。通过抽象接口解耦。

```ocaml
(* LLM service — closures bundled in record for yojson deriving *)
type llm_service = {
  complete_fn : model_config -> conversation -> (llm_response, error_category) result;
  stream_fn : model_config -> conversation -> (llm_response_chunk -> unit) -> (stream_complete, error_category) result;
  close_fn : unit -> unit;
}

module type PERSISTENCE_SERVICE = sig
  type t
  val save_events : t -> event list -> (unit, error_category) result
  val load_events : t -> Task_id.t -> (event list, error_category) result
  val save_task_state : t -> task_state -> (unit, error_category) result
  val load_task_state : t -> Task_id.t -> (task_state option, error_category) result
  val transaction : t -> (t -> 'a) -> ('a, error_category) result
end

(* LLM_SERVICE — defined in §8.1 with full streaming support *)
module type LLM_SERVICE = sig
  type t
  val complete :
    t -> model_config -> conversation ->
    (llm_response, error_category) result
  val stream :
    t -> model_config -> conversation ->
    (llm_response_chunk -> unit) ->
    (stream_complete, error_category) result
  val close : t -> unit
end

module type EVENT_BUS_SERVICE = sig
  type t
  type subscription                    (* opaque handle for unsubscribe *)
  val publish : t -> event -> unit
  val subscribe : t -> (event -> unit) -> subscription
  val unsubscribe : t -> subscription -> unit
end

type runtime_config  (* forward declaration — defined in §9.1 *)

type service_registry = {
  persistence : (module PERSISTENCE_SERVICE);
  llm : llm_service;
  event_bus : (module EVENT_BUS_SERVICE);
  config : runtime_config;
}
```

**设计说明**：
- `PERSISTENCE_SERVICE`、`LLM_SERVICE`、`EVENT_BUS_SERVICE` 不再携带类型参数，简化模块签名
- `llm` 字段改为 `llm_service` record 类型，将操作函数闭包化，便于 `yojson` 派生
- 原设计 `runtime_context = { db_conn : Caqti_eio.connection option; ... }` 导致工具直接操作 DB、测试困难、实现锁定。新设计通过模块类型约束，工具仅获得所需服务接口

### 2.9 任务类型 (Task.t)

```ocaml
type task_input =
  | Agent_input of { agent_id : string; message : string }
  | Tool_input of { tool_name : string; arguments : Yojson.Safe.t }
  | Approval_input of { prompt : string; timeout : float; allowed_roles : string list }
  | Workflow_input of { workflow_id : string; variables : (string * Yojson.Safe.t) list }

type task_state = {
  id : Task_id.t;
  input : task_input;
  status : task_status;
  parent_id : Task_id.t option;
  workflow_run_id : Workflow_run_id.t option;
  priority : int;                    (* 0 = highest *)
  schedule : [ `At of Time.t | `Delay of float ] option;
  timeout : float;
  retry_policy : retry_policy option;
  retry_count : int;
  dependencies : Task_id.t list;
  depend_mode : [ `All_success | `Any_success | `All_complete ];
  created_at : Time.t;
  updated_at : Time.t;
  output : Yojson.Safe.t option;
  error : error_category option;
}
[@@deriving yojson]
```

**依赖模式语义**：

| 模式 | 行为 | 适用场景 |
|------|------|----------|
| `All_success` | 所有依赖必须成功 | 关键路径执行 |
| `Any_success` | 至少一个依赖成功 | 后备方案、降级处理 |
| `All_complete` | 所有依赖完成（不论成败） | 清理任务、通知任务 |

---

## 3. 核心引擎设计

### 3.1 对话类型 (conversation)

```ocaml
type message_role = System | User | Assistant | Tool
[@@deriving yojson]

type message = {
  role : message_role;
  content : string option;
  tool_calls : tool_call list option;
  tool_call_id : string option;      (* for Tool role messages *)
  name : string option;              (* tool name for Tool role *)
}
[@@deriving yojson]

type conversation = {
  messages : message list;
  metadata : (string * Yojson.Safe.t) list;
}
```

### 3.2 中间件链 (middleware_chain)

采用**俄罗斯套娃（Russian Doll）组合模式**：每个中间件接收值和 `next` 函数，可选择修改值后传递、直接短路返回、或透传。

```ocaml
val apply_before_llm :
  middleware_hook list -> conversation ->
  (conversation -> llm_response) ->
  llm_response

val apply_after_llm :
  middleware_hook list -> llm_response ->
  (llm_response -> llm_response) ->
  llm_response

val apply_before_tool :
  middleware_hook list -> tool_call ->
  (tool_call -> handler_result) ->
  handler_result

val apply_after_tool :
  middleware_hook list -> tool_call * handler_result ->
  (tool_call * handler_result -> handler_result) ->
  handler_result

val apply_on_error :
  middleware_hook list -> error_category ->
  (error_category -> handler_result) ->
  handler_result
```

**组合规则**：遍历中间件列表 → 检查是否实现对应回调 → `Some value` 替换继续 → `None` 跳过 → 最终调用 `next`。

### 3.3 工具管线 (tool_pipeline)

```
执行流程：
1. Look up tool_binding by name from agent's tools list
2. Validate input against tool's input_schema (JSON Schema)
3. Apply before_tool middleware chain
4. Check tool_permission — if Confirm, emit event and wait for approval
5. Execute handler with cancellable_handler wrapper
6. Apply after_tool middleware chain
7. Return handler_result
```

```ocaml
val execute_tool :
  cancellation_token ->
  tool_binding ->
  Yojson.Safe.t ->                   (* input arguments *)
  middleware_hook list ->
  handler_result
```

**错误处理规范**：

| 场景 | 错误类别 | 可重试 |
|------|---------|--------|
| 工具未找到 | `Invalid_input` | false |
| 参数校验失败 | `Invalid_input` | false |
| 权限拒绝 | `Permission_denied` | false |
| 执行超时 | `Timeout` | true |
| 处理器异常 | `Internal` | false |

### 3.4 Agent 执行器 (agent_executor)

ReAct 循环：

```
1. Create conversation with system_prompt
2. Add user message
3. Apply context_strategy if defined
4. Loop (max max_iterations):
   a. check_cancel (cancellation_token)
   b. Apply before_llm middleware
   c. Call LLM_SERVICE.complete
   d. Apply after_llm middleware
   e. If response has tool_calls:
      - Execute each via execute_tool (with semaphore)
      - Convert results to Tool-role messages
      - Continue loop
   f. If text only (no tool_calls): return as final answer
   g. If finish_reason = Max_tokens: apply context_strategy, retry once
   h. On error: apply on_error middleware, retry if retryable
5. If max_iterations reached: return Error Max_iterations_exceeded
```

```ocaml
val run_agent :
  cancellation_token ->
  agent_config ->
  string ->                           (* user message *)
  llm_service ->
  (llm_response, error_category) result
```

### 3.5 状态机引擎 (state_machine)

```ocaml
val transition :
  (module PERSISTENCE_SERVICE) ->
  task_state -> task_status ->
  (task_state, string) result
(* Validates transition, then persists atomically in transaction *)

val apply_retry :
  task_state -> retry_policy ->
  (task_state, [> `Max_retries_exceeded | `Not_retryable ]) result
(* Checks retry_count < max_attempts, increments, calculates backoff with jitter *)
```

---

## 4. 并发模型

### 4.1 结构化并发

所有并发基于 Eio 结构化并发，通过 Switch 管理纤程生命周期。

**三层层级**：

```
Engine (root Switch)
 └── Task (per-task Switch)
      └── Tool call (individual fibers)
```

取消传播：Switch 关闭 → 级联取消所有子 fiber。

### 4.2 资源配额 (resource_quota) — **[P1-5]**

```ocaml
type resource_quota = {
  max_concurrent_tasks : int;         (* global limit *)
  max_concurrent_tools_per_agent : int;
  max_tokens_per_turn : int option;
  max_total_tokens : int option;      (* lifetime budget *)
}
[@@deriving yojson]
```

- **全局任务并发**：`Eio.Semaphore` 实现 `max_concurrent_tasks`
- **Agent 级工具并发**：每个 agent 独立信号量
- **Token 预算**：累积 `usage_stats`，超预算则拒绝

### 4.3 共享状态安全 — **[P1-7]**

OCaml 的 `Hashtbl` 不是 fiber 安全的。所有共享可变状态必须通过互斥锁保护。

```ocaml
type protected_hashtbl ('k, 'v) = {
  data : ('k, 'v) Hashtbl.t;
  mutex : Eio.Mutex.t;
}

val htbl_get : protected_hashtbl -> 'k -> 'v option
val htbl_set : protected_hashtbl -> 'k -> 'v -> unit
val htbl_remove : protected_hashtbl -> 'k -> unit
val htbl_iter : protected_hashtbl -> ('k -> 'v -> unit) -> unit
```

### 4.4 Eio.Condition 正确用法 — **[P1-3]**

```ocaml
(* ALWAYS use while-loop guard to handle spurious wakeups *)
let await_condition cond mutex predicate =
  Eio.Mutex.use_ro mutex (fun () ->
    while not (predicate ()) do
      Eio.Condition.await cond mutex
    done
  )
```

---

## 5. 优雅关闭 — **[P1-4 新增]**

```
Shutdown phases (triggered by SIGTERM or Runtime.shutdown):

Phase 1 — 停止接收: Close task submission queue
Phase 2 — 排空任务: Wait for in-flight tasks (configurable timeout, default: 30s)
Phase 3 — 取消残留: Cooperatively cancel remaining fibers (5s grace period)
Phase 4 — 持久化:   Flush event bus buffer, snapshot non-terminal task states
Phase 5 — 释放资源: Close DB connections, HTTP pools, file handles
Phase 6 — 退出:     Return exit code (0=clean, 1=forced, 2=error)
```

```ocaml
type shutdown_config = {
  drain_timeout : float;
  cancel_grace_period : float;
  flush_batch_size : int;
}

val graceful_shutdown : runtime -> shutdown_config -> int
```

---

## 6. 事件系统

### 6.1 事件类型

```ocaml
type event_metadata = {
  trace_id : string option;
  span_id : string option;
  timestamp : float;                   (* Unix timestamp, ms *)
  source : string;
}
[@@deriving yojson]

type event =
  | Task_created of { task_id : Task_id.t; task_type : string; priority : int }
  | Task_started of { task_id : Task_id.t }
  | Task_completed of { task_id : Task_id.t; duration_ms : float }
  | Task_failed of { task_id : Task_id.t; error : error_category }
  | Task_cancelled of { task_id : Task_id.t; reason : string }
  | Task_suspended of { task_id : Task_id.t }
  | Task_resumed of { task_id : Task_id.t }
  | Llm_request_sent of { task_id : Task_id.t; model : string }
  | Llm_response_received of { task_id : Task_id.t; usage : usage_stats }
  | Tool_invoked of { task_id : Task_id.t; tool_name : string }
  | Tool_completed of { task_id : Task_id.t; tool_name : string; duration_ms : float }
  | Tool_failed of { task_id : Task_id.t; tool_name : string; error : error_category }
  | Workflow_started of { workflow_run_id : Workflow_run_id.t }
  | Workflow_step_completed of { step_id : string }
  | Workflow_completed of { workflow_run_id : Workflow_run_id.t }
  | Workflow_failed of { workflow_run_id : Workflow_run_id.t; error : error_category }
  | Approval_requested of { prompt : string; allowed_roles : string list }
  | Approval_granted of { approver : string }
  | Approval_timeout
  | Shutdown_initiated
  | Shutdown_completed of { exit_code : int }
[@@deriving yojson]

type event_envelope = {
  id : string;                       (* UUIDv7 *)
  metadata : event_metadata;
  payload : event;
  idempotency_key : string;
  delivery_attempt : int;
}
[@@deriving yojson]
```

### 6.2 事件总线协议 — **[P1-1]**

```ocaml
type event_delivery_config = {
  max_delivery_attempts : int;        (* default: 5 *)
  initial_retry_delay : float;        (* seconds, default: 1.0 *)
  retry_backoff : backoff_strategy;
  delivery_timeout : float;           (* seconds, default: 30 *)
}

type dead_letter_entry = {
  envelope : event_envelope;
  error : string;
  failure_reason : error_category;
  failed_at : float;
  attempt_count : int;
}

type event_bus_config = {
  buffer_capacity : int;              (* default: 10000 *)
  delivery : event_delivery_config;
  dlq_enabled : bool;
  critical_event_types : string list; (* never dropped when buffer full *)
}
```

| 特性 | 实现 |
|------|------|
| **At-least-once** | 事件先持久化到 events 表，再投递 |
| **幂等性** | `idempotency_key` 去重 |
| **死信队列** | 超过 `max_delivery_attempts` 后写入 `dead_letters` 表 |
| **任务内有序** | 同一 `task_id` 按 timestamp 全序 |
| **背压** | buffer >80% → 丢弃非 critical；buffer 满 → block producer |

### 6.3 OpenTelemetry 集成

- 每个 task 执行 → root span `task.execute`
- LLM 调用 → child span `llm.call`（model, tokens, latency）
- 工具执行 → child span `tool.execute`（tool_name, duration）
- Span context 通过 `event_metadata.trace_id/span_id` 传播
- 导出 via OTLP 到 Jaeger/Tempo

---

## 7. 持久化设计 — **[P1-6]**

### 7.1 双策略

| 场景 | 策略 | 说明 |
|------|------|------|
| dev/test | SQLite 单写者 | 零配置，所有写操作经单一 fiber 串行化 |
| production | PostgreSQL | 并发写入，事务隔离，JSONB 索引 |

### 7.2 数据库表结构

```sql
CREATE TABLE tasks (
  id              TEXT PRIMARY KEY,
  status          TEXT NOT NULL,
  task_type       TEXT NOT NULL,
  agent_id        TEXT,
  priority        INTEGER DEFAULT 0,
  workflow_run_id TEXT,
  parent_id       TEXT,
  created_at      REAL NOT NULL,
  updated_at      REAL NOT NULL,
  scheduled_at    REAL,
  timeout_at      REAL,
  data            JSONB NOT NULL DEFAULT '{}',
  FOREIGN KEY (workflow_run_id) REFERENCES workflows(id)
);

CREATE INDEX idx_tasks_status ON tasks(status)
  WHERE status IN ('scheduled', 'running', 'waiting_input');
CREATE INDEX idx_tasks_workflow ON tasks(workflow_run_id);
CREATE INDEX idx_tasks_priority ON tasks(priority, created_at)
  WHERE status = 'scheduled';

CREATE TABLE workflows (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  status          TEXT NOT NULL,
  definition      JSONB NOT NULL,
  variables       JSONB,
  created_at      REAL NOT NULL,
  updated_at      REAL NOT NULL
);

CREATE TABLE events (
  id                TEXT PRIMARY KEY,
  task_id           TEXT,
  event_type        TEXT NOT NULL,
  idempotency_key   TEXT UNIQUE NOT NULL,
  payload           JSONB NOT NULL,
  delivery_status   TEXT DEFAULT 'pending',
  delivery_attempt  INTEGER DEFAULT 0,
  created_at        REAL NOT NULL
);

CREATE INDEX idx_events_task ON events(task_id, created_at);
CREATE INDEX idx_events_undelivered ON events(created_at)
  WHERE delivery_status = 'pending';

CREATE TABLE dead_letters (
  id              TEXT PRIMARY KEY,
  original_event  JSONB NOT NULL,
  error           TEXT,
  attempts        INTEGER NOT NULL,
  failed_at       REAL NOT NULL,
  resolved        BOOLEAN DEFAULT FALSE
);

CREATE TABLE snapshots (
  task_id         TEXT PRIMARY KEY,
  state           JSONB NOT NULL,
  version         INTEGER NOT NULL,
  created_at      REAL NOT NULL
);
```

**提取列 vs JSONB**：`status`、`priority`、`workflow_run_id` 等高频查询字段独立列 + 索引；完整 `task_state` 存 JSONB。两者在同一事务中保持同步。

### 7.3 SQLite 单写者模式

```ocaml
type write_command =
  | Insert_task of task_state
  | Update_task of Task_id.t * task_state
  | Insert_event of event_envelope
  | Flush_batch of event_envelope list

type sqlite_writer = {
  write_queue : write_command Eio.Stream.t;
  fiber : unit;
  db : Caqti_eio.Connection.t;
}
```

所有写操作经 `write_queue` 串行化，Eio.Stream 保证单消费者。

### 7.4 批量事务

```ocaml
type batch_config = {
  batch_size : int;                   (* default: 100 *)
  flush_interval : float;             (* seconds, default: 5.0 *)
}

val flush_events :
  (module PERSISTENCE_SERVICE) ->
  event_envelope list ->
  (unit, error_category) result
```

### 7.5 事件溯源与恢复

- Events 是 source of truth，State 通过 event replay 派生
- 每 N 个事件生成 snapshot（可配置，默认 50）
- 重启恢复：加载最新 snapshot + replay 增量事件
- 事务隔离：PostgreSQL `SERIALIZABLE`，SQLite `IMMEDIATE`

---

## 8. LLM 客户端

### 8.1 Provider 抽象

```ocaml
(* Full LLM_SERVICE definition — canonical version (§2.4 shows abbreviated form for service_registry context) *)
module type LLM_SERVICE = sig
  type t
  val create : llm_provider_config -> (t, error_category) result
  val complete :
    t -> model_config -> conversation ->
    (llm_response, error_category) result
  val stream :
    t -> model_config -> conversation ->
    (llm_response_chunk -> unit) ->
    (stream_complete, error_category) result
  val close : t -> unit
end

type llm_provider_config =
  | Openai of { api_key : string; base_url : string option; organization : string option }
  | Anthropic of { api_key : string; base_url : string option }
  | Ollama of { base_url : string }
  | Custom of { base_url : string; headers : (string * string) list;
                request_format : [ `Openai_compatible | `Anthropic_compatible ] }
```

### 8.2 流式传输 — **[P2-5 完整设计]**

```ocaml
type llm_response_chunk =
  | Text_delta of { text : string }
  | Tool_call_start of { tool_call_id : string; name : string }
  | Tool_call_delta of { tool_call_id : string; args_json : string }
  | Usage_update of usage_stats
  | Done of { finish_reason : finish_reason }
[@@deriving yojson]

type stream_config = {
  chunk_timeout : float;              (* max seconds between chunks *)
  total_timeout : float option;       (* max total stream duration *)
  buffer_size : int;                  (* internal buffer for backpressure *)
}

type stream_complete = {
  final_usage : usage_stats;
  finish_reason : finish_reason;
  chunks_received : int;
}
```

**Callback-based 设计**：

```
Producer (LLM API) ──chunk──► Callback ──► Consumer
```

- Producer 推送 chunk，Consumer 通过 callback 即时处理
- 背压：callback 阻塞时 producer 暂停（TCP 层流控）
- `chunk_timeout`：两个 chunk 间超时则终止
- Middleware 集成：`on_after_llm` 收到累积的 `llm_response`，非单个 chunk

### 8.3 上下文窗口管理 — **[P2-6]**

```ocaml
(* context_strategy defined in §2.4 — referenced here for apply_context_strategy *)

val apply_context_strategy :
  context_strategy ->
  token_counter:(conversation -> int) ->
  conversation ->
  (conversation, error_category) result
```

Token 计数：Provider 专用 tokenizer（tiktoken for OpenAI），近似 fallback `chars / 4`。策略在 ReAct 循环中**每次 LLM 调用前**执行。

---

## 9. SDK 设计

### 9.1 Runtime 初始化

```ocaml
type runtime_config = {
  persistence : [ `Sqlite of string | `Postgresql of string ];
  event_bus : event_bus_config;
  default_quota : resource_quota;
  shutdown : shutdown_config;
  llm_providers : (string * llm_provider_config) list;
}

type runtime  (* opaque handle *)

val create :
  config:runtime_config ->
  ?persistence:(module PERSISTENCE_SERVICE) ->
  ?event_bus:(module EVENT_BUS_SERVICE) ->
  (runtime, error_category) result
val close : runtime -> int
```

内部结构（不对外暴露）：

```ocaml
type event_bus_impl                     (* internal event bus state *)

type runtime_impl = {
  agents : (string, agent_config) protected_hashtbl;
  services : service_registry;
  cancellation_root : Eio.Switch.t;
  event_bus : event_bus_impl;
  task_semaphore : Eio.Semaphore.t;
  shutdown_requested : bool Eio.Atomic.t;
}
```

### 9.2 Agent 注册与执行

```ocaml
val register_agent : runtime -> agent_config -> (unit, error_category) result

val register_tool :
  runtime -> name:string -> description:string -> input_schema:Yojson.Safe.t ->
  handler:(Yojson.Safe.t -> cancellation_token -> handler_result) ->
  ?permission:tool_permission -> ?timeout:float -> ?concurrency_limit:int ->
  unit -> tool_binding

val invoke :
  runtime -> agent_id:string -> message:string ->
  ?cancellation_token:cancellation_token ->
  (llm_response, error_category) result
```

### 9.3 Task 管理

```ocaml
val submit_task : runtime -> task_input -> ?priority:int -> ?timeout:float ->
  Task_id.t

val wait_for_task : runtime -> Task_id.t -> timeout:float ->
  (Yojson.Safe.t option, [> `Timeout | `Task_failed of error_category ]) result

val get_task_status : runtime -> Task_id.t -> (task_status option, error_category) result
val cancel_task : runtime -> Task_id.t -> (unit, error_category) result
val approve_task : runtime -> Task_id.t -> approver:string -> (unit, error_category) result
val stream_events : runtime -> ?task_id:Task_id.t -> unit -> event_envelope Eio.Stream.t
```

### 9.4 Workflow 提交

```ocaml
val submit_workflow : runtime -> workflow ->
  (Workflow_run_id.t, error_category) result
val get_workflow_status : runtime -> Workflow_run_id.t ->
  (workflow_status, error_category) result
val cancel_workflow : runtime -> Workflow_run_id.t -> (unit, error_category) result
```

---

## 10. 中间件系统 — **[P2-4 修复]**

### 10.1 中间件组合

所有 hooks 为 `option` — 中间件只实现所需部分。

```ocaml
type middleware_hook = {
  name : string;
  on_before_llm : (conversation -> conversation option) option;
  on_after_llm : (llm_response -> llm_response option) option;
  on_before_tool : (tool_call -> tool_call option) option;
  on_after_tool : (tool_call * handler_result -> handler_result option) option;
  on_error : (error_category -> handler_result option) option;
}

val compose_middleware : middleware_hook list -> middleware_stack
(* middleware_stack is opaque — composed chain of hooks ready for execution *)
type middleware_stack
(* First in list = outermost (runs first on input, last on output) *)
```

### 10.2 默认中间件集合

| 中间件 | Hook | 功能 |
|--------|------|------|
| **LoggingMiddleware** | before_llm, after_tool | 日志请求/响应摘要，发事件到 event_bus，不修改数据 |
| **TimeoutMiddleware** | before_llm, before_tool | 包装 `with_timeout`，超时返回 `Error Timeout` |
| **RetryMiddleware** | on_error | 检查 `retryable_condition`，可重试则交给重试逻辑 |
| **RateLimitMiddleware** | before_llm | 令牌桶限流（rate + burst） |
| **PiiMaskMiddleware** | before_llm | 正则脱敏邮箱/电话/信用卡，可选可逆加密 |
| **ValidationMiddleware** | after_llm | 反思修复或多模型共识（见下方） |

**ReflectionRepair**：

```ocaml
type reflection_config = {
  critic_model : model_config;
  quality_threshold : float;          (* 0.0 - 1.0 *)
  max_repair_attempts : int;
  degradation_strategy : [ `Best_effort | `Fail ];
}
```

1. Agent 输出后，调用 critic 评估质量
2. 分数 < 阈值 → 注入反馈，递归重跑 Agent（最多 N 次）
3. 达到上限：`Best_effort` 返回最佳输出，`Fail` 返回错误

**MultiModelConsensus**：

```ocaml
type consensus_config = {
  models : model_config list;
  strategy : [ `Majority_vote | `Best_of_n of { critic : model_config } ];
  agreement_threshold : float;
  disagreement_action : [ `Retry | `Pause_for_human ];
}
```

1. 并行发送相同 prompt 到所有模型（`Eio.Fiber.all`）
2. MajorityVote：嵌入相似度聚类，选最大簇
3. BestOfN：critic 评分，返回最高分
4. 无法共识：重试或暂停等人工

---

## 11. 工作流引擎 — **[P1-2]**

### 11.1 工作流定义

```ocaml
type workflow_step =
  | Agent_call of { agent_id : string; prompt_template : string }
  | Tool_call of { tool_name : string; input : Yojson.Safe.t }
  | Parallel of workflow_step list
  | Sequential of workflow_step list
  | Conditional of { condition : expression; then_step : workflow_step;
                     else_step : workflow_step option }
  | Map_reduce of { over : string; step : workflow_step;
                    reduce : [ `Collect_all | `First_success | `Majority ] }
  | Human_approval of { prompt_template : string; timeout : float;
                        allowed_roles : string list }
  | Sub_workflow of { workflow_id : string; variables : (string * Yojson.Safe.t) list }
[@@deriving yojson]

type failure_policy =
  | Fail_fast
  | Continue_on_failure
  | Conditional of { on_failure : workflow_step }
[@@deriving yojson]

type workflow = {
  id : string;
  name : string;
  version : int;
  steps : workflow_step;
  variables : (string * Yojson.Safe.t) list;
  failure_policy : failure_policy;
  parallel_limit : int;
  timeout : float;
  on_complete : (workflow_result -> unit) option;
}

and workflow_status =
  | Wf_pending
  | Wf_running
  | Wf_suspended                     (* waiting on human approval *)
  | Wf_completed of workflow_result
  | Wf_failed of error_category

and workflow_result = {
  outputs : (string * Yojson.Safe.t) list;  (* collected step outputs *)
  status : [ `Success | `Partial | `Failed ];
  elapsed : float;
  metadata : (string * string) list;
}
[@@deriving yojson]

type task_completion = {
  task_id : Task_id.t;
  result : (Yojson.Safe.t, error_category) result;
  elapsed : float;
}
```

`prompt_template` 使用 `{{variable}}` 语法引用变量。

### 11.2 事件驱动调度器 — **[P1-2 修复]**

**非轮询**。事件驱动 + Condition：

```
1. Scheduler fiber listens on task_completion_stream
2. When a task completes:
   a. Find downstream tasks depending on this one
   b. Check if ALL dependencies satisfied
   c. If satisfied → mark Scheduled, signal Condition
3. Dispatcher fiber waits on Condition with predicate "has_schedulable_tasks"
4. Pick up to parallel_limit tasks, start each in own fiber
5. Each task fiber signals completion back to scheduler
```

```ocaml
type scheduler = {
  pending : (Task_id.t, task_state) protected_hashtbl;
  completion_stream : task_completion Eio.Stream.t;
  condition : Eio.Condition.t;
  mutex : Eio.Mutex.t;
}

val run_workflow :
  runtime -> workflow -> variables:(string * Yojson.Safe.t) list ->
  (Workflow_run_id.t, error_category) result
```

**优势**：O(1) 通知（只检查受影响的下游任务），零轮询延迟。

---

## 12. 条件表达式 — **[P2-7]**

### 12.1 表达式类型（安全求值）

```ocaml
type expression =
  | Literal of Yojson.Safe.t
  | Variable of string                (* e.g., "tasks.t1.output" *)
  | Equals of expression * expression
  | Not_equals of expression * expression
  | Greater_than of expression * expression
  | Less_than of expression * expression
  | And of expression * expression
  | Or of expression * expression
  | Not of expression
  | Contains of expression * expression
  | Is_null of expression
  | Is_empty of expression
  | Has_key of expression * string
[@@deriving yojson]
```

**安全约束**：无任意代码执行，无字符串插值，无函数调用。变量白名单：`tasks.{id}.output`、`variables.{name}`、`config.{key}`。最大嵌套深度 10。类型不匹配返回 false（永不崩溃）。

```ocaml
type eval_context = {
  task_outputs : (Task_id.t * Yojson.Safe.t) list;
  variables : (string * Yojson.Safe.t) list;
}

val eval : expression -> eval_context -> (bool, string) result
```

### 12.2 表达式解析器

字符串语法用于 YAML/JSON 工作流定义：`"tasks.t1.output.score > 0.8"`

递归下降解析器，限制：max 100 tokens，max depth 10。支持 `==`、`!=`、`>`、`<`、`>=`、`<=`、`&&`、`||`、`!`、`contains`、`is_null`、`is_empty`、`has_key`。

---

## 13. 安全性 — **[P1-8]**

### 13.1 Human Approval 安全

```ocaml
type approval_config = {
  timeout : float;                    (* default: 3600s *)
  allowed_roles : string list;
  max_pending_age : float;            (* auto-reject, default: 86400s *)
  audit_log : bool;
}

val request_approval :
  runtime -> task_id:Task_id.t -> prompt:string -> approval_config ->
  (unit, error_category) result
```

流程：Task → `Waiting_input` → 发 `Approval_requested` 事件 → 外部 UI 呈现 → 用户批准 → 恢复 / 超时 → 失败。

### 13.2 工具权限模型

权限检查在 tool_pipeline 中、handler 执行前：

- `Allow`：立即执行
- `Deny`：返回 `Permission_denied`
- `Confirm`：暂停，发确认事件，等外部批准
- `Role_based`：检查调用者角色
- `Condition_based`：求值表达式

### 13.3 敏感数据保护

- API 密钥：环境变量/加密配置注入，绝不存 DB
- LLM 调用：始终 HTTPS（tls-eio）
- PII：PiiMaskMiddleware 可选脱敏
- 审计：所有审批/权限决策记为事件
- 密钥轮换：Provider 配置支持无重启轮换

### 13.4 LLM 安全防护（审查加固）

- **Prompt 注入防御**：工具输出在注入 LLM context 前必须经过 `sanitize_tool_output` 清洗（移除 `system:` 前缀注入、越狱模式检测）
- **表达式求值资源限制**：`expression` evaluator 强制 `max_depth=10`，`max_node_visits=1000`，超限返回 `Error (Resource_limit, ...)` 而非挂起
- **事件总线重放防护**：`subscribe` 注册时记录 `subscription_id + nonce`，`publish` 仅广播到已验证订阅者，防止伪造事件注入

---

## 14. 项目结构

```
par/
├── dune-project
├── par.opam
├── lib/
│   ├── par_core/                     (* core types, engine, SDK *)
│   │   ├── dune
│   │   ├── types.ml / .mli
│   │   ├── engine.ml / .mli
│   │   ├── state_machine.ml / .mli
│   │   ├── cancellation.ml / .mli
│   │   ├── runtime.ml / .mli
│   │   └── expression.ml / .mli
│   ├── par_eio/                      (* Eio-specific concurrency *)
│   │   ├── dune
│   │   ├── concurrency.ml / .mli
│   │   ├── event_bus.ml / .mli
│   │   └── graceful_shutdown.ml / .mli
│   ├── par_sqlite/
│   │   └── sqlite_persistence.ml / .mli
│   ├── par_postgres/
│   │   └── postgres_persistence.ml / .mli
│   ├── par_openai/
│   │   └── openai_provider.ml / .mli
│   ├── par_anthropic/
│   │   └── anthropic_provider.ml / .mli
│   ├── par_middleware/
│   │   ├── logging.ml
│   │   ├── timeout.ml
│   │   ├── retry.ml
│   │   ├── rate_limit.ml
│   │   ├── pii_mask.ml
│   │   └── validation.ml
│   └── par_cli/
│       └── main.ml
├── test/
│   ├── unit/
│   │   ├── test_types.ml
│   │   ├── test_state_machine.ml
│   │   ├── test_expression.ml
│   │   ├── test_middleware.ml
│   │   └── test_concurrency.ml
│   ├── integration/
│   │   ├── test_agent_loop.ml
│   │   ├── test_tool_pipeline.ml
│   │   ├── test_workflow.ml
│   │   └── test_event_bus.ml
│   └── e2e/
│       └── test_full_workflow.ml
├── schema/
│   ├── sqlite.sql
│   └── postgresql.sql
└── examples/
    ├── basic_agent.ml
    ├── tool_use.ml
    └── workflow.ml
```

---

## 15. 测试策略

| 层级 | 工具 | 范围 | 策略 |
|------|------|------|------|
| 单元测试 | ounit2 | 类型验证、状态机、表达式、中间件、并发原语 | 每个公共函数 ≥1 测试 |
| 集成测试 | tezt + mock LLM | Agent 循环、工具管线、工作流、持久化恢复 | 端到端路径覆盖 |
| 并发测试 | tezt + fiber | 取消传播、超时、配额、虚假唤醒、死锁 | 1000 并发 fiber 压力测试 |
| 属性测试 | qcheck | 状态机不变量、事件排序、序列化往返 | 10000 次随机输入 |
| E2E 测试 | tezt + 真实 LLM | 完整工作流 + 校验 | 可选，CI 标记 `slow` |

**覆盖率目标：≥80%**

---

## 16. 开发路线

| 里程碑 | 内容 | 依赖 |
|--------|------|------|
| M1 | 核心类型 + 状态机 + 取消协议 | base, yojson, eio |
| M2 | 引擎骨架 + Mock LLM | M1 |
| M3 | 工具管线 + 中间件链 | M1, M2 |
| M4 | 事件系统 + SQLite 持久化 | M1 |
| M5 | SDK 公共 API | M1–M4 |
| M6 | OpenAI + Anthropic Provider | M2, M3 |
| M7 | 工作流引擎 + 调度器 | M1–M5 |
| M8 | 默认中间件集合 | M3 |
| M9 | Streaming + 上下文管理 | M6 |
| M10 | CLI 工具 + Examples | M5, M7 |
| M11 | PostgreSQL 持久化 | M4 |
| M12 | 测试覆盖率达标 + 文档 | All |

```
M1 → M2 → M3 → M5 → M10
 │         │           ▲
 │         ▼           │
 └→ M4 → M5 ←→ M7 → M10
               ▲
M2,M3 → M6 ───┘

M3 → M8
M6 → M9
M4 → M11
```

---

## 17. 交付物清单

- [ ] `par-core` 库：类型、引擎、SDK
- [ ] `par-eio` 库：并发原语、事件总线、优雅关闭
- [ ] `par-sqlite` 库：SQLite 持久化后端
- [ ] `par-postgres` 库：PostgreSQL 持久化后端
- [ ] `par-openai` 库：OpenAI Provider
- [ ] `par-anthropic` 库：Anthropic Provider
- [ ] `par-middleware` 库：默认中间件集合
- [ ] `par` CLI 工具
- [ ] 所有模块 `.mli` 接口文件
- [ ] 单元测试覆盖率 ≥80%
- [ ] 集成测试覆盖关键路径
- [ ] OpenTelemetry 集成示例
- [ ] 数据库初始化脚本
- [ ] 快速开始指南 README
