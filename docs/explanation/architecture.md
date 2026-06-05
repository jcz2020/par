<!-- language: en -->

**English** · [简体中文](../zh-CN/explanation/architecture.md)

> Translated to English for v0.3.2.

# Architecture Overview

This document explains the internal structure of the PAR SDK. It is intended for readers who want to understand how PAR works or contribute to the core codebase.

## Core abstractions

PAR models the LLM agent as three layers:

```
┌─────────────────────────────────────────────────────────┐
│                     LLM Loop                             │
│  ReAct loop: observe → think → act → observe → ...      │
│  (lib/core/engine.ml)                                    │
├─────────────────────────────────────────────────────────┤
│  Tool calls (types, dispatch, timeout, concurrency)      │
│  (lib/tools/builtin_tools.ml)                            │
├─────────────────────────────────────────────────────────┤
│  LLM communication (OpenAI / Anthropic)                  │
│  (lib/providers/)                                        │
└─────────────────────────────────────────────────────────┘
```

Each layer has its own type boundary, ensuring that errors are caught at compile time.

## Module structure

```
lib/
├── core/           Types + Runtime + Engine + SDK entry point
│   ├── types.ml         All public types (agent_config, tool_descriptor, handler_result, ...)
│   ├── runtime.ml       Runtime.create / make_agent / register_tool / invoke
│   ├── engine.ml        ReAct loop implementation
│   ├── sdk.ml           Public SDK API
│   ├── tool_registry.ml Tool deduplication and registration
│   ├── cancellation.ml  Cooperative cancellation semantics
│   ├── context_manager.ml Conversation context management
│   ├── expression.ml    Expression evaluation (used by Workflow)
│   ├── state_machine.ml 8-state machine
│   └── workflow.ml      Workflow engine (sequential / parallel / conditional / map-reduce)
│
├── providers/      LLM providers
│   ├── openai_provider.ml
│   ├── anthropic_provider.ml
│   └── mock_provider.ml  (for testing)
│
├── tools/          Built-in tools (20 since v0.3.1)
│   ├── builtin_tools.ml
│   ├── bash_safe_command.ml  (v0.3.1 bash ADT)
│   ├── bash_policy.ml        (v0.3.1 safety policy)
│   └── bash_blacklist.ml     (v0.3.1 blacklist)
│
├── persistence/    Persistence backends
│   ├── sqlite_persistence.ml
│   └── postgres_persistence.ml  (separate opam package)
│
├── event_bus/      Event bus (with DLQ)
│
├── middleware/     7 built-in middleware
│   ├── logging / retry / rate_limit / timeout / validation / pii_mask / sanitize_tool_output
│
├── ffi/            C FFI (par_capi.so + par_ffi.h + par_ffi.c)
│
└── par.ml          Public entry point (re-exports all sub-modules)
```

## Data flow: a single invoke

```
User code
  │
  ▼
Runtime.invoke agent_id "question"
  │
  ▼
Engine.execute_ReAct_loop agent conversation
  │
  ▼  ┌─→ LLM Provider (OpenAI / Anthropic) ─→ network
  │   │
  │   ◄── LLM response (text + tool_calls)
  │
  ├──→ Parse tool_calls
  │   │
  │   ▼
  │   Tool_registry.invoke tool_name
  │     │
  │     ▼
  │     Tool_handler input token → output / error
  │     │
  │     ▼
  │   Parse result, inject into conversation
  │
  ├──→ Middleware chain (logging / retry / rate_limit / ...)
  │
  ▼
Return final result (text + tool_calls history)
```

## Type system: why PAR is safer

PAR uses OCaml's strong types instead of Python-style dynamic dictionaries:

- Tool parameter types are checked at **compile time** (not runtime crashes)
- LLM response parsing uses pattern matching to **force coverage** of all branches
- Configuration is validated through `make_config` constructors (rejects illegal values)
- Duplicate tool names return `Error (`Duplicate_tool)` instead of silently overwriting

The v0.3.1 `bash` tool is the extreme expression of this compile-time safety: the `command` ADT has **no** `Exec_raw_shell` constructor — shell injection is unrepresentable at the type level.

## Concurrency model (Eio)

PAR's entire stack runs on [Eio](https://github.com/ocaml-multicore/eio) — OCaml 5's structured concurrency primitives.

Key points:
- Every Runtime has one `Eio.Switch.t` (cancellation root)
- `Runtime.close` triggers the entire switch to cancel; all fibers (tool handlers, LLM inference, SSE streams) are cancelled
- `cancellation_token` is passed through to every tool handler; handlers can cooperatively cancel inside `with_timeout`
- Timeouts use `Eio.Fiber.first`: `Future.first [| timeout sleep |]`

## Event stream

`Par.Types.event` is an open sum type; each event is an inline record:

```ocaml
type event =
  | Task_created of { task_id : Task_id.t; task_type : string; priority : int }
  | Task_completed of { task_id : Task_id.t; duration_ms : float }
  | Tool_invoked of { task_id : Task_id.t; tool_name : string }
  | Tool_progress of { task_id : Task_id.t; tool_name : string; message : string }
  | Bash_invoked of { task_id : Task_id.t; argv : string list; risk : string; ... }  (* v0.3.1 *)
  | ...
  [@@deriving yojson]
```

Events are emitted by the Runtime via `rt.publish_event_fn`, and subscribers receive them through `Event_bus.subscribe`. Since v0.3.0, events are also written to SQLite / Postgres (for audit and debug).

## Next steps

- **Add a tool**: see the 20 tools in [docs/sdk/tools.md](sdk/tools.md), then add one with `let my_tool = { descriptor; handler } in` and `Runtime.register_tool`.
- **Add an LLM provider**: see [docs/howto/custom-llm-provider.md](howto/custom-llm-provider.md).
- **Add middleware**: see the 7 examples in `lib/middleware/` and the reference at [docs/sdk/middleware.md](sdk/middleware.md).
- **Contribute to core**: read `lib/core/types.ml` (all public types), then follow the Runtime lifecycle through `lib/core/runtime.ml`.
