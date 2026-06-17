# P-A-R — 可编程 Agent 运行时

[English](../../README.md) · **简体中文**

P-A-R（Programmable Agent Runtime）是一个模块化、类型安全的 Agent 运行时，面向 OCaml 5.4+。
相当于 OCaml 生态的 LangChain + LangGraph。

## 文档目录

| 文档 | 说明 |
|------|------|
| [快速入门](quickstart.md) | 30 分钟从安装到跑起一个带工具调用的 Agent |
| [CLI 参考](cli.md) | `par`、`par config`、`par ask` 命令详解 |
| [SDK 概览](sdk/overview.md) | 模块结构与公共 API 总览 |
| [Agent API](sdk/agent.md) | agent_config、model_config、Runtime.invoke |
| [Workflow API](sdk/workflow.md) | 顺序、并行、条件分支、map-reduce |
| [Middleware](sdk/middleware.md) | 7 个内置中间件 + 自定义写法 |
| [Tools](sdk/tools.md) | 20 个内置工具（含类型安全 bash） |
| [MCP 客户端](sdk/mcp.md) | MCP 客户端 API（stdio + HTTP/SSE）+ 安全清单 |

### How-to 指南

| 文档 | 说明 |
|------|------|
| [并发模式](howto/concurrency.md) | 3 层并发、并行 tool 调用、限流 |
| [自定义 LLM Provider](howto/custom-llm-provider.md) | 注册 Cohere、Mistral、Ollama 等 |
| [错误处理](howto/error-handling.md) | error_category、重试策略、取消传播 |

### 深入理解

| 文档 | 说明 |
|------|------|
| [架构总览](explanation/architecture.md) | 模块结构、数据流、类型系统、Eio 并发模型 |

## 相关链接

- [索引页](index.md) — 完整文档导航
- [贡献指南](../../CONTRIBUTING.md) — 开发环境搭建与 PR 规范
- [安全策略](../../SECURITY.md) — 漏洞报告与安全特性
