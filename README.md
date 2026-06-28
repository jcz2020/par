# PAR — Programmable Agent Runtime

**English** · [简体中文](docs/zh/README.md)

A modular, type-safe agent runtime. LangChain + LangGraph for OCaml — but you can use it from Python or the CLI without writing a single line of OCaml.

[![Build Status](https://github.com/jcz2020/par/actions/workflows/ci.yml/badge.svg)](https://github.com/jcz2020/par/actions/workflows/ci.yml)
[![PyPI](https://img.shields.io/pypi/v/par-runtime?color=blue&label=PyPI)](https://pypi.org/project/par-runtime/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OCaml](https://img.shields.io/badge/OCaml-5.4+-blue)]()

> **Status**: v0.6.0-beta — Configurable truncation policy (`on_max_tokens_behavior` ADT), synthesized tool-calling fallback for non-native providers (PAR-k38), auto JSON-Schema derivation via `ppx_deriving_jsonschema` (PAR-g4c), CLI session resume fixed, 14 GH audit fixes. API may change before v1.0.

---

## What is PAR?

PAR is an agent runtime that handles the plumbing — ReAct loop, tool dispatch, multi-provider LLM calls, persistence, event bus, middleware — so you can focus on your agent's logic, not on infrastructure. Think of it as the server framework for LLM-powered applications, written in OCaml for type safety and structured concurrency, accessible from three surfaces: OCaml SDK, Python binding, and CLI.

## Who is this for?

- **Python backend engineers** who want type-safe agent infrastructure without rewriting their stack in OCaml — `pip install par-runtime` and call the same runtime from Python.
- **OCaml developers** building production LLM applications — the SDK is first-class, every public API has a typed interface.
- **Anyone who wants a CLI** to drive an agent without writing code — `par ask "question"` and you're done.

## Hero

```bash
$ curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
$ par config          # interactive: choose provider (OpenAI / Anthropic / Ollama), enter API key
$ par ask "What is 2+2?"
4

$ pip install par-runtime
>>> from par_runtime import Runtime
>>> rt = Runtime('{"persistence": {"tag": "sqlite", "contents": ":memory:"}}')
>>> rt.register_tool("calc", "Evaluate math", '{"type": "object"}')
```

No OCaml toolchain needed for Python or CLI usage.

## Why PAR?

| Aspect | LangChain (Python) | OpenAI Agents SDK | PAR (OCaml) |
|--------|--------------------|--------------------|-------------|
| Type safety | Runtime crashes | Runtime crashes | **Compile-time guarantees** |
| Concurrency | asyncio callbacks | asyncio callbacks | **Eio structured effects** |
| Shell safety | `exec` with raw strings | raw subprocess | **Type-safe ADT, injection-free** |
| Tool count | 50+ (bloat risk) | 5 (LLM-only) | **20 builtin + custom registration** |
| MCP client | separate lib | not built-in | **stdio + HTTP/SSE builtin** |

## Quick install

**CLI binary** (~5 seconds):
```bash
curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
```

**Python binding** (Linux x86_64 + macOS arm64):
```bash
pip install par-runtime
```

**OCaml SDK** (opam, once published):
```bash
opam install par par_cli
```

**Build from source:**
```bash
git clone https://github.com/jcz2020/par.git && cd par
make install
```

Upgrade: `par update`

## Documentation

Full docs live in [`docs/`](docs/) (also published at **jcz2020.github.io/par**):

- [Quickstart](docs/quickstart.md) — 30-minute tutorial, first agent with tool calls
- [CLI reference](docs/cli.md) — `par`, `par config`, `par ask`, `par history`
- [Agent API](docs/sdk/agent.md) — `agent_config`, `Runtime.invoke`, tool handlers
- [Workflow API](docs/sdk/workflow.md) — sequential, parallel, conditional, map-reduce
- [Middleware](docs/sdk/middleware.md) — Logging, Retry, Rate_limit, Timeout, PII_mask, +3
- [Tools](docs/sdk/tools.md) — 20 built-in tools including type-safe bash
- [MCP Client](docs/sdk/mcp.md) — connect any Model Context Protocol server
- [Streaming API](docs/sdk/streaming.md) — token streaming, tool call events
- [Generate API](docs/sdk/generate.md) — long-output generation, on_max_tokens policy
- [RAG API](docs/sdk/rag.md) — embeddings, vector store, retrieval
- [Skills API](docs/sdk/skills.md) — reusable prompt + tool bundles with triggers
- [Architecture](docs/explanation/architecture.md) — how PAR works internally
- [How-to guides](docs/howto/) — concurrency, custom providers, error handling
- [Doc index](docs/index.md) — complete table of contents

## Features

- **ReAct agent loop** with bounded iterations, middleware at every LLM/tool boundary
- **Workflow engine** — sequential, parallel, conditional, map-reduce with checkpoints
- **Multi-provider LLM** — OpenAI, Anthropic, Ollama (local), Mock (tests), + custom registration for any OpenAI-compatible endpoint
- **MCP client** (stdio + HTTP/SSE) — connect any Model Context Protocol server for tools, resources, prompts
- **20 built-in tools** including type-safe bash (`Bash_safe_command` ADT, shell injection unrepresentable)
- **7 middleware** — Logging, Retry, Rate_limit, Timeout, Validation, PII_mask, Sanitize_tool_output
- **SQLite persistence** — embedded audit log (events, task state, workflow checkpoints, conversation history); Noop backend for tests
- **Structured concurrency** — OCaml 5.4 effects with Eio, no orphan fibers, no callback hell
- **Python ctypes binding** — `par_runtime` package, thread-safe, no GIL contention with OCaml runtime. Persistent Eio domain per Runtime for full concurrency support.
- **1000+ OCaml tests + 64 Python tests** passing (all green, including RAG e2e from any cwd)
- **Skill system** — drop a `skill.md` in `~/.par/skills/<id>/` and it auto-activates during `Runtime.invoke` based on trigger conditions (Auto / Manual / Keyword). See [Skills API](docs/sdk/skills.md).

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
See [`bindings/python/examples/basic_agent.py`](bindings/python/examples/basic_agent.py) and [`bindings/python/tests/`](bindings/python/tests/) (58 pytest tests).

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

### CLI
| Command | Description |
|---------|-------------|
| `par` | Interactive REPL |
| `par config` | Provider/API key/model wizard |
| `par ask "question"` | Single-shot query |
| `par update` | Check and install updates |
| `par history <session>` | Show event history |
| `par stats` | Usage statistics |

## Status & roadmap

**Current**: v0.6.0-beta — Configurable truncation policy (`on_max_tokens_behavior` Retry/Continue/Return_partial ADT), per-provider capability detection with synthesized tool-calling fallback (PAR-k38), auto JSON-Schema derivation via `ppx_deriving_jsonschema` with 13/20 builtin tools migrated (PAR-g4c), CLI session resume fixed (`par -c <id>` / `par -r` now actually round-trip), 14 GH issue audit sweep fixes. See [CHANGES.md](CHANGES.md) for the full release notes.

**Coming next**: Complete PAR-g4c builtin-tool migration (edit tool + bash), external vector stores (Qdrant/Milvus), document loaders, prompt caching, context compression refinements.

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
