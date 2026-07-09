# PAR — Programmable Agent Runtime

**English** · [简体中文](docs/zh/README.md)

A modular, type-safe agent runtime. LangChain + LangGraph for OCaml — but you can use it from Python or OCaml without writing a single line of the other.

> **Looking for the CLI?** Use [par-code](https://github.com/jcz2020/par-code) — an interactive coding agent built on this SDK.

[![Build Status](https://github.com/jcz2020/par/actions/workflows/ci.yml/badge.svg)](https://github.com/jcz2020/par/actions/workflows/ci.yml)
[![PyPI](https://img.shields.io/pypi/v/par-runtime?color=blue&label=PyPI)](https://pypi.org/project/par-runtime/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OCaml](https://img.shields.io/badge/OCaml-5.4+-blue)]()

> **Status**: v0.7.1-beta — Concurrency Architecture + Memory Module + Persistence Scope + Deprecation Framework + Dynamic System Prompt. `invoke_context` per-call isolation via Eio.Fiber makes `Runtime.invoke` safe for reentrancy, parallelism, and `invoke_async`. New `Memory_service` (FTS5) + 3 builtin tools. Workflow `Agent_call` gains `response_schema`. Generic persistence `scope` dimension. `Deprecation.warn_once` + event bus signaling. Per-turn `system_prompt_appendix`. Auto-skill `system_prompt_override` bug fixed. FFI persistence wiring fixed. 1306 tests passing. API may change before v1.0.

---

## What is PAR?

PAR is an agent runtime that handles the plumbing — ReAct loop, tool dispatch, multi-provider LLM calls, persistence, event bus, middleware — so you can focus on your agent's logic, not on infrastructure. Think of it as the server framework for LLM-powered applications, written in OCaml for type safety and structured concurrency, accessible from two surfaces: OCaml SDK and Python bindings.

## Who is this for?

- **Python backend engineers** who want type-safe agent infrastructure without rewriting their stack in OCaml — `pip install par-runtime` and call the same runtime from Python.
- **OCaml developers** building production LLM applications — the SDK is first-class, every public API has a typed interface.

## Hero

```bash
$ pip install par-runtime
$ python3 -c 'from par_runtime import Runtime, Agent; print("OK")'
OK
```

Build a real agent end-to-end:

```python
from par_runtime import Runtime

config = '{"persistence": {"tag": "sqlite", "contents": ":memory:"}}'
with Runtime(config) as rt:
    agent = rt.make_agent(id="assistant", model="openai/gpt-4o-mini")
    rt.invoke(agent, "Summarize the last 3 log entries")
```

## Why PAR?

| Aspect | LangChain (Python) | OpenAI Agents SDK | PAR (OCaml) |
|--------|--------------------|--------------------|-------------|
| Type safety | Runtime crashes | Runtime crashes | **Compile-time guarantees** |
| Concurrency | asyncio callbacks | asyncio callbacks | **Eio structured effects** |
| Shell safety | `exec` with raw strings | raw subprocess | **Type-safe ADT, injection-free** |
| Tool count | 50+ (bloat risk) | 5 (LLM-only) | **20 builtin + custom registration** |
| MCP client | separate lib | not built-in | **stdio + HTTP/SSE builtin** |

## Quick install

**Interactive SDK wizard** (detects system, picks Python or OCaml):
```bash
curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
```

**Python binding** (Linux x86_64 + macOS arm64):
```bash
pip install par-runtime
```

**OCaml SDK**:
```bash
opam pin add par https://github.com/jcz2020/par.git
```

**Build from source:**
```bash
git clone https://github.com/jcz2020/par.git && cd par
make install-dev   # builds library + installs .so + syncs Python version
```

## Documentation

Full docs live in [`docs/`](docs/) (also published at **jcz2020.github.io/par**):

- [Quickstart](docs/quickstart.md) — 30-minute tutorial, first agent with tool calls
- [Agent API](docs/sdk/agent.md) — `agent_config`, `Runtime.invoke`, tool handlers
- [Workflow API](docs/sdk/workflow.md) — sequential, parallel, conditional, map-reduce
- [Middleware](docs/sdk/middleware.md) — Logging, Retry, Rate_limit, Timeout, PII_mask, +3
- [Tools](docs/sdk/tools.md) — 20 built-in tools including type-safe bash
- [MCP Client](docs/sdk/mcp.md) — connect any Model Context Protocol server
- [Streaming API](docs/sdk/streaming.md) — token streaming, tool call events
- [Generate API](docs/sdk/generate.md) — long-output generation, on_max_tokens policy
- [RAG API](docs/sdk/rag.md) — embeddings, vector store, retrieval
- [Document Loaders](docs/sdk/document_loaders.md) — load text, Markdown, HTML, CSV, PDF into `Document.t` for RAG
- [Memory API](docs/sdk/memory.md) — cross-session agent memory with FTS5 search + 3 builtin tools
- [Skills API](docs/sdk/skills.md) — reusable prompt + tool bundles with triggers
- [Architecture](docs/explanation/architecture.md) — how PAR works internally
- [How-to guides](docs/howto/) — concurrency, custom providers, error handling
- [Doc index](docs/index.md) — complete table of contents

## Features

- **ReAct agent loop** with bounded iterations, middleware at every LLM/tool boundary
- **Workflow engine** — sequential, parallel, conditional, map-reduce with checkpoints; `Agent_call` supports `response_schema` for structured output
- **Multi-provider LLM** — OpenAI, Anthropic, Ollama (local), Mock (tests), + custom registration for any OpenAI-compatible endpoint
- **MCP client** (stdio + HTTP/SSE) — connect any Model Context Protocol server for tools, resources, prompts
- **23 built-in tools** including type-safe bash (`Bash_safe_command` ADT), memory tools (`recall_memory`, `remember_memory`, `search_history`)
- **7 middleware** — Logging, Retry, Rate_limit, Timeout, Validation, PII_mask, Sanitize_tool_output
- **SQLite persistence** — embedded audit log with generic `scope` dimension for session grouping (workspace/user/tenant); Noop backend for tests
- **Structured concurrency** — OCaml 5.4 effects with Eio, no orphan fibers, no callback hell. `invoke_context` per-call isolation via `Eio.Fiber.with_binding` makes `Runtime.invoke` safe for reentrancy, parallelism, and `invoke_async`.
- **Agent memory** — cross-session `Memory_service` (FTS5 keyword search) + 3 builtin tools. Scoped per-session via `invoke_context`. Pluggable like `llm_service`.
- **Dynamic system prompt** — per-turn `system_prompt_appendix` via `invoke_context`. Appends after template + skill overlay + tool suffix. Covers invoke/generate/handoff paths.
- **Deprecation framework** — `warn_once` helper + `Deprecated_api_called` event + `[@@deprecated]` annotations + migration guides. Breaking changes no longer happen silently.
- **Python ctypes binding** — `par_runtime` package, thread-safe, no GIL contention with OCaml runtime. Persistent Eio domain per Runtime for full concurrency support.
- **1306 OCaml tests + Python bindings** passing (all green, including RAG e2e from any cwd)
- **Skill system** — drop a `skill.md` in `~/.par/skills/<id>/` and it auto-activates during `Runtime.invoke` based on trigger conditions (Auto / Manual / Keyword). Auto-trigger skills no longer replace the system prompt. See [Skills API](docs/sdk/skills.md).

## Language tracks

### Python binding
```python
from par_runtime import Runtime
import json

config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "default_quota": {"max_tokens": 4096, "max_iterations": 10, "timeout_seconds": 30.0},
})

with Runtime(config) as rt:
    rt.register_tool("echo", "Echo tool", '{"type": "object"}')
```
See [`bindings/python/examples/basic_agent.py`](bindings/python/examples/basic_agent.py) and [`bindings/python/tests/`](bindings/python/tests/).

### OCaml SDK
```ocaml
open Par
let () = Eio_main.run (fun _env ->
  Eio.Switch.run (fun switch ->
    match Runtime.create ~config switch with
    | Ok rt -> ignore (Runtime.close rt)
    | Error e -> prerr_endline (Runtime.string_of_error_category e)))
```
See [`docs/quickstart.md`](docs/quickstart.md) for the full tutorial.

## Status & roadmap

**Current**: v0.7.1-beta — Concurrency Architecture (invoke_context + invoke_async + reentrancy), Memory Module (FTS5 + 3 builtin tools), Persistence Session Scope Dimension, Deprecation Framework (warn_once + event + migration guide), Per-turn Dynamic System Prompt (system_prompt_appendix), Workflow response_schema, Auto-skill system_prompt_override bug fix, FFI persistence wiring fix. 1306 tests passing.

**Coming next**: Windows process support (v0.7.2), vector-based semantic recall (backlog P0), external vector stores (Qdrant/Milvus), multimodal image tools, .docx support.

**Recent releases**: v0.6.5 (Workspace abstraction) → v0.6.6 (per-run workspace override) → v0.6.7 (CLI removed, SDK installer wizard) → v0.6.8 (fresh-switch compilation fix) → v0.6.9 (bash cwd fix, raw SQLite accessor) → v0.7.0-beta (Document Loaders Framework) → v0.7.1-beta (Concurrency + Memory + Scope + Deprecation + Dynamic Prompt).

## Getting help

- [GitHub Issues](https://github.com/jcz2020/par/issues) — bug reports, feature requests
- [GitHub Discussions](https://github.com/jcz2020/par/discussions) — questions, show & tell
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute
- [CHANGES.md](CHANGES.md) — version history

## Contributing

Contributions welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, PR conventions, and code style. The project uses the Diataxis documentation framework — when adding docs, follow the [tutorial / how-to / reference / explanation](docs/index.md) structure.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgements

PAR builds on OCaml 5.4 effects, the Eio concurrency library, the dune build system, and draws architectural inspiration from LangChain and LangGraph. Thanks to every maintainer of the libraries PAR depends on.
