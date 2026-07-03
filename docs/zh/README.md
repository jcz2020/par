# PAR — 可编程 Agent 运行时

**[English](../../README.md)** · 简体中文

> **v0.6.7 提示：** 本仓库的 CLI（`par ask`、`par config`）已移除；SDK 是唯一受支持的界面。需要交互式编码 Agent 体验请使用 [par-code](https://github.com/jcz2020/par-code)。以下 `par ask` 示例保留作为历史参考，新用户请参考 SDK 部分。

一个模块化、类型安全的 agent 运行时。OCaml 版的 LangChain + LangGraph —— 但你可以完全通过 Python 或 CLI 使用它，不需要写一行 OCaml 代码。

[![Build Status](https://github.com/jcz2020/par/actions/workflows/ci.yml/badge.svg)](https://github.com/jcz2020/par/actions/workflows/ci.yml)
[![PyPI](https://img.shields.io/pypi/v/par-runtime?color=blue&label=PyPI)](https://pypi.org/project/par-runtime/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../../LICENSE)
[![OCaml](https://img.shields.io/badge/OCaml-5.4+-blue)]()

> **状态**: v0.5.0 beta。首个 PyPI 发布于 2026-06-21。原生 wheel 支持 Linux x86_64 和 macOS arm64。v1.0 前 API 可能变化。

---

## PAR 是什么？

PAR 是一个 agent 运行时，处理所有底层管道 —— ReAct 循环、工具分发、多 provider LLM 调用、持久化、事件总线、中间件 —— 让你专注 agent 逻辑而非基础设施。可以把它理解为 LLM 应用的服务端框架，用 OCaml 编写以保证类型安全和结构化并发，可通过三个入口使用：OCaml SDK、Python 绑定、CLI。

## 适合谁用？

- **Python 后端工程师** —— 想要类型安全的 agent 基础设施，但不想用 OCaml 重写整个技术栈。`pip install par-runtime` 即可从 Python 调用同一个运行时。
- **OCaml 开发者** —— 构建生产级 LLM 应用。SDK 是一等公民，每个公共 API 都有类型化接口。
- **任何想用 CLI 驱动 agent 的人** —— `par ask "问题"` 即可，无需写代码。

## 演示

```bash
$ curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
$ par config          # 交互式：选择 provider（OpenAI / Anthropic / Ollama），输入 API key
$ par ask "2加2等于几？"
4

$ pip install par-runtime
>>> from par_runtime import Runtime
>>> rt = Runtime('{"persistence": {"tag": "sqlite", "contents": ":memory:"}}')
>>> rt.register_tool("calc", "数学计算", '{"type": "object"}')
```

Python 或 CLI 使用不需要安装 OCaml 工具链。

## 为什么选 PAR？

| 方面 | LangChain (Python) | OpenAI Agents SDK | PAR (OCaml) |
|------|--------------------|--------------------|-------------|
| 类型安全 | 运行时崩溃 | 运行时崩溃 | **编译时保证** |
| 并发模型 | asyncio 回调 | asyncio 回调 | **Eio 结构化 effects** |
| Shell 安全 | `exec` 拼接原始字符串 | 原始 subprocess | **类型安全 ADT，注入不可能** |
| 工具数量 | 50+（臃肿风险） | 5（仅 LLM） | **20 内置 + 自定义注册** |
| MCP 客户端 | 需要额外库 | 非内置 | **stdio + HTTP/SSE 内置** |

## 快速安装

**CLI 二进制**（~5 秒）:
```bash
curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
```

**Python 绑定**（Linux x86_64 + macOS arm64）:
```bash
pip install par-runtime
```

**OCaml SDK**（opam，发布后）:
```bash
opam install par par_cli
```

**从源码构建:**
```bash
git clone https://github.com/jcz2020/par.git && cd par
make install
```

升级: `par update`

## 文档

完整文档在 [`docs/`](../) 中（同时发布在 **jcz2020.github.io/par**）:

- [快速入门](quickstart.md) — 30 分钟教程，构建第一个带工具调用的 agent
- [CLI 参考](cli.md) — `par`、`par config`、`par ask`、`par history`
- [Agent API](sdk/agent.md) — `agent_config`、`Runtime.invoke`、工具处理器
- [工作流 API](sdk/workflow.md) — 顺序、并行、条件、map-reduce
- [中间件](sdk/middleware.md) — Logging、Retry、Rate_limit、Timeout、PII_mask 等
- [工具](sdk/tools.md) — 20 个内置工具，包括类型安全的 bash
- [MCP 客户端](sdk/mcp.md) — 连接任何 Model Context Protocol 服务器
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
- **Python ctypes 绑定** — `par_runtime` 包，线程安全，与 OCaml 运行时无 GIL 竞争
- **987 个 OCaml 测试 + 33 个 Python 测试** 通过

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
见 [`bindings/python/examples/basic_agent.py`](../../bindings/python/examples/basic_agent.py) 和 [`bindings/python/tests/`](../../bindings/python/tests/)（33 个 pytest 测试）。

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

### CLI
| 命令 | 描述 |
|------|------|
| `par` | 交互式 REPL |
| `par config` | Provider/API key/模型配置向导 |
| `par ask "问题"` | 单次查询 |
| `par update` | 检查并安装更新 |
| `par history <session>` | 显示事件历史 |
| `par stats` | 使用统计 |

## 状态与路线图

**当前**: v0.5.0 — PyPI 原生 wheel 支持 Linux x86_64 + macOS arm64。ARM64 Linux wheel 推迟（GitHub Actions 免费层级 ARM runner 饱和）。Intel Mac 未发布（`macos-13` runner 已弃用）。

**v0.5.1+ 计划**: ARM64 Linux wheel、RAG 基础（`Runtime.embed`、`Vector_store`、`invoke_with_rag`）、流式输出、双层持久化改进。

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
