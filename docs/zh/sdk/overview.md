# P-A-R SDK 概览

> **v0.6.7 提示：** 本仓库的 CLI（`par_cli` / `par ask` / `par config` / `par`）已移除；SDK（OCaml）与 Python 绑定是受支持的界面。架构图中的 CLI 节点已废弃，保留作为历史参考。需要交互式 Agent 体验请使用 [par-code](https://github.com/jcz2020/par-code)。
[English](../sdk/overview.md) · **简体中文**

P-A-R (Programmable Agent Runtime) 是一个基于 OCaml 5.4+ 的模块化 Agent 运行时，
提供 ReAct 推理循环、工作流编排、持久化状态管理和中间件管道。

## 核心能力

| 能力 | 说明 |
|------|------|
| ReAct Agent 循环 | 思考-行动-观察循环，支持工具调用，可配置最大迭代次数 |
| 工作流引擎 | 顺序、并行、条件分支、Map-Reduce、人工审批、子工作流 |
| 多 Provider 支持 | OpenAI 兼容接口、Anthropic Messages API、Ollama、自定义端点 |
| MCP 客户端 | 连接任意 MCP server（stdio / HTTP/SSE），自动发现工具/资源/提示词 |
| 中间件管道 | 日志、重试、限速、超时、输入校验、PII 掩码、输出清洗 (7 个内置) |
| 持久化 | SQLite（唯一的持久化后端），事件溯源 + 任务状态持久化；Noop 用于测试 |
| FFI / Python 绑定 | C ABI (`par_capi.so`) + ctypes Python 包 (`par_runtime`) |

## 架构

> v0.6.7 后 CLI 层已移除（本仓库纯 SDK）。如需交互式体验，使用独立的 [par-code](https://github.com/jcz2020/par-code) 项目。

```
+-----------------------------------------------------------+
|                       SDK (par)                           |
+----------+----------+----------+----------+--------------+
|  Core    |Providers |Persist   |Event_bus |  Middleware  |
| Types    |OpenAI    |SQLite    |Eio+DLQ   |  Logging     |
| Runtime  |Anthropic |SQLite    |          |  Retry       |
| Engine   |          |          |          |  Rate_limit  |
| Workflow |          |          |          |  Timeout     |
| Expr     |          |          |          |  Validation  |
| State_m  |          |          |          |  Pii_mask    |
+----------+----------+----------+----------+------+-------+
|                   Tools (20 builtin)                     |
|       calculator / web_search / fetch_url / bash ...     |
+----------+-----------------------------------------------+
|  MCP Client (v0.3.1)    |  tools / resources / prompts   |
|  stdio + HTTP/SSE transport  |  server lifecycle management   |
+-----------------------------------------------------------+
|                    FFI Bridge (par_capi)                  |
|         C API (par_ffi.h) -> Python ctypes binding         |
+-----------------------------------------------------------+
```

## 模块组织

| 层 | 模块 | 职责 |
|----|------|------|
| Core | `Par.Types` | 所有核心类型定义：agent_config、model_config、workflow_step、event 等 |
| Core | `Par.Runtime` | 运行时创建、Agent 注册/调用、工具注册、工作流提交 |
| Core | `Par.Engine` | ReAct 循环实现、中间件链组合、工具执行管道 |
| Core | `Par.Workflow_engine` | 工作流执行器：顺序/并行/条件/Map-Reduce/审批/子工作流 |
| Core | `Par.Expression` | 表达式求值器（用于条件分支），支持变量引用和比较运算 |
| Core | `Par.State_machine` | 任务状态机：9 种状态 + 合法转换校验 |
| Core | `Par.Context_manager` | 上下文窗口管理：截断、摘要、滑动窗口 |
| Core | `Par.Cancellation` | 取消令牌：协作式取消、超时包装 |
| Core | `Par.Tool_registry` | 工具处理器注册表（名称 -> handler 映射） |
| Providers | `Par.Openai_provider` | OpenAI Chat Completions API + SSE 流式响应 |
| Providers | `Par.Anthropic_provider` | Anthropic Messages API |
| Providers | `Par.Mock_provider` | 测试用 mock provider |
| Persistence | `Par.Sqlite_persistence` | SQLite 后端（事件 + 任务状态 + 工作流状态） |
| Persistence | `Par.Noop_persistence` | 空操作持久化（用于测试和快速原型） |
| Event_bus | `Par.Event_bus` | Eio 异步事件总线 + 死信队列 |
| Tools | `Par.Builtin_tools` | 20 个内置工具（计算器、时间、UUID、哈希、Web、bash 等） |
| MCP | `Par.Mcp_types` | MCP 协议类型：server_config、capabilities、tool/resource/prompt 类型 |
| MCP | `Par.Mcp_server` | MCP server 生命周期：spawn、stop、call_method、notify |
| MCP | `Par.Mcp_client` | MCP 高阶客户端：connect、list_tools、call_tool、list_resources、read_resource、list_prompts、get_prompt |
| Middleware | `Par.Logging` | 请求/响应日志 |
| Middleware | `Par.Retry` | 指数退避重试 |
| Middleware | `Par.Rate_limit` | 滑动窗口限速 |
| Middleware | `Par.Timeout` | 超时错误转换 |
| Middleware | `Par.Validation` | 输入/输出 JSON 校验 |
| Middleware | `Par.Pii_mask` | PII 数据脱敏 |
| Middleware | `Par.Sanitize_tool_output` | 工具输出注入模式清洗 |

## 快速开始

```ocaml
open Par

let config = {
  persistence = `Sqlite "par.db";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
}

let () = Eio_main.run (fun _env ->
  Eio.Switch.run (fun switch ->
    match Runtime.create ~config switch with
    | Error _ -> Printf.eprintf "Runtime creation failed\n"
    | Ok rt ->
      (* 注册工具、配置 Agent、调用... *)
      ignore (Runtime.close rt)
  )
)
```

## SDK 文档索引

| 文档 | 内容 |
|------|------|
| [Agent API](agent.md) | Agent 配置、运行时创建、工具注册、ReAct 循环 |
| [Workflow API](workflow.md) | 工作流定义、步骤类型、条件分支、审批、检查点 |
| [Middleware API](middleware.md) | 中间件概念、7 个内置中间件、自定义中间件编写 |
| [Tools API](tools.md) | 20 个内置工具（含 bash 安全工具） |
| [MCP Client API](mcp.md) | MCP 客户端（stdio + HTTP/SSE）：连接外部 MCP server |

## See also

- [README.md](../../../README.md) -- 项目概览和 CLI 用法
- [quickstart.md](../../quickstart.md) -- 快速上手指南
- [v0.2-ROADMAP.md](../../v0.2-ROADMAP.md) -- 版本路线图
