# PAR 文档
[English](../index.md) · **简体中文**

> **v0.6.7 提示：** 本仓库的 CLI 已移除；SDK（OCaml / Python）是受支持的界面。需要交互式编码 Agent 体验请使用 [par-code](https://github.com/jcz2020/par-code)。

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
| [CLI 参考 *（v0.6.7 已移除）*](https://github.com/jcz2020/par-code) | 交互式编码 Agent 已迁移到独立的 par-code 项目 |
| [SDK 概览](sdk/overview.md) | SDK 模块索引与文档导航 |
| [Agent API](sdk/agent.md) | Agent 配置、Runtime API、工具注册 |
| [Workflow API](sdk/workflow.md) | 工作流定义、8 种 step 类型、检查点 |
| [Middleware API](sdk/middleware.md) | 7 个内置中间件与自定义中间件编写 |
| [Tools API](sdk/tools.md) | 20 个内置工具（含类型安全 bash） |
| [Generate API](sdk/generate.md) | `invoke_generate` 长输出生成模式，截断自动续写 |
| [MCP Client API](sdk/mcp.md) | MCP 客户端（stdio + HTTP/SSE）：连接外部工具服务器 |
| [文档加载器](sdk/document_loaders.md) | 加载文本、Markdown、HTML、CSV、PDF 为 `Document.t`，接入 RAG |
| [Skills API](sdk/skills.md) | 可复用的 prompt + 工具包，支持触发条件 |
| [Observability](sdk/observability.md) | 指标、健康检查端点、事件总线、结构化日志 |
| [Prompt Caching](sdk/prompt_caching.md) | 缓存系统 prompt 和重复上下文，降低延迟和成本 |
| [Content Blocks](sdk/content_blocks.md) | 结构化内容块，支持多模态和类型化消息部件 |

## 解释 (Explanation)

**理解导向** — 架构原理与设计决策。

| 文档 | 内容 |
|------|------|
| [架构深度解析](explanation/architecture.md) | 核心抽象、模块结构、数据流、类型系统、并发模型、事件流 |

### 文档内部规则

文档维护规则：标识符保留、语言标记、CJK 检查、CI 集成——见 [CONTRIBUTING.md](../../CONTRIBUTING.md)。

## 项目链接

不在上述四个分类中的项目级文档。

- [`README.md`](../../README.md)：项目概览
- [`CHANGES.md`](../../CHANGES.md)：版本历史
- [`CONTRIBUTING.md`](../../CONTRIBUTING.md)：如何贡献
- [`SECURITY.md`](../../SECURITY.md)：安全披露
- [GitHub 仓库](https://github.com/jcz2020/par)：源码、Issues、PR
- [opam 包 `par`](https://opam.ocaml.org/packages/par/)：发布后可用
