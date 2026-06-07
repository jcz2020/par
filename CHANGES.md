# CHANGES

## v0.3.7 (2026-06-08)

> CI fix: add `linenoise` dependency to `par_cli.opam`. 871 OCaml tests, 16 Python tests.

### Bug Fixes

- **CI build fix**: Added `linenoise` to the `par_cli` package depends in `dune-project`, so the generated `par_cli.opam` correctly lists it as a dependency. Without this, `opam install par_cli --deps-only` on CI never installed `linenoise`, causing `dune build` to fail with "Library linenoise not found".

## v0.3.6 (2026-06-08)

> Streaming tool call fix, CLI help beautification, short flag aliases. 871 OCaml tests, 16 Python tests.

### Bug Fixes

- **Streaming tool calls now work**: OpenAI and Anthropic streaming providers had a `tool_call_id` key mismatch — `Tool_call_start` used the API-issued id while `Tool_call_delta` used the array index, so the engine's Hashtbl never accumulated arguments. Both providers now consistently use the index as the matching key. Additionally, GLM-4 sends `name` and `arguments` in a single chunk; the parser now emits both `Tool_call_start` and `Tool_call_delta` in that case.
- **Tool duration display**: Changed from `int_of_float` (truncating sub-ms durations to 0ms) to `%.1f` format, so fast tools like `calculator` now show accurate timings (e.g. `0.5ms` instead of `0ms`).
- **TTY color detection**: `TERM=dumb` is now set only when stdout is not a TTY, restoring Cmdliner ANSI styling for interactive terminals.

### CLI

- **Custom help renderer**: `par --help` and `par -h` now render a cargo-style colored help page using `cli_style.ml` (green command names, yellow section headers, dim descriptions). Bypasses Cmdliner's plain-text renderer.
- **Short flag aliases**: `par -v` prints the version, `par -h` prints help. Both work alongside the long forms `--version` and `--help`.

## v0.3.5 (2026-06-07)

> CLI streaming output, tool call summary, release pipeline fixes. 873 OCaml tests, 16 Python tests.

### CLI

- **Streaming output**: LLM responses now stream token-by-token to stdout in real-time. The engine uses `stream_fn` with an internal accumulator that forwards chunks to the CLI while reconstructing the full `llm_response` for the ReAct loop (tool calls, finish_reason, usage).
- **Tool call summary**: Prints `→ tool_name ✓ (Nms)` to stderr on tool completion, `→ tool_name ✗` on failure. Tracked per-task_id for correct parallel tool execution.
- **`par upgrade` renamed to `par update`**: No alias, no `--check` flag. Clean break from the old name.
- **Colored REPL prompt**: `par>` in bold cyan, agent responses in green, informational messages in dim. Respects `NO_COLOR` env var and non-TTY detection.

### Providers

- **Incremental SSE streaming**: Both OpenAI and Anthropic providers now use `Http_client.do_request_streaming` for real-time line-by-line parsing instead of buffering the entire response. Chunks fire to the callback as they arrive from the server.

### Engine

- **Tool event publishing**: Engine fires `Tool_invoked`, `Tool_completed`, and `Tool_failed` events with `task_id`, `tool_name`, and `duration_ms`. Observable via `?on_tool_event` on `Runtime.invoke` and `Engine.run_agent`.
- **Streaming API**: `Engine.run_agent` and `Runtime.invoke` gain `?on_chunk:(llm_response_chunk -> unit)` for real-time streaming output.

### HTTP

- **`do_request_streaming`**: New function in `Http_client` that parses HTTP responses incrementally via `Eio.Buf_read`, supporting both chunked and non-chunked transfer encoding.
- **Chunked encoding fix**: Chunk sizes are now always parsed as hexadecimal (HTTP spec), fixing a bug where pure-digit hex sizes like "200" were incorrectly interpreted as decimal.

### Release Pipeline

- **Release naming**: Binary assets use `par-v{version}-{platform}` format (e.g. `par-v0.3.5-linux-x64`).
- **CI exclusion**: `par_postgres` excluded from CI dependency resolution (postgresql opam package not in standard repo).
- **Release template**: `docs/RELEASE-TEMPLATE.md` provides per-platform install instructions for GitHub Release body.

## v0.3.4 (2026-06-07)

> Release pipeline: multi-platform binaries, one-click install, self-upgrade, CI/CD workflows. 863 OCaml tests, 16 Python tests.

### Distribution

- **install.sh rewrite**: Downloads pre-built binaries from GitHub Releases with SHA-512 checksum verification. Supports linux-x64, linux-arm64, macos-x64, macos-arm64. Takes ~5 seconds instead of 10+ minutes. Configurable via `PAR_INSTALL_PREFIX` and `PAR_INSTALL_VERSION` env vars.
- **Source build moved**: Previous install.sh migrated to `scripts/build-from-source.sh` for users who need to compile from source.
- **`par upgrade` command**: New CLI subcommand that checks GitHub Releases for the latest version, downloads the binary for the current platform, verifies SHA-512 checksum, and replaces the running binary in-place. Supports `--check` flag for check-only mode. Platform detection via `uname()`. Self-path resolution via `/proc/self/exe` (Linux) or `Sys.argv` (macOS).
- **release.yml**: GitHub Actions workflow triggers on `v*.*.*` tag push. Builds binaries on ubuntu-latest (linux-x64), macos-15 (macos-arm64), macos-13 (macos-x64). Uploads binaries and `sha512-checksums.txt` to GitHub Release.
- **opam-publish.yml**: Generates tarball via `git archive` and uploads `.opam` files + tarball to GitHub Release. First opam-repository submission is manual.
- **pypi-publish.yml**: Builds `par_capi.so` and Python wheel, uploads to GitHub Release. First PyPI upload is manual.

### CLI

- **New subcommand**: `par upgrade [--check]` — check for and install updates.
- Engine structured logging (`PAR_LOG=info`): conversation lifecycle events (new conversation, resume, LLM call, LLM response).

### Docs & Ops

- **AGENTS.md**: Build & Compilation Rules section (dune commands, .exe suffix, binary install locations, PATH priority, version sync).
- **Version sync**: `make sync-version` target reads `dune-project` version and syncs to `pyproject.toml` and `__init__.py`.
- **check_doc_links.sh**: New script validating relative markdown links.
- **Makefile docs-check**: Orchestrates doc identifier checks and link checks.
- **par_postgres.opam**: Stub package (`available: false`) for the optional PostgreSQL backend.
- **CI matrix**: Expanded to ubuntu-latest + macos-15 + macos-13.

## v0.3.3 (2026-06-06)

> CLI integration fix + MCP config + OPS tech debt + test coverage + Python FFI expansion. 863 OCaml tests, 13 Python tests.

### CLI Fixes (W0)

- **Conversation memory**: REPL now threads conversation history across turns. `Runtime.invoke` accepts `?conversation` and returns `invoke_result` record. `/reset` command clears history. `par ask` remains single-shot.
- **Bash tool wiring**: `setup_runtime` calls `Runtime.install_bash_tool` with `process_mgr` and `clock` from the Eio environment.
- **MCP config**: `~/.par/config.json` accepts `mcp_servers` array. CLI passes MCP server configs to `Runtime.create` with `mcp_process_mgr` and `mcp_clock`.

### API Changes

- `Engine.run_agent` now accepts `?conversation` and returns `(llm_response * conversation, error_category * conversation) result`.
- `Runtime.invoke` now accepts `?conversation` and returns `(invoke_result, error_category * conversation) result`.
- New type `Types.invoke_result = { response : llm_response; conversation : conversation }`.
- All callers updated: `workflow_engine.ml`, `par_capi.ml`, `test_integration.ml`, `examples/otel_tracing.ml`.

### OPS Tech Debt Cleanup (W1)

- **OPS-14**: `Openai_provider.create` and `Anthropic_provider.create` now reject empty `api_key` with `Error (Invalid_input "api_key must not be empty")` instead of silently constructing a client that would fail at first HTTP request. New test file `test/test_provider_api_key.ml` (6 cases).
- **OPS-8**: New accessor `Event_bus.dlq_entries : t -> event list` projects payloads from the DLQ. Complements the existing `get_dead_letters` (which carries envelope + failure metadata) for consumers that only need the original events. New test file `test/test_event_bus_dlq.ml` (2 cases).
- **OPS-9**: `Event_bus.publish` now routes to the DLQ with reason `"buffer full: backpressure"` when the stream is at configured capacity, instead of blocking the caller indefinitely. New test file `test/test_event_bus_backpressure.ml` (4 cases).
- **OPS-11**: New `Validation.validate_temperature` and `Validation.validate_temperature_result` reject NaN, infinity, negatives, and values above 2.0 (the range accepted by OpenAI, Anthropic, Cohere, Mistral). 8 new test cases in `test/test_config_validation.ml`.
- **OPS-12, OPS-13**: Confirmed `max_concurrent_tasks = 0` and `buffer_capacity = 0` were already rejected by `Validation.validate_runtime_config`; tests already in `test/test_config_validation.ml` (`max_concurrent_tasks=0 fails`, `buffer_capacity=0 fails`).
- **OPS-16**: New `Par.Persistence_common` module in `lib/persistence/persistence_common.ml` houses the canonical `extract_task_id` function. Both `Sqlite_persistence` and `Postgres_persistence` now re-export it via a one-line alias, removing 32 lines of duplicated match logic that was at risk of drifting. `Par.Persistence_common` re-exported from the `Par` facade. New test file `test/test_persistence_common.ml` (4 cases).

### Test Coverage (W2)

- **test_middleware.ml**: Unit tests for all 7 middleware (retry, rate_limit, timeout, logging, arg_validation, pii_mask, sanitize_tool_output).
- **test_workflow_engine.ml**: Workflow engine tests — sequential, parallel, conditional, map-reduce, checkpoint, lifecycle.
- **test_providers.ml**: OpenAI/Anthropic provider and HTTP client tests — request format, error handling, streaming.
- Total OCaml tests: 688 → 863 (+175 new).

### Python FFI Expansion (W3)

- 6 new C functions in `par_ffi.h`/`par_ffi.c`: `par_mcp_server`, `par_mcp_list_tools`, `par_workflow_status`, `par_workflow_cancel`, `par_event_subscribe`, `par_version`.
- New Python methods: `Runtime.version()`, `Runtime.mcp_server()`, `Runtime.mcp_list_tools()`, `Runtime.workflow_status()`, `Runtime.workflow_cancel()`.
- `par_capi.ml`: new OCaml callback handlers with `Mcp_types.server_id_of_string` conversion.
- Python tests: 8 → 16 (13 passed, 3 skipped — known Eio scheduler context issue in FFI health/metrics callbacks).

## v0.3.2 (2026-06-06)

> Documentation-only release. Zero code changes. All public docs translated to English.

### Documentation

- **README.md**: rewritten — SDK-first hero section, mermaid architecture diagram, Why-PAR comparison table, 20 built-in tools table, MCP client section with code example, full module reference.
- **docs/index.md**: rewritten as English SDK-first navigation hub (was Chinese placeholder).
- **docs/sdk/overview.md**: expanded from 20-line stub to full SDK hub page with architecture, feature list, and navigation links.
- **docs/sdk/agent.md**: translated to English (agent_config, model_config, Runtime.invoke, tool handler signature).
- **docs/sdk/workflow.md**: translated to English (step types, checkpoints, conditional and map-reduce).
- **docs/sdk/middleware.md**: translated to English (7 built-in middleware plus how to write your own).
- **docs/sdk/tools.md**: translated to English (all 20 built-in tools including the type-safe bash tool).
- **docs/sdk/mcp.md**: translated to English (Mcp_client, Mcp_server, Mcp_types APIs plus event list and security checklist).
- **docs/quickstart.md**: translated to English (full 30-minute tutorial from install to tool calls).
- **docs/howto/concurrency.md**: translated to English (3 concurrency layers, parallel tool execution, rate limiting).
- **docs/howto/custom-llm-provider.md**: translated to English (registering Cohere, Mistral, Ollama, etc.).
- **docs/howto/error-handling.md**: translated to English (error categories, retry policies, cancellation, event bus observability).
- **docs/explanation/architecture.md**: translated to English (module structure, data flow, type system, Eio concurrency model).
- **docs/cli.md**: translated to English (full CLI reference with all options, config wizard, troubleshooting).

### Infrastructure

- **docs/DOC-MAINTENANCE.md**: new file — single source of truth for doc rules (CJK ban, identifier preservation, pre-release checklist).
- **scripts/check_doc_identifiers.sh**: new script — CI gate for OCaml identifier preservation in public docs.
- **CONTRIBUTING.md**: new file — contributor guide with documentation standards section.
- **SECURITY.md**: new file — security policy with supported versions, reporting instructions, threat model.
- **examples/README.md**: new file — describes all example programs in examples/.
- **AGENTS.md**: added 12-item pre-release checklist, identifier-preservation list, CI integration notes.
- **CI badge**: replaced hardcoded build badge with GitHub Actions CI badge URL.

### Test coverage

- 666 OCaml tests and 16 Python tests passing (unchanged from v0.3.1).

## v0.3.1 (2026-06-06)

> 100% 向后兼容，纯 additive，零 breaking change。

### SDK (par)

- **New tool**：`bash` —— 类型化 shell 执行。`argv` 强制为 `string list`（无 `Exec_raw_shell` 构造器），shell 注入在类型层不可表示。
- **New module**：`Par.Bash_safe_command` —— ADT（`sandboxed_path` 私有类型 + `command` 变体 + `risk` 评分）
- **New module**：`Par.Bash_policy` —— `POLICY` 模块类型 + 3 个预置（`Coder` 默认、`ReadOnly`、`ReadOnlyNoNet`）+ `sanitize_env` / `strip_ansi` / `truncate_output` 辅助函数
- **New module**：`Par.Bash_blacklist` —— 31 条正则（`rm -rf /`、`dd of=/dev/`、fork bomb 等）
- **New Runtime API**：`Runtime.install_bash_tool : ?process_mgr:... -> ?clock:... -> runtime -> (unit, error_category) result`
- **New Runtime param**：`Runtime.create ?bash_policy:(module POLICY)`（默认 = `Coder`）
- **New event types**：`Bash_invoked` / `Bash_completed`（在 `Par.Types.event` 里，携带 `risk` 评分与 `argv`）

### Security posture

- 9 维安全机制：CWD 锁定、黑名单、环境脱敏、超时强制、进程组清理、ANSI 剥离、输出截断、event bus 审计、风险评分
- OS 层沙箱（bwrap / landlock）v0.3.1 不提供

### Test coverage

- 165 个新测试，分布在 4 个新测试文件：
  - `test/test_bash_safe_command.ml`（31）
  - `test/test_bash_blacklist.ml`（56：31 正向 + 23 反向 + 2 结构）
  - `test/test_bash_policy.ml`（67）
  - `test/test_bash_runtime.ml`（11）
- 现有 297 个 OCaml 测试全部继续通过（零回归）

### Backward compatibility

- 100% 向后兼容 v0.3.0
- 现有 `~/.par/config.json` 文件以 v0.3.1 默认值加载
- 现有用户代码无需修改即可编译运行（bash 工具通过 `install_bash_tool` 显式启用）

### Documentation

- `docs/sdk/tools.md` —— 新文件，文档化 20 个内置工具（19 个 v0.3.0 + bash）

### MCP stdio client (v0.3.1 W2)

- **New modules**：`Par.Mcp_types` / `Par.Mcp_server` / `Par.Mcp_client` — MCP stdio 协议客户端（JSON-RPC 2.0 over stdin/stdout）
- **New Runtime params**：`Runtime.create ?mcp_servers ?mcp_process_mgr ?mcp_clock ?mcp_startup_policy` — 启动时自动 spawn MCP 子进程，关闭时自动 stop
- **New event types**（7 个）：`Mcp_server_started` / `Mcp_server_failed` / `Mcp_server_stopped` / `Mcp_tool_invoked` / `Mcp_tool_completed` / `Mcp_resource_read` / `Mcp_prompt_rendered`
- **Runtime API**：`Runtime.mcp_servers` / `Runtime.mcp_server` — 按 server_id 查询已连接的 MCP server
- **Startup policy**：`Fail_fast`（任一 server 失败则全部回滚）/ `Log_and_continue`（跳过失败继续）
- **Scope**：stdio transport only
- 20 个新测试：7 event round-trip + 10 runtime integration + 3 facade exposure
- 现有 644 个测试全部继续通过（零回归）

## v0.3.0-post (2026-06-04)

### CLI (par_cli)
- **Breaking**: Agent now constructed via `Runtime.make_agent` smart constructor (validates id, prompt, iterations, tool uniqueness)
- **Breaking**: Tool registration now uses `Runtime.register_tool` (surfaces `Duplicate_tool` errors instead of silently ignoring)
- **Fix**: `--max-iterations` CLI flag now actually works (was parsed but ignored)
- **New**: System prompt generated from built-in template with `{{role}}`, `{{task}}`, `{{available_tools}}`, `{{current_time}}` variables
- **New**: Config fields: `max_iterations`, `max_tokens`, `top_p`, `parallel_tool_execution`, `template_variables`, `system_prompt_template_override`
- **New**: CLI flags: `--max-tokens`, `--top-p`, `--no-parallel-tools`
- **New**: REPL commands: `/help`, `/steer <msg>`, `/followup <msg>`, `/health`, `/metrics`, `/quit`
- **New**: Config wizard asks for agent role, task, max iterations, parallel execution
- Backward-compatible: old `~/.par/config.json` files load with v0.3.0 defaults

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