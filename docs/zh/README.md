# PAR — 可编程 Agent 运行时

**[English](../../README.md)** · 简体中文

一个模块化、类型安全的 agent 运行时。LangChain + LangGraph for OCaml —— 但你可以通过 Python 或 OCaml 使用它，不需要写一行另一种语言。

> **需要 CLI？** 请使用 [par-code](https://github.com/jcz2020/par-code) —— 基于本 SDK 构建的交互式编码 Agent。

[![Build Status](https://github.com/jcz2020/par/actions/workflows/ci.yml/badge.svg)](https://github.com/jcz2020/par/actions/workflows/ci.yml)
[![PyPI](https://img.shields.io/pypi/v/par-runtime?color=blue&label=PyPI)](https://pypi.org/project/par-runtime/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../../LICENSE)
[![OCaml](https://img.shields.io/badge/OCaml-5.4+-blue)]()

> **状态**: v0.7.0-beta — 文档加载器框架：5 个格式加载器（文本、Markdown、HTML、CSV、PDF）+ 目录加载器、`Document.t` 记录类型、`LOADER` 模块类型和 `Load_error` ADT。PDF 加载器使用简单文本流提取（不保留布局、不支持 OCR）。1270 tests passing。v1.0 前 API 可能变化。

---

## PAR 是什么？

PAR 是一个 agent 运行时，处理所有底层管道 —— ReAct 循环、工具分发、多 provider LLM 调用、持久化、事件总线、中间件 —— 让你专注 agent 逻辑而非基础设施。可以把它理解为 LLM 应用的服务端框架，用 OCaml 编写以保证类型安全和结构化并发，可通过两个入口使用：OCaml SDK 和 Python 绑定。

## 适合谁用？

- **Python 后端工程师** —— 想要类型安全的 agent 基础设施，但不想用 OCaml 重写整个技术栈。`pip install par-runtime` 即可从 Python 调用同一个运行时。
- **OCaml 开发者** —— 构建生产级 LLM 应用。SDK 是一等公民，每个公共 API 都有类型化接口。

## 演示

```bash
$ pip install par-runtime
$ python3 -c 'from par_runtime import Runtime, Agent; print("OK")'
OK
```

构建一个完整的 agent：

```python
from par_runtime import Runtime

config = '{"persistence": {"tag": "sqlite", "contents": ":memory:"}}'
with Runtime(config) as rt:
    agent = rt.make_agent(id="assistant", model="openai/gpt-4o-mini")
    rt.invoke(agent, "总结最近的日志")
```

## 为什么选 PAR？

| 方面 | LangChain (Python) | OpenAI Agents SDK | PAR (OCaml) |
|------|--------------------|--------------------|-------------|
| 类型安全 | 运行时崩溃 | 运行时崩溃 | **编译时保证** |
| 并发模型 | asyncio 回调 | asyncio 回调 | **Eio 结构化 effects** |
| Shell 安全 | `exec` 拼接原始字符串 | 原始 subprocess | **类型安全 ADT，注入不可能** |
| 工具数量 | 50+（臃肿风险） | 5（仅 LLM） | **20 内置 + 自定义注册** |
| MCP 客户端 | 需要额外库 | 非内置 | **stdio + HTTP/SSE 内置** |

## 快速安装

**交互式 SDK 向导**（检测系统，选 Python 或 OCaml）:
```bash
curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
```

**Python 绑定**（Linux x86_64 + macOS arm64）:
```bash
pip install par-runtime
```

**OCaml SDK**:
```bash
opam pin add par https://github.com/jcz2020/par.git
```

**从源码构建:**
```bash
git clone https://github.com/jcz2020/par.git && cd par
make install-dev   # 构建库 + 安装 .so + 同步 Python 版本
```

## 文档

完整文档在 [`docs/`](../) 中（同时发布在 **jcz2020.github.io/par**）:

- [快速入门](quickstart.md) — 30 分钟教程，构建第一个带工具调用的 agent
- [Agent API](sdk/agent.md) — `agent_config`、`Runtime.invoke`、工具处理器
- [工作流 API](sdk/workflow.md) — 顺序、并行、条件、map-reduce
- [中间件](sdk/middleware.md) — Logging、Retry、Rate_limit、Timeout、PII_mask 等
- [工具](sdk/tools.md) — 20 个内置工具，包括类型安全的 bash
- [MCP 客户端](sdk/mcp.md) — 连接任何 Model Context Protocol 服务器
- [Streaming API](sdk/streaming.md) — token 流式输出、工具调用事件
- [Generate API](sdk/generate.md) — 长输出生成、on_max_tokens 策略
- [RAG API](sdk/rag.md) — embeddings、向量存储、检索
- [文档加载器](sdk/document_loaders.md) — 加载文本、Markdown、HTML、CSV、PDF 为 `Document.t`，接入 RAG
- [Skills API](sdk/skills.md) — 可复用的 prompt + 工具包，支持触发条件
- [架构](explanation/architecture.md) — PAR 内部工作原理
- [How-to 指南](howto/) — 并发、自定义 provider、错误处理
- [文档索引](index.md) — 完整目录

## 功能特性

- **ReAct agent 循环** — 有界迭代，每个 LLM/工具边界都有中间件钩子
- **工作流引擎** — 顺序、并行、条件、map-reduce，支持检查点
- **多 provider LLM** — OpenAI、Anthropic、Ollama（本地）、Mock（测试）+ 自定义注册任何 OpenAI 兼容端点
- **MCP 客户端**（stdio + HTTP/SSE）— 连接任何 Model Context Protocol 服务器获取工具、资源、提示
- **20 个内置工具** — 包括类型安全的 bash（`Bash_safe_command` ADT，shell 注入在类型层不可能）
- **7 个中间件** — Logging、Retry、Rate_limit、Timeout、Validation、PII_mask、Sanitize_tool_output
- **SQLite 持久化** — 嵌入式审计日志（事件、任务状态、工作流检查点、对话历史）；测试用 Noop 内存后端
- **结构化并发** — OCaml 5.4 effects + Eio，无孤立 fiber，无回调地狱
- **Python ctypes 绑定** — `par_runtime` 包，线程安全，与 OCaml 运行时无 GIL 竞争。每个 Runtime 有独立 Eio domain，完整支持并发。
- **1270 OCaml 测试 + Python 绑定** 全部通过（包括任意工作目录的 RAG 端到端测试）
- **Skill 系统** — 在 `~/.par/skills/<id>/` 放一个 `skill.md`，在 `Runtime.invoke` 时根据触发条件（Auto / Manual / Keyword）自动激活。见 [Skills API](sdk/skills.md)。

## 语言轨道

### Python 绑定
```python
from par_runtime import Runtime
import json

config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "default_quota": {"max_tokens": 4096, "max_iterations": 10, "timeout_seconds": 30.0},
})

with Runtime(config) as rt:
    rt.register_tool("echo", "回显工具", '{"type": "object"}')
```
见 [`bindings/python/examples/basic_agent.py`](../../bindings/python/examples/basic_agent.py) 和 [`bindings/python/tests/`](../../bindings/python/tests/)。

### OCaml SDK
```ocaml
open Par
let () = Eio_main.run (fun _env ->
  Eio.Switch.run (fun switch ->
    match Runtime.create ~config switch with
    | Ok rt -> ignore (Runtime.close rt)
    | Error e -> prerr_endline (Runtime.string_of_error_category e)))
```
完整教程见 [`docs/quickstart.md`](../quickstart.md)。

## 状态与路线图

**当前**: v0.7.0-beta — 文档加载器框架：`Document.t` 记录类型包含 `content`、`metadata`（Yojson 值的哈希表）和 `source` 字段。`module type LOADER` 以 `lazy_load` 为规范入口。5 个格式加载器（Text、带 YAML frontmatter 的 Markdown、lambdasoup 的 HTML、行级文档的 CSV、camlpdf 简单提取的 PDF）。`Directory_loader` 支持扩展名分发 `default_map` 和自定义映射。`Load_error` ADT：`File_not_found`、`Permission_denied`、`Unsupported_format`、`Extraction_failed`、`Workspace_rejected`。21 个新测试，共 1270 个通过。

**下一步**: 外部向量库（Qdrant/Milvus）、多模态输入工具、.docx 支持（v0.7.1）。

**近期发布**: v0.6.5（Workspace 抽象）→ v0.6.6（per-run workspace override）→ v0.6.7（CLI 移除，SDK 安装向导）→ v0.6.8（fresh-switch 编译修复）→ v0.6.9（bash cwd 修复，raw SQLite accessor）→ v0.7.0-beta（文档加载器框架）。

## 获取帮助

- [GitHub Issues](https://github.com/jcz2020/par/issues) — bug 报告、功能请求
- [GitHub Discussions](https://github.com/jcz2020/par/discussions) — 问题、展示与讨论
- [CONTRIBUTING.md](../../CONTRIBUTING.md) — 如何贡献
- [CHANGES.md](../../CHANGES.md) — 版本历史

## 贡献

欢迎贡献。开发环境搭建、PR 规范和代码风格见 [CONTRIBUTING.md](../../CONTRIBUTING.md)。项目使用 Diataxis 文档框架 —— 添加文档时请遵循 [教程 / how-to / 参考 / 解释](index.md) 结构。

## 许可证

MIT。见 [LICENSE](../../LICENSE)。

## 致谢

PAR 基于 OCaml 5.4 effects、Eio 并发库、dune 构建系统构建，架构设计受到 LangChain 和 LangGraph 的启发。感谢 PAR 依赖的所有库的维护者。
