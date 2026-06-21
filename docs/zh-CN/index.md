# PAR 文档
[English](../index.md) · **简体中文**

本目录包含 PAR (Programmable Agent Runtime) 的用户文档。

文档按 [Diátaxis](https://diataxis.fr/) 框架组织为四个分类：

---

## 教程 (Tutorial)

**学习导向** — 从零开始，手把手带你跑通。

| 文档 | 内容 |
|------|------|
| [快速上手](quickstart.md) | 30 分钟教程：安装 → 配置 provider → 写第一个带工具调用的 agent |

## 操作指南 (How-to Guide)

**任务导向** — 解决具体问题的步骤。

| 文档 | 内容 |
|------|------|
| [并发模式](howto/concurrency.md) | 3 层并发：Runtime 级、Fiber 级、Tool 级并行 |
| [自定义 LLM Provider](howto/custom-llm-provider.md) | 注册 Cohere、Mistral、Ollama 等自定义 provider |
| [错误处理](howto/error-handling.md) | error_category 分类、恢复策略、event bus 审计 |

## 参考 (Reference)

**查阅导向** — API 签名、配置项、命令参数。

| 文档 | 内容 |
|------|------|
| [CLI 参考](cli.md) | `par` / `par config` / `par ask` 全部命令与参数 |
| [SDK 概览](sdk/overview.md) | SDK 模块索引与文档导航 |
| [Agent API](sdk/agent.md) | Agent 配置、Runtime API、工具注册 |
| [Workflow API](sdk/workflow.md) | 工作流定义、8 种 step 类型、检查点 |
| [Middleware API](sdk/middleware.md) | 7 个内置中间件与自定义中间件编写 |
| [Tools API](sdk/tools.md) | 20 个内置工具（含类型安全 bash） |
| [MCP Client API](sdk/mcp.md) | MCP 客户端（stdio + HTTP/SSE）：连接外部工具服务器 |

## 解释 (Explanation)

**理解导向** — 架构原理与设计决策。

| 文档 | 内容 |
|------|------|
| [架构深度解析](explanation/architecture.md) | 核心抽象、模块结构、数据流、类型系统、并发模型、事件流 |

### 文档内部规则

[文档维护规则](../DOC-MAINTENANCE.md)：保持 PAR 文档整洁的规则（标识符保留、语言标记、CJK 检查、CI 集成）。

## 项目链接

不在上述四个分类中的项目级文档。

- [`README.md`](../../README.md)：项目概览
- [`CHANGES.md`](../../CHANGES.md)：版本历史
- [`CONTRIBUTING.md`](../../CONTRIBUTING.md)：如何贡献
- [`SECURITY.md`](../../SECURITY.md)：安全披露
- [GitHub 仓库](https://github.com/jcz2020/par)：源码、Issues、PR
- [opam 包 `par`](https://opam.ocaml.org/packages/par/)：发布后可用
