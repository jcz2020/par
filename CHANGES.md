# CHANGES

## v0.1.0 (2026-05-30)

Initial release of PAR — Programmable Agent Runtime.

### SDK (par)
- Core ReAct agent engine with type-safe tool dispatch
- Multi-provider LLM support: OpenAI-compatible + Anthropic Messages API
- 8-state machine with 17 validated state transitions
- Expression DSL with 14 forms, bounded evaluation (≤100 depth)
- Workflow engine: sequential, parallel, conditional, map-reduce
- 6 middleware: logging, retry, rate_limit, timeout, validation, pii_mask
- Dual persistence: SQLite (default) + PostgreSQL (production)
- Eio-based event bus with dead-letter queue
- 13 builtin tools (calculator, web tools, string tools, etc.)
- C FFI bridge with thread-safe Python ctypes binding (par_runtime)

### CLI (par_cli)
- Interactive REPL: `par`
- Config wizard: `par config`
- Single-shot query: `par ask "question"`
- Optional overrides: --provider, --api-key, --model, --persistence, --db-uri

### Python Binding (par_runtime)
- ctypes FFI wrapping par_capi.so C API
- Thread-safe Runtime class with context manager
- Tool registration and agent invocation
- 8 pytest tests passing

### Test Suite
- 171 tests total (163 OCaml + 8 Python)
- Mock LLM provider for deterministic testing
- Benchmark harness with 4 correctness metrics