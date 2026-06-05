# P-A-R SDK 概览

P-A-R (Programmable Agent Runtime) 是一个基于 OCaml 5.4+ 的模块化 Agent 运行时，
提供 ReAct 推理循环、工作流编排、持久化状态管理和中间件管道。

## SDK 文档索引

| 文档 | 内容 |
|------|------|
| [Agent API](agent.md) | Agent 配置、运行时创建、工具注册、ReAct 循环 |
| [Workflow API](workflow.md) | 工作流定义、步骤类型、条件分支、审批、检查点 |
| [Middleware API](middleware.md) | 中间件概念、7 个内置中间件、自定义中间件编写 |
| [Tools API](tools.md) | 20 个内置工具（含 bash 安全工具） |
| [MCP Client API](mcp.md) | MCP stdio 客户端：连接外部 MCP server |

## See also

- [README.md](../../README.md) — 项目概览和 CLI 用法
- [quickstart.md](../quickstart.md) — 快速上手指南
- [architecture.md](../explanation/architecture.md) — SDK 架构深度解析（模块、数据流、类型系统、并发）
