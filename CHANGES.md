# CHANGES

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