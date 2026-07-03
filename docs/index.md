<!-- language: en -->

**English** · [简体中文](zh/index.md)

# PAR Documentation

PAR's docs are SDK-first. PAR is an embeddable runtime — production code uses the OCaml SDK directly, and Python code calls the same runtime via ctypes bindings. If you're building an agent, start with the SDK overview and the agent API reference.

The docs are organized by purpose, not by source-tree layout. Four sections follow: Tutorials walk you through a complete task from scratch, How-to guides solve a specific problem, Reference documents every API, and Explanation discusses the design decisions. Pick the section that matches your question; cross-links inside each page point at related material.

Every page in this tree opens with a `<!-- language: en -->` marker on line 1, ships English only, and preserves OCaml identifiers verbatim (backticks, not code blocks). The full authoring contract, the identifier list, and the pre-release checklist live in [Documentation maintenance](DOC-MAINTENANCE.md); contributors should read that file before opening a doc PR.

The audience for this tree is two groups: SDK users who embed `par` in their applications (OCaml or Python), and contributors who extend the runtime with a new provider, tool, or middleware. The four sections below serve both, and each page is written so a fresh reader can act on it without first reading the rest of the tree.

## Tutorials

Tutorials walk you through a complete task from scratch. Start here if you're new to PAR. The quickstart below installs the SDK, configures an LLM provider, and runs an agent with a single tool end-to-end; later tutorials build on the same setup.

| Document | Time | What you'll build |
|----------|------|-------------------|
| [Quickstart](quickstart.md) | 30 min | An agent with one tool, run end-to-end |
| [01: RAG Q&A Bot](tutorials/01-rag-qa-bot.md) | 30 min | A PDF-style Q&A bot: embed, index, retrieve, answer |
| [02: Streaming UI](tutorials/02-streaming-ui.md) | 25 min | Consume `invoke_stream` into a live-updating TTY UI |
| [04: Multi-Provider Fallback](tutorials/04-multi-provider-fallback.md) | — | *stub, ships after v0.5.4 Track A Phase A.3* |
| [05: Session Resume](tutorials/05-session-resume.md) | — | *stub, ships after v0.5.4 Track B Phase B.2* |

## How-to guides

How-to guides solve specific problems. Skip to the one you need. Each guide assumes you have already completed the quickstart and have a working `par` install, and each one ends with a short checklist you can run to confirm the change took effect.

If you are looking for a one-paragraph answer to a setup or runtime question, the FAQ is the fastest entry point. For deeper recipes, the table below is grouped by topic so you can jump straight to the area that matches your problem.

### Concurrency & scaling

[Concurrency patterns](howto/concurrency.md): 3 layers of parallelism: Runtime, Fiber, Tool.

### Provider integration

[Custom LLM provider](howto/custom-llm-provider.md): register Cohere, Mistral, Ollama, or any OpenAI-compatible endpoint.

### Operations & reliability

[Error handling](howto/error-handling.md): error_category classification, recovery strategies, event-bus auditing.

### Common questions

[FAQ](explanation/faq.md): 6 common questions answered (PAR vs LangChain, picking a surface, streaming behavior, persistence, provider support, the skill system).

## Reference

Reference docs are the API source of truth. Look here for type signatures, configuration options, and Python/OCaml binding details. PAR is an SDK — the reference IS the product; there is no separate "user-facing" surface beyond the bindings.

The SDK is the canonical surface. Every page below is marked **PRIMARY** because it documents a public API of the `par` package. If a behavior changes in code, these pages are updated first.

| Document | Description |
|----------|-------------|
| [SDK overview](sdk/overview.md) | **PRIMARY**: the SDK hub (architecture, five-minute tour, module map) |
| [Agent API](sdk/agent.md) | **PRIMARY**: Agent config, Runtime API, tool registration, ReAct loop |
| [Workflow API](sdk/workflow.md) | **PRIMARY**: workflow JSON, 8 step types, checkpoints |
| [Middleware API](sdk/middleware.md) | **PRIMARY**: 7 built-in middlewares and how to write your own |
| [Tools API](sdk/tools.md) | **PRIMARY**: all 20 built-in tools including type-safe bash |
| [Streaming API](sdk/streaming.md) | **PRIMARY**: `invoke_stream`, 5-event tagged union, backpressure, 3 runnable examples |
| [Generate API](sdk/generate.md) | **PRIMARY**: `invoke_generate`, long-output generation mode, auto-continue on truncation |
| [RAG API](sdk/rag.md) | Embeddings, vector store, chunking, `invoke_with_rag` |
| [MCP Client API](sdk/mcp.md) | **PRIMARY**: MCP client (stdio + HTTP/SSE), 7 event types, server lifecycle |

## Explanation

Explanation docs discuss the why behind PAR's design. Read these when you want to understand the type system, concurrency model, or how an invoke flows through the runtime. These pages argue for a design choice; reference pages simply document the current state.

### Architecture

[Architecture deep dive](explanation/architecture.md): core abstractions, module structure, data flow, type system, Eio concurrency, event stream.

### Common questions

[FAQ](explanation/faq.md): 6 common questions answered (PAR vs LangChain, picking a surface, streaming behavior, persistence, provider support, the skill system).

### Doc internals

[Documentation maintenance](DOC-MAINTENANCE.md): the rules that keep PAR's docs clean (identifier preservation, language indicator, CJK check, CI integration).

## Project links

Project-level documents that live outside the four sections above.

- [`README.md`](../README.md): project overview
- [`CHANGES.md`](../CHANGES.md): changelog
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): how to contribute
- [`SECURITY.md`](../SECURITY.md): security disclosure
- [GitHub repository](https://github.com/jcz2020/par): source, issues, PRs
- [opam package `par`](https://opam.ocaml.org/packages/par/): once published
