# PAR 架构总览
[English](../explanation/architecture.md) · **简体中文**

本文档解释 PAR SDK 的内部结构。面向想理解 PAR 如何工作、或想贡献核心代码的读者。

## 核心抽象

PAR 把 LLM agent 抽象为三层：

```
┌─────────────────────────────────────────────────────────┐
│                      LLM 循环                              │
│  ReAct 循环：观察 → 思考 → 行动 → 观察 → ...              │
│  (lib/core/engine.ml)                                     │
├─────────────────────────────────────────────────────────┤
│  工具调用（types、调度、超时、并发）                       │
│  (lib/tools/builtin_tools.ml)                            │
├─────────────────────────────────────────────────────────┤
│  LLM 通信（OpenAI / Anthropic）                          │
│  (lib/providers/)                                        │
└─────────────────────────────────────────────────────────┘
```

每一层都有自己的类型边界，确保编译期能抓到错误。

## 模块结构

```
lib/
├── core/           类型 + Runtime + Engine + SDK 入口
│   ├── types.ml         所有公共类型（agent_config、tool_descriptor、handler_result、...）
│   ├── runtime.ml       Runtime.create / make_agent / register_tool / invoke
│   ├── engine.ml        ReAct 循环实现
│   ├── sdk.ml           公共 SDK API
│   ├── tool_registry.ml 工具去重注册
│   ├── cancellation.ml  协程取消语义
│   ├── context_manager.ml 对话上下文管理
│   ├── expression.ml    表达式求值（Workflow 用）
│   ├── state_machine.ml  8 状态机
│   └── workflow.ml      Workflow 引擎（sequential / parallel / conditional / map-reduce）
│
├── providers/      LLM provider
│   ├── openai_provider.ml
│   ├── anthropic_provider.ml
│   └── mock_provider.ml  (测试用)
│
├── tools/          内置工具（v0.3.1 起 20 个）
│   ├── builtin_tools.ml
│   ├── bash_safe_command.ml  (v0.3.1 bash ADT)
│   ├── bash_policy.ml        (v0.3.1 安全策略)
│   └── bash_blacklist.ml     (v0.3.1 黑名单)
│
├── persistence/    持久化
│   ├── sqlite_persistence.ml
│   └── postgres_persistence.ml  (独立 opam 包)
│
├── event_bus/      事件总线（带 DLQ）
│
├── middleware/     7 个中间件
│   ├── logging / retry / rate_limit / timeout / validation / pii_mask / sanitize_tool_output
│
├── ffi/            C FFI（par_capi.so + par_ffi.h + par_ffi.c）
│
└── par.ml          公共入口（re-export 所有子模块）
```

## 数据流：一次 invoke

```
用户代码
  │
  ▼
Runtime.invoke agent_id "问题"
  │
  ▼
Engine.execute_ReAct_loop agent conversation
  │
  ▼  ┌─→ LLM Provider (OpenAI / Anthropic) ─→ 网络
  │   │
  │   ◄── LLM 响应（text + tool_calls）
  │
  ├──→ 解析 tool_calls
  │   │
  │   ▼
  │   Tool_registry.invoke tool_name
  │     │
  │     ▼
  │     Tool_handler input token → 输出 / 错误
  │     │
  │     ▼
  │   解析结果，注入到 conversation
  │
  ├──→ 中间件链（logging / retry / rate_limit / ...）
  │
  ▼
返回最终结果（text + tool_calls 历史）
```

## 类型系统：为什么 PAR 更安全

PAR 不用 Python 风格的动态字典，而是用 OCaml 强类型：

- 工具参数类型在**编译期**检查（而非运行时崩溃）
- LLM 响应解析通过模式匹配**强制覆盖**所有分支
- 配置通过 `make_config` 构造器校验（拒绝非法值）
- 重复工具名返回 `Error (\`Duplicate_tool)` 而非静默覆盖

`v0.3.1 bash` 工具是这种"编译期安全"的极致：`command` ADT **没有** `Exec_raw_shell` 构造器，shell 注入在类型层不可表示。

## 并发模型（Eio）

PAR 整个栈在 [Eio](https://github.com/ocaml-multicore/eio) 上运行——OCaml 5 的结构化并发原语。

关键点：
- 每个 Runtime 有一个 `Eio.Switch.t`（cancellation_root）
- `Runtime.close` 触发整个 switch cancel，所有纤程（tool handler、LTM 推理、SSE 流）都被取消
- `cancellation_token` 透传到每个 tool handler，handler 可在 `with_timeout` 内协作式取消
- 超时通过 `Eio.Fiber.first` 实现：`Future.first [| timeout sleep |]`

## 事件流

`Par.Types.event` 是个 open sum type，每个事件是 inline record：

```ocaml
type event =
  | Task_created of { task_id : Task_id.t; task_type : string; priority : int }
  | Task_completed of { task_id : Task_id.t; duration_ms : float }
  | Tool_invoked of { task_id : Task_id.t; tool_name : string }
  | Tool_progress of { task_id : Task_id.t; tool_name : string; message : string }
  | Bash_invoked of { task_id : Task_id.t; argv : string list; risk : string; ... }  (* v0.3.1 *)
  | ...
  [@@deriving yojson]
```

事件由 Runtime 通过 `rt.publish_event_fn` emit，订阅者通过 `Event_bus.subscribe` 接收。v0.3.0 起，事件还会写到 SQLite / Postgres（用于审计 + debug）。

## 下一步

- **新加工具**：看 [docs/sdk/tools.md](../sdk/tools.md) 的 20 个工具，再加一个 `let my_tool = { descriptor; handler } in` 然后 `Runtime.register_tool`。
- **新加 LLM provider**：看 [docs/howto/custom-llm-provider.md](../howto/custom-llm-provider.md)。
- **新加中间件**：看 `lib/middleware/` 的 7 个例子，参考 [docs/sdk/middleware.md](../sdk/middleware.md)。
- **贡献核心代码**：读 `lib/core/types.ml`（所有公共类型），跟着 `lib/core/runtime.ml` 走一遍 Runtime 生命周期。
