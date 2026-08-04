<!-- language: zh -->

# PAR 文档

本目录包含 PAR (Programmable Agent Runtime) 的用户文档。

文档按 [Diátaxis](https://diataxis.fr/) 框架组织为四个分类：教程、操作指南、参考、解释。

---

## 教程 (Tutorial)

**学习导向** — 从零开始，手把手带你跑通。

| 文档 | 时间 | 内容 |
|------|------|------|
| [快速上手](quickstart.md) | 30 min | 安装 → 配置 provider → 写第一个带工具调用的 agent |
| [01: RAG 问答机器人](tutorials/01-rag-qa-bot.md) | 30 min | PDF 风格问答：embed、索引、检索、回答 |
| [02: 流式 UI](tutorials/02-streaming-ui.md) | 25 min | 用 `invoke_stream` 消费 token 流，构建实时 TTY UI |
| [04: 多 Provider 回退](https://github.com/jcz2020/par/blob/main/docs/tutorials/04-multi-provider-fallback.md) | — | *stub（仅英文）* |
| [05: 会话恢复](https://github.com/jcz2020/par/blob/main/docs/tutorials/05-session-resume.md) | — | *stub（仅英文）* |

## 操作指南 (How-to Guide)

**任务导向** — 解决具体问题的步骤。

| 文档 | 内容 |
|------|------|
| [并发模式](howto/concurrency.md) | 3 层并发：Runtime 级、Fiber 级、Tool 级并行 |
| [自定义 LLM Provider](howto/custom-llm-provider.md) | 注册 Cohere、Mistral、Ollama 等自定义 provider |
| [错误处理](howto/error-handling.md) | error_category 分类、恢复策略、event bus 审计 |

### 常见问题

[FAQ](explanation/faq.md)：6 个常见问题（PAR vs LangChain、选择界面、流式行为、持久化、provider 支持、技能系统）。

## 参考 (Reference)

**查阅导向** — API 签名、配置项。

| 文档 | 内容 |
|------|------|
| [SDK 概览](sdk/overview.md) | SDK 模块索引与文档导航 |
| [Agent API](sdk/agent.md) | Agent 配置、Runtime API、工具注册、ReAct 循环 |
| [HITL API](sdk/hitl.md) | 人在环路审批（挂起-恢复、持久化、跨进程） |
| [并行分发](sdk/parallel.md) | 并行多 Agent 分发，类型化合并 |
| [Invoke Context](sdk/invoke_context.md) | 单次调用上下文隔离（`Fiber.key` 绑定） |
| [Workflow API](sdk/workflow.md) | 工作流定义、8 种 step 类型、检查点 |
| [Middleware API](sdk/middleware.md) | 9 个内置中间件与自定义中间件编写 |
| [Tools API](sdk/tools.md) | 23 个内置工具（含类型安全 bash） |
| [Streaming API](sdk/streaming.md) | 流式 API，token 流式输出与工具调用事件 |
| [Generate API](sdk/generate.md) | `invoke_generate` 长输出生成模式，截断自动续写 |
| [RAG API](sdk/rag.md) | RAG API，embeddings、向量存储、检索 |
| [MCP Client API](sdk/mcp.md) | MCP 客户端（stdio + HTTP/SSE）：连接外部工具服务器 |
| [文档加载器](sdk/document_loaders.md) | 加载文本、Markdown、HTML、CSV、PDF 为 `Document.t`，接入 RAG |
| [Memory API](sdk/memory.md) | 跨会话记忆，FTS5 + 3 个内置工具 |
| [Persistence API](sdk/persistence.md) | SQLite + Noop 持久化后端 |
| [Skills API](sdk/skills.md) | 可复用的 prompt + 工具包，支持触发条件 |
| [Observability](sdk/observability.md) | 指标、健康检查端点、事件总线、结构化日志 |
| [Prompt Caching](sdk/prompt_caching.md) | 缓存系统 prompt 和重复上下文，降低延迟和成本 |
| [Content Blocks](sdk/content_blocks.md) | 结构化内容块，支持多模态和类型化消息部件 |

## 解释 (Explanation)

**理解导向** — 架构原理与设计决策。

| 文档 | 内容 |
|------|------|
| [架构深度解析](explanation/architecture.md) | 核心抽象、模块结构、数据流、类型系统、并发模型、事件流 |

### 常见问题

[FAQ](explanation/faq.md)：6 个常见问题（PAR vs LangChain、选择界面、流式行为、持久化、provider 支持、技能系统）。

### 文档内部规则

文档维护规则：标识符保留、语言标记、CJK 检查、CI 集成——见 [CONTRIBUTING.md](https://github.com/jcz2020/par/blob/main/CONTRIBUTING.md)。

## 项目链接

不在上述四个分类中的项目级文档。

- [`README.md`](https://github.com/jcz2020/par/blob/main/README.md)：项目概览
- [`CHANGES.md`](https://github.com/jcz2020/par/blob/main/CHANGES.md)：版本历史
- [`CONTRIBUTING.md`](https://github.com/jcz2020/par/blob/main/CONTRIBUTING.md)：如何贡献
- [`SECURITY.md`](https://github.com/jcz2020/par/blob/main/SECURITY.md)：安全披露
- [GitHub 仓库](https://github.com/jcz2020/par)：源码、Issues、PR
- [opam 包 `par`](https://opam.ocaml.org/packages/par/)：发布后可用
