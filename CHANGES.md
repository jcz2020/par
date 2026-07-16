# CHANGES

## v0.7.5 — HNSW vector store + .docx loader + native structured output

> Three features: (1) pure OCaml HNSW vector store backend — zero external deps, works on all platforms including Windows; (2) Word `.docx` document loader via camlzip + xmlm; (3) native structured output for OpenAI/Anthropic replacing text-injection fallback. 1408 tests passing.
>
> **Note**: `vector_store_backend`, HNSW, and `Docx_loader` are OCaml SDK only in this release. Python FFI exposure is tracked for a future version.

### Added — HNSW Vector Store Backend

- **NEW** `lib/core/hnsw.ml` + `hnsw.mli`: Pure OCaml HNSW approximate nearest neighbor search. Implements Algorithms 1-4 from Malkov & Yashunin (TPAMI 2020). Supports cosine and L2 distance metrics. Configurable M, ef_construction, ef_search parameters. Binary persistence via Marshal.
- **NEW** `Types.vector_store_backend`: ADT with `Vs_sqlite_vec` and `Vs_hnsw` variants for backend selection.
- **NEW** `Vector_store.create_for_backend`: Factory function dispatching to sqlite-vec or HNSW backend. `Vector_store.t` internal type changed to variant; all public functions dispatch transparently.
- **NEW** `Runtime.create ?vector_store_backend`: When provided, creates the vector store and stores it in the runtime. `invoke_with_rag` uses it automatically.
- **NEW** `test/test_hnsw.ml` (8 tests) + `test/test_in_memory_vector_store.ml` (2 tests): recall >= 0.8 at 100 vectors, >= 0.7 at 1000 vectors, persistence, delete, dimension mismatch, cosine vs L2.
- **CHANGED** `docs/sdk/rag.md`: Vector store backends section added.

### Added — Word Document Loader

- **NEW** `lib/documents/docx_loader.ml` + `docx_loader.mli`: Extracts text from Word `.docx` (OOXML ZIP). camlzip opens ZIP, xmlm streams `word/document.xml`, extracts `<w:t>` text. Paragraphs → newlines, tabs preserved, field instructions excluded.
- **NEW** `test/test_docx_loader.ml` (6 tests): extraction, metadata, missing file, invalid ZIP, workspace rejection.
- **CHANGED** `dune-project` + `par.opam`: `camlzip` + `xmlm` dependencies.
- **CHANGED** `docs/sdk/document_loaders.md` + `docs/zh/sdk/document_loaders.md`: `.docx` section (EN + ZH synced).

### Changed — Native Structured Output

- **CHANGED** `par_capi.ml`: OpenAI and Anthropic branches now set `complete_structured_fn = Some` instead of `None`. OpenAI uses `response_format: json_schema` (strict), Anthropic uses `output_config: json_schema`. Ollama/Custom keep text-injection fallback.
- **CHANGED** `docs/sdk/agent.md` + `docs/zh/sdk/agent.md`: Structured output section documents native mode.

### Infrastructure

- **CI**: Python binding tests added to ci.yml (Python 3.10-3.13, ubuntu, needs ocaml artifact).
- **CI**: Windows conditional `--with-test` (avoids Cygwin test-dep build failures).
- **CI**: `lib/ffi/dune` — removed `eio.unix` (POSIX-only, unused; eio_main handles platform dispatch).
- **NEW** `Makefile python-test` target.
- **NEW** `bindings/python/tests/test_structured.py`: invoke_structured with-tools integration test (two-phase ReAct→structured path).

## v0.7.4 — json_extract think-tag + fence ordering fix + run_agent_structured

> `extract_json_from_text` processing order bug fixed. New `Engine.run_agent_structured` enables two-phase (ReAct loop + structured output) for agents that need both tools and schema-validated JSON.

### Added — Structured Output + Tools

- **NEW** `Engine.run_agent_structured` — two-phase pattern: Phase 1 runs full ReAct loop with tools (bash, http, custom), Phase 2 makes a separate structured LLM call with the complete conversation history. Follows LangGraph's `create_react_agent(response_format=)` approach. Works across all providers without requiring native `tools + response_format` support.
- **CHANGED** `Runtime.invoke_structured` routing: when `agent.tools <> []`, routes to `run_agent_structured` (two-phase); when `agent.tools = []`, routes to `run_structured` (lightweight, unchanged). Previously `invoke_structured` always used `run_structured` which silently ignored tool calls.
- **CHANGED** `workflow_engine.ml` `Agent_call` with `response_schema` and tools also routes to `run_agent_structured`.

### Fixed — JSON Extraction

- `extract_json_from_text`: move `String.trim` to after `strip_think_tags` and before `strip_markdown_fences`. Without this fix, input like `<think>reasoning</think>\n\`\`\`json\n{...}\n\`\`\`` would fail to strip the markdown fence because the leading `\n` (leftover from think-tag removal) prevented the fence-start check from matching.

## v0.7.3 — Audit Fixes (38 Issues Resolved)

> Full audit of v0.7.0–v0.7.2 codebase found 38 issues (10 P0, 6 P1, 10 P2 doc mismatches, 12 P3 quality). All 38 fixed, verified, and tested. 1387 tests passing.

### Fixed — Memory Module (9 issues)

- `Auto` search mode now resolves dynamically (Hybrid if embeddings available, Keyword_only otherwise) — was dead code returning FTS-only
- `update()` now deletes old row before INSERT — was leaking orphaned rows + embeddings + FTS entries on every update
- Windows `vec0.dll` vendor path added to `sqlite_memory.ml` candidate list
- Embedding dimension validation before blob insert — was silently corrupting vec0 index on mismatch
- FTS5 trigger creation wrapped in `BEGIN`/`COMMIT` transaction
- `close()` logs `db_close` failure instead of silent ignore
- FTS5 availability check closes `:memory:` handle — was leaking DB handle
- `search` uses write lock (`use_rw`) since `bump_usage` performs UPDATE — was using read lock
- Embedding generation errors logged via `Logs.warn` — was silently swallowed

### Fixed — Document Loaders (11 issues)

- PDF loader catches exceptions and returns empty list instead of `failwith` — was crashing entire directory scan
- HTML loader adds `Sys.file_exists` check — was throwing uncaught `Sys_error` on missing file
- HTML loader wraps file handle in `Fun.protect` — was leaking FD on exception
- `LOADER` module type removed (dead code); `make` pattern documented as canonical
- CSV loader wraps `Csv.load` in try/with — was propagating uncaught exception
- `Directory_loader.load` default map = `default_map` — was silently loading zero files without `~map`
- Markdown frontmatter parser handles `\r\n` (Windows line endings)
- PDF loader detects encrypted PDFs via typed `Pdf.PDFError` pattern match
- Directory loader circular symlink protection via `Unix.realpath` + visited set
- CSV column names prefixed with `csv_` to avoid metadata key collision
- HTML `file_size` reports actual file bytes, not cleaned text length

### Fixed — FFI / Native (2 issues)

- 5 FFI functions move `caml_copy_string`/`caml_copy_double` outside `PAR_MUTEX_LOCK` — was risking deadlock from OOM longjmp skipping mutex unlock
- `vec_extension_path` changed from `let` binding to `unit -> string` function — Python binding override was never taking effect

### Fixed — Core Runtime (4 issues)

- `invoke_structured` now accepts `?system_prompt_appendix` and wraps in `Invoke_context.with_context` — was bypassing context entirely
- `run_structured` injects `Invoke_context.appendix_text ()` into system prompt — was missing (unlike `run_agent`)
- Double-appendix on conversation resume fixed: appendix stored in conversation metadata, stripped before re-applying — was accumulating on every resume
- `invoke_handle_cancel` TOCTOU race fixed: `request_cancel` first, CAS loop respects `Completed` — was flipping Cancelled→Completed

### Fixed — SDK Documentation (12 issues)

- `agent_config.system_prompt` type corrected (record, not `string`) in EN + ZH
- `agent_config.cache_strategy` field added to docs
- `Runtime.register_tool` return type updated to `(tool_binding, error_category) result`
- `tool_descriptor` missing fields added: `output_schema`, `on_update`, `cache_control`
- `handler_result` `Handoff` variant documented
- `llm_provider_config.Openai` missing fields added: `embedding_model`, `prompt_cache_key`
- `context_strategy.Truncate_oldest` field renamed to `keep_system` (snake_case)
- `Noop_persistence.create` signature corrected in EN + ZH
- `Sqlite_memory.make_service` return type adds `result` wrapper
- CHANGES.md v0.7.2 duplicate sections removed
- `overview.md` sub-library count corrected (10→11), middleware count (7→8), module map updated
- ZH `agent.md` missing sections translated: System prompt templates + Context strategy

### Fixed — Review Follow-ups (3 issues)

- `fork_invoke` uses `Atomic.compare_and_set` for Completed status — was unconditionally overriding Cancelled
- 11 `system_prompt` examples in 7 doc files corrected to use `Types.stable_prompt`
- Audit findings file marked as resolved

## v0.7.2-beta — Vector Memory, SDK Docs; Windows Platform Code Added (CI Build Pending)

> v0.7.2 ships vector-based semantic memory search (RRF hybrid search) and completes SDK documentation for all v0.7.1 APIs. All changes are SemVer-additive.
>
> **Windows platform status**: The capability registry, FFI shim, workspace path normalization, process spawning gates, and vendored `vec0.dll` are SHIPPED in the codebase. **Windows MinGW CI build is NOT YET GREEN** — `par_ffi.c` has a pointer-type incompatibility on MinGW (line 121: `caml_startup(caml_argv)`). `windows-latest` has been removed from CI matrix until resolved. The platform code is sound and will work on Windows once the MinGW build issue is fixed; expect that fix in v0.7.3.

### Added — Vector-Based Semantic Memory Search

- **NEW** `vec0` virtual table (`memory_entries_vec`) alongside existing FTS5 in `Sqlite_memory`. Configurable dimension (default 1536, cosine distance).
- **NEW** `search_mode` type: `Keyword_only | Vector_only | Hybrid | Auto`. Smart default: Hybrid when `embedding_fn` configured, Keyword_only otherwise.
- **NEW** `embedding_fn` type in `Memory_service` — lightweight function type (`string list -> (float array list, string) result`). Callers bridge from `Types.embedding_service`.
- **CHANGED** `Sqlite_memory.create` accepts `?embedding_fn` + `?dimension`. On `add`, embeds content and stores in vec0 (graceful degradation on failure).
- **NEW** `hybrid_search` function — Reciprocal Rank Fusion (RRF) in a single SQL statement. Over-fetches k×3 from each leg, fuses via `1/(60+rank_fts) + 1/(60+rank_vec)`. Configurable weights and k constant.
- **NEW** vec0 sync triggers — `DELETE` trigger removes embedding on row delete; `UPDATE OF content` trigger drops stale embedding (lazy re-embed pattern).
- **FIX** `search_vec` SQL: use vec0 `k = ?` constraint instead of `LIMIT ?` (vec0 requires `k = ?` in subqueries).
- **NEW** `Embedding_unavailable` error variant in `memory_error`.
- **NEW** `test/test_sqlite_memory_schema.ml` (5 tests), `test/test_memory_embedding.ml` (11 tests), `test/test_hybrid_search.ml` (7 tests), `test/test_vec_triggers.ml` (4 tests), `test/test_memory_search_modes.ml` (11 tests).

### Added — SDK Documentation Completion

- **NEW** `docs/sdk/invoke_context.md` + ZH — per-call isolation, `invoke_async`, `?context`, `?system_prompt_appendix`.
- **NEW** `docs/sdk/persistence.md` + ZH — persistence service CRUD, `?scope` dimension, SQLite/Noop backends.
- **CHANGED** `docs/sdk/agent.md` + ZH — fixed `Runtime.invoke` (7 missing params) and `Runtime.create` (9 missing params) signatures. Added `invoke_async` section. Fixed return type (`invoke_result` not `llm_response`).
- **CHANGED** `docs/sdk/tools.md` + ZH — tool count 20 → 23 (added `recall_memory`, `remember_memory`, `search_history`).
- **CHANGED** `docs/sdk/memory.md` + ZH — fixed signatures to match `.mli`, documented `search_mode` + `embedding_fn` + RRF hybrid search.
- **CHANGED** `docs/sdk/overview.md` + ZH — refreshed module map (added Capability, Invoke_context, Deprecation, Memory_service), tool count, platform support section.
- **CHANGED** `docs/sdk/observability.md` + ZH — documented `Atomic.t` counters + `Metrics.merge_into`.

### Added — Windows Platform Code (CI Build Pending)

- **NEW** `lib/core/capability.{ml,mli}` — runtime capability registry. Single source of truth for platform-specific feature detection (`Process_spawning`, `Pipe_io`, `Signal_based_kill`). Returns `Available`/`Unavailable status` with actionable error messages. On Linux/macOS: all `Available`. On Windows: `Unavailable` until MinGW build is resolved.
- **CHANGED** `lib/ffi/par_ffi.c` — `#ifdef _WIN32` guards added: `SRWLOCK` replaces `pthread_mutex_t`, `InterlockedExchange`/`InterlockedCompareExchange` replace GCC atomics. POSIX path unchanged. **Known issue**: `caml_startup(caml_argv)` at line 121 triggers "incompatible pointer type" on MinGW. Fix planned for v0.7.3.
- **CHANGED** `lib/core/workspace.ml` — cross-platform path handling: `HOME` → `USERPROFILE` → `HOMEDRIVE+HOMEPATH` fallback chain; drive-letter-aware colon rejection (`C:\` allowed, `foo:bar` rejected); `is_absolute_path` detects Unix `/`, Windows `C:\`, and UNC `\\server\share`.
- **CHANGED** `lib/core/runtime.ml` — bash tool checks `Capability.detect \`Process_spawning` before `Eio.Process.spawn`. Returns typed error on unavailable platforms (including Windows).
- **CHANGED** `lib/mcp/mcp_transport_stdio.ml` — MCP stdio transport gated behind capability check.
- **NEW** `vendor/sqlite-vec/windows-x86_64/vec0.dll` — pre-built MSVC sqlite-vec extension for Windows (KERNEL32.dll only, 289KB). Will be activated once MinGW build is fixed.
- **CHANGED** `lib/ffi/par_capi.ml` — `vec_extension_path` handles `Sys.os_type = "Win32"` → `vec0.dll` lookup.
- **CHANGED** `.github/workflows/ci.yml` — `windows-latest` REMOVED from OS matrix (pending MinGW build fix). Will re-add once `caml_startup` pointer issue is resolved.

### Fixed — CI Build & Test Stability

- **FIX** `dune-project` package depends were missing `camlpdf`, `csv`, `sexplib0` (v0.7.0 document loaders' opam deps were never declared — pre-existing bug, masked by earlier build failures).
- **FIX** `lib/memory/sqlite_memory.ml` `resolve_vec_extension_path` — added dune build directory candidates (`../lib/ffi/`) so CI tests can find `vec0.so` from `_build/default/test/` working directory.
- **FIX** `macOS` `so_name` detection — `Sys.file_exists "/System/Library"` instead of unreliable `PAR_OS` env var.
- **FIX** `load_vec_extension` — now catches `Failure` exception from `Sqlite3.enable_load_extension` on macOS CI (where extension loading is disabled).
- **FIX** 11 test files — added platform/env guards (`Sys.file_exists "/tmp/opencode"` for fixtures, `Sys.os_type = "Win32"` for Windows process tests, `macos_skip` for macOS path differences).

### Tests

- 1306 → 1387 tests passing (+81 new tests).
- New test files: `test_capability.ml` (8), `test_capability_gating.ml` (4), `test_workspace_paths.ml`, `test_sqlite_memory_schema.ml` (5), `test_memory_embedding.ml` (11), `test_hybrid_search.ml` (7), `test_vec_triggers.ml` (4), `test_memory_search_modes.ml` (11).
- CI: Ubuntu ✅, macOS ✅, Windows pending (MinGW build fix), Python bindings pending.

---

## v0.7.1 — Concurrency, Memory, Persistence Scope, Deprecation, Dynamic Prompt

> v0.7.1 is the largest PAR SDK release yet, addressing 9 of 10 issues in a single iteration. The foundational change is the `invoke_context` per-call isolation layer (hybrid typed-record + Eio.Fiber carrier) that makes `Runtime.invoke` safe for reentrancy, parallelism, and background async execution — with **zero breaking changes** (all additive). Windows support (#5) is deferred to v0.7.2 per user direction.

### Added — Concurrency Architecture (#1, #3, #10)

- **NEW** `lib/core/invoke_context.{ml,mli}` — typed `invoke_context` record carrying per-call `session_id`, `Metrics` accumulator, skill/hook snapshots, and per-call steering/followup queues. Delivered via `Eio.Fiber.with_binding` — propagates to forked fibers (parallel tools, workflow steps, nested invokes). `Engine.run_agent` signature unchanged.
- **NEW** `invoke_handle` type + `invoke_async` function on `Runtime` — mirrors `submit_workflow_async` shape (fork under `rt.cancellation_root`, track status, emit events). Returns handle with `await`/`cancel`/`status`.
- **NEW** `?context:invoke_context` optional parameter on `Runtime.invoke` (additive, non-breaking).
- **CHANGED** `Metrics.counters` fields → `Atomic.t` for race-free concurrent increments. Added `Metrics.merge_into` for atomic accumulator merge.
- **CHANGED** `Expression.visit_count` moved from module-level ref to fiber-local key (with non-Eio fallback).
- **NEW** `test/test_concurrency.ml` — 6 concurrency tests (session_id isolation, metrics isolation, hooks isolation, async handle lifecycle, expression visit_count, auto-skill override).
- **NEW** `test/test_fiber_spike.ml` — permanent spike-gate artifact documenting that `Eio.Fiber.with_binding` propagates into `fork_promise` children.

### Added — Memory Abstraction Module (#8)

- **NEW** `lib/memory/` subdirectory (mirrors `lib/documents/` precedent):
  - `module type MEMORY_SERVICE` + `memory_service` closure record (mirrors `llm_service` pattern).
  - `memory_object` record: `id`, `content`, `summary`, `scope`, `metadata`, `categories`, timestamps, `source`.
  - `Sqlite_memory` — default FTS5 backend (porter+unicode61 tokenizer, BM25 ranking, sync triggers, ADD-only lifecycle).
  - `memory_error` ADT: `Not_found`, `Invalid_scope`, `FTS5_unavailable`, `Database_error`.
- **NEW** 3 builtin tools: `recall_memory`, `remember_memory`, `search_history` — read per-call scope from `Invoke_context.get_current_exn().session_id`.
- **NEW** `service_registry` gains `memory : memory_service option` (additive, mirrors `embeddings` pattern).
- **NEW** `Runtime.create` accepts `?memory:memory_service` optional param.
- **NEW** FFI parses `{"memory":{"backend":"sqlite","path":"..."}}` config.
- **NEW** `test/test_memory.ml` — 12 unit tests + `test/test_memory_tools.ml` E2E scope isolation test.
- Vector-based semantic recall deferred to backlog (P0, user prioritizes).

### Added — Workflow `response_schema` (#2)

- **NEW** `response_schema : Yojson.Safe.t option` field on `Agent_call` workflow step (default `None`, decoder uses `[@deriving.yojson.default None]` for backward compat with existing workflow JSON files).
- **NEW** When `Some _`, workflow engine routes through `Engine.run_structured` (schema-validated output + repair loop) and exposes validated JSON as `result.output` for downstream `Conditional` dot-path access.
- **NEW** Dependency: `jsonschema-validation` (opam, 0.1.0).

### Added — Persistence Session Scope Dimension (#4)

- **NEW** Generic `scope : string option` indexed column on `events` and `conversations` tables. Applications use this to partition sessions by arbitrary dimensions (workspace_id, user_id, tenant_id). Scope name is generic — no baked-in dimensions.
- **NEW** `?scope:string` optional parameter on persistence CRUD functions: `save_events`, `load_events_by_session`, `load_sessions`, `save_conversation`, `load_most_recent_conversation`. All optional (backward compatible).
- **NEW** Idempotent schema migration via `PRAGMA table_info` check (replaces silent `ALTER TABLE` error swallowing).
- **NEW** Indexes `idx_events_scope` and `idx_conversations_scope`.

### Added — Deprecation Framework (#6)

- **NEW** `lib/core/deprecation.{ml,mli}` — reusable `warn_once` helper with idempotent per-`fn_name` logging (Hashtbl-backed) + event bus emission. Thread-safe via `Eio.Mutex`.
- **NEW** `Deprecated_api_called` event variant on `Types.event` bus (with yojson). Fired the first time a deprecated API is called in this process.
- **NEW** Retrofitted `[@@deprecated]` OCaml annotations on recently-broken APIs.
- **CHANGED** `lib/middleware/timeout.ml` refactored to use the new `Deprecation` module.
- **NEW** `docs/migration/v0.7.1.md` (EN) + `docs/zh/migration/v0.7.1.md` (ZH) — consolidated upgrade guide.

### Added — Per-turn Dynamic System Prompt (#7)

- **NEW** `system_prompt_appendix : string option` field on `invoke_context`.
- **NEW** `?system_prompt_appendix:string` optional parameter on `Runtime.invoke`, `Runtime.invoke_generate`, `Runtime.invoke_async`. Appended AFTER template render + skill overlay + synthesized tool suffix, BEFORE conversation creation. Covers all 3 prompt-construction paths: invoke (`engine.ml`), generate (`generate.ml`), handoff (`engine.ml`).
- **NEW** Conversation resume: appendix appended to existing system message in-place (not duplicated).

### Fixed — Auto-skill `system_prompt_override` Bug (#9)

- **FIXED** `trigger=Auto` skills no longer apply `system_prompt_override`. Previously, Auto-trigger skills with `system_prompt_override` silently replaced the agent's system prompt every turn. Now, the produced `skill_effect` has `system_prompt_override = None` when `trigger=Auto` — only `tool_filter_overlay` is honored. Affects builtin skills `summarizer` and `rag-assistant`.

### Fixed — FFI Persistence Wiring (#4 bug)

- **FIXED** FFI path at `par_capi.ml` now wires parsed persistence config into `Runtime.create`. Previously, Python users who configured SQLite persistence in JSON config silently got `noop_persistence` — events, conversations, sessions were never persisted via the Python binding.

### Tests

- 1270 → 1306 tests passing (+36 new tests).
- New test files: `test_concurrency.ml` (9), `test_fiber_spike.ml` (exit-code based), `test_deprecation.ml` (5), `test_memory.ml` (12), `test_memory_tools.ml` (3).
- Extended: `test_skill_e2e.ml` (flipped #9 assertion), `test_skill_user_activation.ml`, `test_generate.ml`, `test_workflow_engine.ml`, `test_sessions.ml`.

### Backward compatibility

- All changes are SemVer-additive (no breaking changes). Existing callers compile and run unchanged.
- `Agent_call` variant gains `response_schema` with `[@@deriving.yojson.default None]` — existing workflow JSON files decode unchanged.
- `?scope`, `?context`, `?system_prompt_appendix`, `?memory` are all optional parameters — omitting them preserves v0.7.0 behavior.

### Scope deferrals (R2-compliant)

- **Windows process support (#5)**: deferred to v0.7.2 per user direction. Eio Windows backend is materially incomplete (Issue #125 open since Jan 2022).
- **Vector-based semantic recall**: deferred to backlog (P0, user prioritizes). SQLite FTS5 keyword search is the v0.7.1 default.

### Added

- **NEW** `response_schema : Yojson.Safe.t option` field on `Agent_call` workflow step (default `None`, decoder uses `[@deriving.yojson.default None]` for backward compat with existing workflow JSON files).
- **NEW** `lib/jsonschema_validation.ml` wrapper exposing `Jsonschema_validation.compile` and `Jsonschema_validation.validate` for `Jsonschema_validation.Draft2020_12` (draft-07) schema validation. Used by the workflow engine for additional `response_schema` validation.
- **NEW** Dependency: `jsonschema-validation` (opam, 0.1.0, draft-07 keywords).
- **NEW** Tests in `test/test_workflow_engine.ml`: regression guard for `None` path, schema-validated happy path, repair loop, and `Conditional` referencing `result.output.*` via dot-paths.

### Backward compatibility

- Existing 2-field `Agent_call` constructions in OCaml code now require `response_schema = None` (additive field).
- Existing workflow JSON files (e.g. `examples/sequential_workflow.json`, `examples/test_workflow.json`) decode unchanged — the missing `response_schema` key defaults to `None` via the `[@deriving.yojson.default None]` attribute.

## v0.7.0-beta — Document Loaders Framework

> PAR RAG previously only accepted raw strings. Document loaders turn real files (text, Markdown, HTML, CSV, PDF) into `Document.t` records that plug directly into the existing `Chunking` + `Vector_store` + `invoke_with_rag` pipeline, unlocking real-world RAG.

### Added

- **NEW** `Document` module (`lib/documents/document.ml`): `Document.t` record with `content`, `metadata` (Hashtbl of Yojson values), and `source` fields. Includes `Meta` submodule (`empty`/`singleton`/`add`/`add_string`/`add_int`/`to_yojson`/`of_yojson`) and `module type LOADER` (`lazy_load` canonical, `load` convenience).
- **NEW** `Text_loader`, `Markdown_loader` (with YAML frontmatter via `Yaml`), `Html_loader` (via lambdasoup), `Csv_loader` (row-per-Document), `Pdf_loader` (via camlpdf `Pdftext` simple text extraction) — each producing `Document.t list`.
- **NEW** `Directory_loader` with extension-dispatch `default_map` and custom map support.
- **NEW** `Load_error` ADT: `File_not_found`, `Permission_denied`, `Unsupported_format`, `Extraction_failed`, `Workspace_rejected`.
- **NEW** Public API: `Par.Document`, `Par.Text_loader`, `Par.Markdown_loader`, `Par.Html_loader`, `Par.Csv_loader`, `Par.Pdf_loader`, `Par.Directory_loader`.
- **NEW** Dependencies: `camlpdf` (PDF), `csv`, `omd` (Markdown), all LGPL+OCaml-linking-exception (MIT-compatible).
- **NEW** ROADMAP `docs/v0.7.0-ROADMAP.md` with 12 section 11.3 decisions documented.

### Limitations (scope compromises, R2 retirement plans in ROADMAP)

- `.docx` (Word) deferred to v0.7.1 (no maintained OCaml library; DIY is fragile).
- PDF loader uses simple text-stream extraction; no layout preservation, no OCR. Trigger for layout-aware extraction: downstream failure rate >20% or v0.8.

### Tests

- 21 new tests covering Document type, 5 loaders, Directory loader, E2E RAG.
- Total test count: 1249 → 1270, all passing.

---

## v0.6.9 — Bash Cwd Fix + Raw SQLite Accessor

> Two changes driven by integration feedback: a silent security bug in the bash tool's cwd handling, and a new accessor for downstream projects that need to extend the SQLite schema (e.g. FTS5 memory tables).

### Fixed — bash handler did not pass cwd to spawned process

- **Root cause**: `Eio.Process.spawn` in `make_bash_handler` was called without `~cwd`. All bash commands ran in the PAR process's cwd regardless of the `cwd` parameter the user passed. The `Workspace.admit` validation was decorative — it validated the path but the spawned process never used it.
- **Fix**: `install_bash_tool` now requires a `?fs` parameter (typically `Eio.Stdenv.fs env`). The handler constructs `Eio.Path.(fs / Workspace.to_string cwd)` and passes it as `~cwd` to `Eio.Process.spawn`.
- **Breaking**: `Runtime.install_bash_tool` gained a required `?fs` parameter. Callers must pass `~fs:(Eio.Stdenv.fs env)`.
- **Test**: regression test `spawn cwd reaches process (regression for runtime.ml:510)` — invokes `pwd` with a specific cwd and asserts stdout equals the expected directory.

### Added — `Sqlite_persistence.raw_sqlite3_db : t -> Sqlite3.db`

- Downstream projects that need to create FTS5 virtual tables, custom indexes, or run raw SQL on the same database can now access the underlying handle.
- The accessor bypasses the internal mutex — callers are responsible for thread safety.

### Stats

- 1249 tests (1248 existing + 1 new regression test)
- Linux CI: green
- macOS CI: pending

---

## v0.6.8 — Fix Fresh-Switch Compilation

> v0.6.7 tag had two missing dependency declarations that caused `opam install par` from a fresh switch to fail with `Unbound value string_jsonschema` and `Library "eio_main" not found`. Local incremental builds passed due to stale `.cmx` artifacts; CI fresh switches and clean `opam install` exposed the gap. v0.6.8 is the first release that installs cleanly from scratch.

### Fixed — `ppx_deriving_jsonschema` version pin

- **Root cause**: `par.opam` had no version constraint on `ppx_deriving_jsonschema`. Local switch had `0.0.1` (PPX auto-generates `string_jsonschema` inline); CI/fresh switches installed `0.0.8` (PPX generates bare references expecting an `open` that doesn't exist in source). The two versions have fundamentally different code-generation behavior.
- **Fix**: `(ppx_deriving_jsonschema {= "0.0.1"})` in `dune-project` + `par.opam`. Pinning to 0.0.1 also avoids dragging in `melange` + `server-reason-react` (heavy deps PAR doesn't need — pure native OCaml).

### Fixed — `eio_main` dependency

- **Root cause**: `lib/ffi/dune` links `eio_main` and multiple test files call `Eio_main.run`, but `eio_main` was never declared in `par.opam` depends. Local switch had it transitively; fresh switches didn't. This error was masked by the `string_jsonschema` error (which compiled first).
- **Fix**: Added `eio_main` to `dune-project` + `par.opam` depends.

### Stats

- 1248 tests (unchanged from v0.6.7)
- 0 code changes — only `dune-project` + `par.opam` metadata fixes
- Linux CI: green (build + runtest)
- macOS CI: build green, runtest exit-code 1 (pre-existing test-env issue, unrelated to compilation)

---

## v0.6.7 — Remove CLI + SDK Installer Wizard

> PAR is an SDK/runtime. Product-level UX (REPL, config wizard, history/stats) lives in the separate **PAR Code** project in another repo. This release removes the parallel CLI from PAR (caused user confusion about which to install and maintenance drag on engine devs) and replaces `install.sh` with an interactive SDK installation wizard.

### Removed — CLI application

- Entire `bin/` directory (`main.ml` 1741 lines + `cli_style.ml/mli` + `par_config.ml` + `repl_input.ml` + `dune`) — the CLI was a complete product, not a thin wrapper
- `par_cli` opam package block from `dune-project` + `par_cli.opam` (the package was never successfully published to opam-repository, so deletion has zero external impact)
- `test_cli_args.ml`, `test_cli_dispatch.ml`, `test_session_resume_cli.ml` (3 CLI tests)
- `docs/cli.md` (CLI reference)
- CLI sections from `docs/index.md` (CLI is not a surface anymore)
- README hero rewritten: no more `curl install.sh | bash → par ask`; lead with `pip install par-runtime` + Python agent example
- From 3 user surfaces (OCaml SDK / Python / CLI) to 2 (OCaml SDK / Python)

### Added — Interactive SDK installer wizard (rewrites `install.sh`)

The new `install.sh` (231 lines, replaces the 175-line binary-downloader):

- Detects OS (Linux/macOS) + arch (x86_64/arm64)
- Prompts Python vs OCaml (`--python` / `--ocaml` to skip)
- Validates environment: Python → `python3 ≥ 3.8` + `pip`; OCaml → `opam ≥ 2.1` + a `par` switch with `OCaml ≥ 5.4`
- Offers opt-in auto-setup (medium aggressiveness per v0.6.7 ROADMAP):
  - Missing opam → runs official installer to `~/.opam` (no sudo, no system package manager touches); user must confirm
  - Missing Python → prints install instructions, does NOT auto-install (system Python is too risky to touch)
  - `--no-auto-setup` flag to skip offering
- Installs the chosen variant: `pip install --user par-runtime` (Python) or `opam install -y par` (OCaml)
- Verifies via import (Python: `from par_runtime import Runtime`) or `opam list --installed par` (OCaml)
- Prints language-specific quickstart

Flags: `--python`, `--ocaml`, `--yes`, `--no-auto-setup`, `--help`.

### Changed — CI / build / docs

- `ci.yml`, `nightly.yml`: `opam install par_cli --deps-only` → `opam install par --deps-only`; `par_cli.opam` removed from `opam-local-packages`
- `opam-publish.yml`: `par_cli.opam` removed from publish + upload list + manual instructions
- `pypi-publish.yml`: `opam install par_cli` → `opam install par`
- `release.yml`: entire `build` job (binary build/upload) deleted; `release` job kept (creates the GitHub release with notes from CHANGES.md pointing to `pip install par-runtime` / `opam install par`)
- `Makefile`: `install`/`uninstall` targets now print info stubs (no binary to install); `install-dev` keeps `.so` + version sync but verifies via `par_runtime.__version__` instead of `par --version`
- `AGENTS.md`: `dune build bin/main.exe` → `dune build`

### Stats

- 1260 → 1248 tests (-12 from CLI test removal; no other test changes)
- 0 public type signature changes to `par`
- `par` opam package unchanged (same deps, same description)
- Internal-only release — no external users affected (par_cli never published)

---

## v0.6.6-beta.20260703 — Per-Run Workspace Override

> *Shipped as beta; merged into v0.6.7 stable without a separate v0.6.6 stable tag (user opted to iterate on beta). The `?workspace` override + `per_call_registry` mechanism described here ships in v0.6.7.*

> Adds `?workspace` parameter to `Runtime.invoke`, `Runtime.submit_workflow`, `Runtime.submit_workflow_async`, and `Runtime.invoke_workflow_sync`. When provided, overrides the runtime's workspace for THAT specific invocation — enabling one process to serve N concurrent workflows each isolated to its own worktree root. Closes the architectural gap identified by Oracle Option E verification of v0.6.5: workspace is now per-run, not just per-runtime. All 7 admission-using builtin tools (bash + read/ls/find/grep/write/edit) honor the override.

### Added — `?workspace` on 4 API entry points

- `Runtime.invoke ... ?workspace:Workspace.workspace ...`
- `Runtime.submit_workflow ... ?workspace ...`
- `Runtime.submit_workflow_async ... ?workspace ...`
- `Runtime.invoke_workflow_sync ... ?workspace ...` (forwards to `submit_workflow`)

When omitted, `effective_workspace` defaults to `rt.workspace` (v0.6.5 behavior — fully backward compatible).

### Added — `per_call_registry` + rebuild mechanism

- `Runtime.per_call_registry ~rt ~workspace : Tool_registry.t` — builds a fresh tool registry for a single invocation. Copies all caller-registered tools, then rebuilds the builtin tools (bash via `rt.bash_rebuild`, file tools via `rt.file_tools_rebuild`) against `rt' = { rt with workspace }`. `handler_fn` signature unchanged (Yojson -> cancellation_token -> result) — no cascade to middleware/FFI/test handlers.
- `Runtime.register_file_tools_rebuild rt rebuild` — called by the entity registering builtin tools (e.g. CLI) to register a closure that rebuilds file tools bound to a given workspace (capturing the Eio switch + net). Read by `per_call_registry`.
- `Tool_registry.copy_all ~src ~dst` — seeds a fresh registry with caller-registered tools.
- `mutable bash_rebuild` / `mutable file_tools_rebuild` fields on the `runtime` record (private — not a public API change).

### Non-goals (deferred to v0.7)

- `?workspace` on `resume_workflow` / `approve_workflow` — workspace is locked to the workflow instance at `submit_workflow` time; resume/approve operate on that instance and should not switch workspace mid-run.
- Per-call override for user-registered custom tools — `register_tool` signature change is a SemVer break, deferred to v0.7 (§11 R3a two-step). Workaround: re-register custom tools with the effective workspace before invoking, or use `per_call_registry` directly.

### Stats

- 1254 → 1260 tests (6 new: 4 per_call_registry isolation + 1 file-tool override + 1 e2e invoke ?workspace via Mock provider)
- 0 public type signature changes to `handler_fn`
- Backward compatible — all additions are optional labeled parameters

---

## v0.6.5 — Workspace Abstraction: Exile Sys.getcwd from Security Primitives

> Introduces `Workspace` module as the sole authority for path admission. `Sys.getcwd()` is removed from every security primitive; workspace is an unforgeable `private` value threaded mandatorily through `runtime` and `exec_context`. Multi-root support from day one (for future git-worktree isolation). Bundles a security fix: file tools (read/ls/find/grep/write/edit) now have the sensitive-prefix check they were previously missing. Triggered by integration feedback on worktree-per-task workflows.

### BREAKING — Type signature changes

| # | Old API | New API | Migration |
|---|---------|---------|-----------|
| 1 | `Bash_safe_command.sandboxed_path` type | `Workspace.sandboxed_path` (moved) | Update all type references to `Workspace.sandboxed_path` |
| 2 | `Bash_safe_command.sandboxed_path_of_string : string -> (...) result` | `Workspace.admit : workspace -> string -> (...) result` | Pass workspace as first arg; obtain via `rt.workspace` |
| 3 | `Bash_safe_command.sandboxed_path_cwd : unit -> sandboxed_path` | REMOVED | No ambient authority; construct workspace explicitly via `Workspace.of_cwd ()` |
| 4 | `Bash_safe_command.sandboxed_path_to_string` | `Workspace.to_string` | Rename call sites |
| 5 | `Bash_safe_command.make_exec ~argv ?(cwd = sandboxed_path_cwd ())` | `Bash_safe_command.make_exec ~argv ~cwd` (mandatory) | Always pass `cwd` explicitly |
| 6 | `Builtin_tools.builtin_tools ~switch ~net` | `Builtin_tools.builtin_tools ~switch ~net ~workspace` | Pass workspace at registration |
| 7 | `Workflow_engine.exec_context` (no workspace) | `exec_context` (with mandatory `workspace` field) | Add `workspace = rt.workspace` at construction |
| 8 | `Runtime.runtime` record (no workspace) | `runtime` record (with `workspace` field) | Constructed at startup via `Workspace.of_cwd ()` |

### New — `Workspace` module (`lib/core/workspace.ml`)

- `type workspace = private { roots : string list; policy : workspace_policy }` — unforgeable, multi-root
- `type sandboxed_path = private Path of string` — moved from `Bash_safe_command`
- `Workspace.of_cwd`, `Workspace.of_dir`, `Workspace.of_dirs` — constructors (canonicalize roots via `Unix.realpath`, fail-closed on non-existent dirs)
- `Workspace.admit` — validates paths (rejects `..`, `:`, sensitive prefixes; ADMITS absolute paths under workspace root — the key behavioral change)
- `Workspace.default_policy` — carries sensitive-prefix list (was a global function, now travels with workspace)

### Security improvement — File tools sensitive-prefix check

Previously, `read`/`ls`/`find`/`grep`/`write`/`edit` had inline 3-check validation (no `..`, no absolute, no `:`) but were MISSING the sensitive-prefix check that `bash` had. All 6 tools now route through `Workspace.admit`, getting the sensitive-prefix check for free.

### Changed — Sys.getcwd exile

`Sys.getcwd()` is now called in exactly ONE security-relevant place: `Workspace.of_cwd ()` at runtime startup. Three convenience sites remain (skill_loader, par_capi, main — resource discovery, not security).

---

## v0.6.4-beta.5 — Oracle-Driven Wire-Level Fixes (BETA, IN PROGRESS)

> Fixes 7 blocking issues found by Oracle verification: cache_control markers now actually reach Anthropic's wire format (were silently dropped). FFI parsing bugs fixed. Both_prompts semantic corrected. 1201 tests passing.

### Fixed — Provider wire-level cache_control emission (CRITICAL)

- **FIX** `anthropic_provider.ml:extract_system_prompt` — returns `content_block list option` instead of `string option`. System prompt cache_control markers are no longer flattened to string and lost.
- **FIX** `anthropic_provider.ml:build_request_body` — emits `("system", `List [...])` with per-block cache_control instead of `("system", `String s)`.
- **NEW** `anthropic_provider.ml:emit_block_with_cache` — canonical block-to-wire serializer handling ALL 4 content_block variants (Text_block, Tool_use_block, Tool_result_block, Image_block) with cache_control preservation. Replaces the old `text_blocks_json` helper that only handled Text_block.
- **FIX** `anthropic_provider.ml:build_message_json` — uses `emit_block_with_cache` for all blocks. Tool_result and Tool_use blocks now preserve their cache_control markers.
- **FIX** `anthropic_provider.ml:tool_descriptor_to_json` — emits `cache_control` field when present on the tool_descriptor. `mark_tool` now has end-to-end wire-format effect.

### Fixed — Engine architecture

- **FIX** `engine.ml:build_breakpoint_candidates` — removed auto-guessed `` `Tool i `` breakpoint (priority 50). Tool caching is now ONLY through explicit `mark_tool` (user intent, per ROADMAP B.3). Pre-marked tools (priority 60) remain.
- **FIX** `engine.ml:apply_breakpoints` — removed Tool-location handling entirely. Eliminates the namespace confusion where tool-list index was matched against message-list index. Tool cache_control is handled by `tool_descriptor_to_json` directly.

### Fixed — FFI parsing bugs

- **FIX** `par_capi.ml:parse_cache_strategy` — bare string `"with_cache_of"` now fails-fast with clear error message (was silently downgrading to `No_caching`).
- **FIX** `par_capi.ml:parse_skill_descriptor` — `system_prompt_override` now accepts 3 JSON forms: bare string → `Stable_prompt` (backward compat), tagged object `{"zone":"stable|volatile|both",...}` → corresponding variant, fallback → `Stable_prompt`. Previously ALL overrides were silently `Stable_prompt`.

### Fixed — Semantic bug

- **FIX** `runtime.ml:apply_skill_effect_to_config` — `Both_prompts { stable; volatile }` now concatenates `stable ^ "\n" ^ volatile` and marks as volatile. Previously discarded the volatile string and used only the stable string while still marking as volatile (worst-of-both-worlds).

---

## v0.6.4-beta.4 — All Deferred Features Completed (BETA, IN PROGRESS)

> Completes ALL previously-deferred v0.6.4 items: mark_cache_breakpoint user-facing API (ROADMAP B.3), skill_prompt_zone ADT (ROADMAP B.5.1), B.4 hard-fail upgrade. 3 breaking changes, 13 new tests, 1201 total passing.

### BREAKING in 0.x (3 changes)

| # | Old API | New API | Migration |
|---|---|---|---|
| 1 | `tool_descriptor` (no `cache_control`) | `tool_descriptor` (with `cache_control : cache_control option`) | Add `cache_control = None` to all 30+ construction sites (mechanical) |
| 2 | `skill_effect.system_prompt_override : string option` | `skill_prompt_zone option` | Wrap `Some "text"` → `Some (Stable_prompt "text")` (or `Volatile_prompt` / `Both_prompts`) |
| 3 | `make_agent` soft-fail on volatile + `With_cache_of` | Hard-fail: returns `Error (Invalid_input _)` | Callers with volatile prompts + caching must switch to `stable_prompt` or drop caching |

### Added — mark_cache_breakpoint user-facing API (ROADMAP B.3)

- **NEW** `Cache_breakpoint.mark_tool : ttl:cache_ttl -> tool_descriptor -> tool_descriptor` — sets `cache_control` on a tool descriptor, marking it for prompt caching.
- **NEW** `Cache_breakpoint.mark_message : ttl:cache_ttl -> message -> message` — sets `cache_control` on the LAST content_block of a message. No-op on empty `content_blocks` (MINOR #19).
- **NEW** `Engine.build_breakpoint_candidates` now scans for pre-marked tools (user used `mark_tool`). Pre-marked tools get priority 60 (higher than auto-guessed 50), ensuring user intent is respected by the budget manager.
- The auto-caching mechanism (System pri 100, last tool pri 50, last user msg pri 10) continues to work alongside user marks. The budget manager drops lowest-priority when over provider cap.

### Added — skill_prompt_zone ADT (ROADMAP B.5.1)

- **NEW** `type skill_prompt_zone = Stable_prompt of string | Volatile_prompt of string | Both_prompts of { stable : string; volatile : string }` — classifies skill prompt overrides at load time.
- `skill_effect.system_prompt_override` and `skill_descriptor.system_prompt_override` changed from `string option` to `skill_prompt_zone option`.
- `apply_skill_effect_to_config` now matches 3 variants: `Stable_prompt s` → `stable_prompt s` (preserves prior behavior); `Volatile_prompt s` → `volatile_prompt s` (forces volatile, cache-busts); `Both_prompts { stable; _ }` → `volatile_prompt stable` (conservative: any volatile component → whole prompt volatile).
- `Runtime.make_skill` parameter `?system_prompt_override` now takes `skill_prompt_zone` (was `string`).
- FFI JSON parser + skill_loader classify parsed strings: default `Stable_prompt` (preserves prior behavior for existing skills).
- `bin/main.ml` skill display extracts the inner string from the ADT for display.

### Changed — B.4 hard-fail (was soft-fail)

- `Runtime.make_agent` now returns `Error (Invalid_input "cache_strategy requires Zone_stable system_prompt, got Zone_volatile")` when `With_cache_of _` is requested with a `Zone_volatile` system prompt. Previously downgraded to `No_caching` with `Logs.warn`.
- Removed dead code: `register_agent` no longer emits `Cache_strategy_skipped { reason = \`Volatile_system }` (make_agent errors before agent exists). The event variant remains declared for other future emit paths.
- The 2 affected tests in `test_stable_volatile_prompts.ml` flipped from `Ok agent with No_caching` → `Error (Invalid_input _)`.

### Added — Tests (13 new)

- **NEW** `test/test_cache_breakpoint_api.ml` — 8 tests: `mark_tool` with `Five_min`/`One_hour` TTLs, field preservation, `mark_message` on single/multiple/empty blocks, `Tool_result_block` variant, message field preservation.
- **NEW** `test/test_engine_breakpoint_candidates.ml` — 5 tests: no marked tools (standard 3 candidates), one marked tool (priority 60), multiple marked tools, `One_hour` ttl propagation, mixed marked + unmarked.

### Architecture (per STRATEGY §11 "一次做对")

- All 3 features use runtime zone_tag mechanism (phantom types excluded by OCaml record-field limitation per commit `6a22c7f`). No existential type design needed.
- The mark_cache_breakpoint API operates on already-validated values (B.4 check happened at construction). No compile-time phantom type enforcement needed.
- `skill_prompt_zone` is a regular ADT, not phantom-typed. Skill classification happens at load time (skill_loader) or construction time (make_skill).

---

## v0.6.4-beta.3 — Prompt Caching Wrap-up Continuation (BETA, IN PROGRESS)

> Completes 2 deferred items from beta.1/beta.2: Generate early-stop cache wiring (Site 2) + Cache_invalidated_by_skill event emission (ROADMAP B.5.2). All 1188 tests passing.

### Added — Generate early-stop cache wiring (Site 2)

- **FIX** `Engine.run_agent` Generate early-stop branch (engine.ml:583-590) now applies cache planning before the final LLM call. Previously this path was reached BEFORE the main dispatch's cache marking (line 668), causing first-iteration-Generate and post-compression edge cases to dispatch with zero cache marks.
- The block mirrors the main dispatch pattern (lines 668-684): `build_breakpoint_candidates` → `plan_breakpoints` → emit dropped events → `apply_breakpoints` on `conv'`.
- Secondary dispatch sites (run_structured line 334, Max_tokens continuation line 975) remain intentionally NOT wired:
  - `run_structured`: would require adding `?on_tool_event` parameter for event publishing; conversations are typically short (3-5 messages); marginal benefit.
  - Max_tokens continuation: cache marks from main dispatch already propagate to the continuation sub-loop (system + tools messages keep their marks; new continuation messages correctly avoid marks to preserve cache key stability).

### Added — Skill overlay cache invalidation event (ROADMAP B.5.2)

- **NEW** `Cache_invalidated_by_skill` event is now emitted at both `apply_skill_effect_to_config` call sites (`runtime.ml:662` invoke + `:754` invoke_generate).
- Trigger condition: when `active_effects <> []` AND (`after_tool_count <> before_tool_count` OR `composed_effect.system_prompt_override <> None`).
- Payload: `{ skill_id; before_tool_count; after_tool_count; estimated_wasted_tokens }` where `estimated_wasted_tokens = max 0 ((before - after) * 100)` (heuristic: each tool definition ~100 tokens).
- Skill ID resolution: single active skill → its ID; multiple → `"composite:N"`; unresolved → `"unknown"`.
- **NEW** `get_active_skill_ids` helper in runtime.ml mirrors `compute_active_skill_effects` logic to derive active skill IDs (necessary because `skill_effect` type has no `skill_id` field).
- The event was previously declared (types.ml:708), tested (test_cache_events.ml:72), and handled by CLI (bin/main.ml:1363) + persistence (persistence_common.ml:49), but never emitted. Now wired end-to-end.

### Architecture

- Skill overlay event scope controlled: B.5.1 phantom-typed `skill_prompt_zone` ADT remains deferred to v0.6.5+ (would require same existential record field design as `mark_cache_breakpoint`). The runtime `string option` for `system_prompt_override` is retained.
- OpenAI `cached_tokens` confirmed DONE (was incorrectly reported as hardcoded to 0 in prior session notes). Field is correctly parsed from `prompt_tokens_details.cached_tokens` at `openai_provider.ml:316`. The hardcoded `cache_creation_input_tokens = 0` and `cache_read_input_tokens = 0` are correct (Anthropic-only fields).
- `mark_cache_breakpoint` user-facing API remains deferred per CHANGES.md beta.1 R3 scope decision: "auto-caching until v0.6.5+ adds user-facing mark_cache_breakpoint API". Trigger condition (v0.6.5+) and migration path documented.

---

## v0.6.4-beta.2 — Prompt Caching Wrap-up (BETA, IN PROGRESS)

> Continues v0.6.4: template zone classification, make_agent `?cache_strategy` + B.4 zone-validation check, budget manager wired into engine main ReAct loop, 4 new test files (48 new tests). All 1188 tests passing.

### Added — Template zone classification (Track B.2)

- **NEW** `Template.builtin_zone` table: `current_time` → `Zone_volatile` (per-second drift via `Unix.gettimeofday`); `agent_id` / `runtime_id` / `available_tools` / `user_variables` → `Zone_stable`.
- **NEW** `Template.classify_template_zone : template:string -> zone_tag` — scans template for `{{var}}` references, max-propagates zone (any volatile → whole template volatile). Unknown variables default to stable.
- **NEW** `Template.zone_of_builtin : string -> zone_tag` — accessor for individual builtin zone lookup.
- **CHANGED** `Template.effective_system_prompt` return type: `(string, error_category) result` → `(system_prompt, error_category) result`. When `system_prompt_template = None`, returns `agent.system_prompt` as-is (preserving caller-set zone). When template renders, wraps result via `stable_prompt` or `volatile_prompt` per `classify_template_zone`.

### Added — Construction-time cache validation (Track B.4)

- **NEW** `Runtime.make_agent` accepts `?cache_strategy:cache_strategy = No_caching` parameter (was hardcoded).
- **NEW** B.4 zone-validation check: when `With_cache_of _` is requested but `system_prompt` zone is `Zone_volatile`, downgrades to `No_caching` with `Logs.warn`. v0.6.5 will upgrade to hard error.
- **NEW** `Runtime.register_agent` emits `Cache_strategy_skipped { reason = \`Volatile_system }` event when make_agent downgrades the strategy (via `rt.publish_event_fn`).
- **NEW** FFI JSON parser: `parse_cache_strategy` helper in `par_capi.ml`. Accepts `cache_strategy` field in agent JSON config. Shape: `"No_caching"` or `["With_cache_of", "Five_min"]` (case-insensitive).

### Added — Budget manager wiring (Track E integration)

- **NEW** `Engine.run_agent` main ReAct loop (engine.ml:605) now consults `agent.cache_strategy`. When `With_cache_of ttl`:
  1. Auto-builds ≤3 breakpoint candidates: System message (priority 100, location `` `System ``), last tool (priority 50, `` `Tool i ``), last user message last block (priority 10, `` `Message (i,j) ``).
  2. Calls `Cache_breakpoint.plan_breakpoints llm candidates` to apply provider cap (4 for Anthropic, 0 for OpenAI/Ollama).
  3. Emits `Cache_breakpoint_dropped` event for each dropped candidate with reason (`Over_budget` or `Unsupported_by_provider`).
  4. Applies `cache_control = Some { type_ = \`Ephemeral; ttl = Some ttl }` markers to the corresponding `content_block`s before LLM dispatch.
- Secondary dispatch sites (run_structured line 334, Generate early-stop line 514, Max_tokens continuation line 884) intentionally NOT wired in v0.6.4 — separate code paths with potentially different cache semantics. Future hardening.
- **NEW** 3 private helpers in engine.ml: `set_cache_control` (functional update of content_block cache_control field), `build_breakpoint_candidates` (auto-mark from current request state), `apply_breakpoints` (mark conv.messages by breakpoint location).

### Added — Tests (Track H subset)

- **NEW** `test/test_budget_manager.ml` — 11 tests: `plan_breakpoints` with 1/2/4/5/100 candidates, `max_breakpoints=0` → all `Unsupported_by_provider`, `max_override` behavior, priority sort DESC verification.
- **NEW** `test/test_cache_events.ml` — 11 tests: 5 event variants (`Cache_write`, `Cache_read`, `Cache_strategy_skipped` ×4 reasons, `Cache_breakpoint_dropped` ×locations×reasons, `Cache_invalidated_by_skill`) construction + yojson round-trip.
- **NEW** `test/test_template_zone.ml` — 12 tests: `classify_template_zone` direct (no-vars/current_time/agent_id/runtime_id/available_tools/mixed/unknown), `zone_of_builtin` table, `effective_system_prompt` zone propagation (no-template preserves / volatile template / stable-only template).
- **NEW** `test/test_stable_volatile_prompts.ml` — 14 tests: constructors (`stable_prompt`/`volatile_prompt` + empty variants), accessors (`prompt_text`/`zone_of`), make_agent zone preservation, B.4 cache_strategy check (stable+With_cache_of kept / volatile+With_cache_of downgraded / volatile+One_hour downgraded / stable+One_hour kept / No_caching unchanged / default).

### Architecture (per STRATEGY §11 "一次做对")

- Runtime `zone_tag` approach retained per commit `6a22c7f`: "phantom types cannot survive OCaml record field boundary (existential type parameter limitation). Runtime zone_tag provides same guarantee at construction time. This is 架构正确 (per §11 R1), not 范围妥协."
- Template zone classification extends this runtime mechanism to builtin variables — same architecture, no phantom types.
- Budget manager wiring scoped to main ReAct loop only. Scope-controlled per R3: secondary paths are separate code paths with different cache semantics; auto-building 3 candidates is "auto-caching" until v0.6.5+ adds user-facing `mark_cache_breakpoint` API.
- v0.6.4 soft-fail → v0.6.5 hard-fail migration path is explicit and dated (per §11 R2).

### Migration (1 BREAKING in 0.x)

| # | Old API | New API | Migration |
|---|---|---|---|
| 1 | `Template.effective_system_prompt` returns `(string, error_category) result` | Returns `(system_prompt, error_category) result` | Use `prompt_text sp` to extract string. Affected: 3 sites in `engine.ml`, `test_template.ml`. |

`Runtime.make_agent ?cache_strategy` is **backwards-compatible** (new optional parameter with default `No_caching`).

---

## v0.6.4-beta — Typed Prompt Caching Infrastructure (BETA, IN PROGRESS)

> PAR-4lh: content_block list message representation + cache_control types + prompt caching infrastructure. Stable/Volatile phantom types + mark_cache_breakpoint API deferred to follow-up commit (needs OCaml type design for existential record fields).

### BREAKING in 0.x (5 changes, all mechanical)

| # | Old API | New API | Migration |
|---|---|---|---|
| 1 | `message.content : string option` | `message.content_blocks : content_block list` | Use `Message.content_of_string` or `Message.text_of_message` helper |
| 2 | `usage_stats` (3 fields) | `usage_stats` (6 fields) | Add `cached_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0` |
| 3 | `llm_service` (no `cache_control_fn`) | `llm_service` (with `cache_control_fn`) | Add `cache_control_fn = None` to all 7 llm_service constructors |
| 4 | `agent_config` (no `cache_strategy`) | `agent_config` (with `cache_strategy`) | Add `cache_strategy = No_caching` to all 17 record-literal sites |
| 5 | `Openai` provider config (no `prompt_cache_key`) | `Openai` (with `prompt_cache_key`) | Add `prompt_cache_key = None` to all Openai variant constructors |

### Added — Content blocks

- **NEW** `content_block` ADT: `Text_block` / `Tool_use_block` / `Tool_result_block` / `Image_block`, each with optional `cache_control`. Replaces flattened `string option`.
- **NEW** `cache_control` type: `{ type_ : [`Ephemeral]; ttl : cache_ttl option }`. Mirrors Anthropic `CacheControlEphemeralParam`.
- **NEW** `cache_ttl = [`Five_min | `One_hour]`. Single canonical definition in types.ml.
- **NEW** `image_source = Url of string | Base64 of string`. Type-level prep for v0.7 multimodal.
- **NEW** `Message` helper module (`lib/core/message.ml`): `content_of_string`, `string_of_content`, `text_of_message`, `content_opt`.

### Added — Prompt caching infrastructure

- **NEW** `cache_strategy = No_caching | With_cache_of of cache_ttl`. On `agent_config` (default `No_caching`).
- **NEW** `cache_control_fn` capability on `llm_service`: `(unit -> cache_control_capability) option` where `cache_control_capability = { supported_ttls; max_breakpoints }`.
- **NEW** `prompt_cache_key : string option` on `Openai` provider config. Injected into OpenAI request body when set.
- **NEW** `Cache_breakpoint` module (`lib/core/cache_breakpoint.ml`): `plan_breakpoints` budget manager — sorts candidates by priority, drops lowest when over provider cap.
- **NEW** `cache_control_to_json` helper in Anthropic adapter: serializes `cache_control` markers on content blocks to wire format.
- **NEW** 5 event variants: `Cache_write`, `Cache_read`, `Cache_strategy_skipped`, `Cache_breakpoint_dropped`, `Cache_invalidated_by_skill` + sub-types (`cache_skip_reason`, `breakpoint_location`, `drop_reason`).

### Changed — Provider adapters

- **Anthropic** `build_message_json`: serializes `content_blocks` (was: synthesize from string). Emits `cache_control` JSON on blocks that carry it.
- **Anthropic** `parse_usage`: reads `cache_creation_input_tokens` and `cache_read_input_tokens`.
- **OpenAI** `build_request_body`: injects `prompt_cache_key` into request body when set.
- **OpenAI** `parse_usage`: reads `prompt_tokens_details.cached_tokens`.

### Not yet in v0.6.4 (follow-up commits)

- Stable/Volatile phantom types on `system_prompt` (needs OCaml type design — record fields can't hold existential type parameters)
- `mark_cache_breakpoint` user-facing API
- `Cache_breakpoint` module wired into engine (currently standalone)
- Template zone tagging (current_time/runtime_id → volatile classification)
- Skill overlay cache invalidation event emission
- New test files (test_content_blocks, test_cache_breakpoint, etc.)

---

## v0.6.3-beta — Auto Context Compression by Window Ratio (BETA)

> PAR-p70: ratio-based auto-compression fires when conversation approaches the model's context window limit. Default `Summarize` strategy aligns with industry consensus (Letta, Anthropic, LangChain-classic, CrewAI all default to LLM-summarize; none default to pure-truncate-drop). 36 new tests across OCaml + Python.

### Added — Auto-compression infrastructure (plan §2.1, §2.3)

- **NEW** `Context_manager.default_context_window : model_config -> int` — static lookup table mapping known model names to context window sizes (gpt-4o family=128K, claude-sonnet-4/opus-4/haiku-3.5=200K, o1/o3/o4-mini=200K, gpt-3.5-turbo=16385, unknown=8000 safe default).
- **NEW** `Context_manager.resolve_context_window` — three-tier resolver: `context_window_override` (user-supplied) → `llm_service.context_window_fn` (provider capability) → `default_context_window` (static table).
- **NEW** `Context_manager.estimated_tokens_with_margin` — wraps existing `estimate_tokens` with 1.2× safety margin (chars/4 underestimates real tokens by ~20%).
- **NEW** `Context_manager.should_compress` — PURE decision function returning `(bool, context_compression_skip_reason option)`. No I/O, no side effects; same inputs → same output.

### Added — Configurable behavior (plan §2.2)

- **NEW** `agent_config.context_compression_threshold : float option` — when `Some r` (0.0–1.0), auto-fires compression when `estimated_tokens / context_window ≥ r`. Default `Some 0.8`. `None` = disabled (preserves pre-v0.6.3 manual-mode behavior).
- **NEW** `agent_config.compression_cooldown_messages : int option` — minimum iterations between auto-compressions. Prevents LLM-summarize thrash. Default `Some 6` (value informed by production practice; matches industry norms).
- **NEW** `agent_config.context_window_override : int option` — user-supplied context window size. Overrides provider capability and static table. `None` = use tier-1/2 resolver.
- **NEW** `llm_service.context_window_fn : (unit -> int) option` — provider capability function mirroring `supports_native_tools_fn`. Custom providers SHOULD set this for accurate ratio computation.
- **NEW** `Runtime.make_agent` optional params for all three new fields.

### Added — Observability events (plan §2.6)

- **NEW** event variant `Context_compressed of { trigger; tokens_before; tokens_after; messages_before; messages_after; strategy_used; elapsed_ms }` — fired on successful compression.
- **NEW** event variant `Context_compression_skipped of { reason }` — fired when compression considered but skipped. `reason` is a typed polymorphic variant: `` `Below_threshold of float ``, `` `Cooldown_active of int ``, `` `No_window_size ``, `` `No_strategy ``.

### Changed — Default strategy switched to Summarize (BREAKING in 0.x per SemVer §4)

- `Runtime.make_agent` default `context_strategy` changed from `Sliding_window { max_messages=100; max_tokens=200000 }` to `Summarize { max_tokens=8000; summary_model=None }`.
- **Rationale**: industry research (librarian bg_940617fc, 2026-06-30) confirmed every mainstream production agent framework that ships a default uses LLM-summarize — Letta (`sliding_window` mode), Anthropic `compact_20260112` (server-side), LangChain `ConversationSummaryBufferMemory` (`predict_new_summary`), CrewAI (`respect_context_window=True` default). Zero frameworks default to pure-truncate-drop. Truncate is universally treated as degradation, not baseline.
- **Migration**: existing agents that relied on the implicit `Sliding_window` default will now get `Summarize` instead when the threshold fires. Users wanting the old behavior should set `context_strategy = Some (Sliding_window {...})` explicitly.
- **Cost mitigation**: cooldown=6 prevents thrash (max 1 summarize call per 6 iterations). `summary_model = None` means "use agent's own model"; users can override with a cheap model (Claude Haiku, gpt-4o-mini) via the existing `Summarize.summary_model` field.

### Changed — Engine integration (plan §2.4)

- `Engine.run_agent` now consults `Context_manager.should_compress` at the top of each ReAct iteration before applying `context_strategy`. Trigger logic:
  - `threshold=None` (manual mode) → apply `context_strategy` unconditionally (pre-v0.6.3 behavior preserved).
  - `threshold=Some r, ratio<r` → emit `Context_compression_skipped(Below_threshold)`, pass through.
  - `threshold=Some r, ratio≥r, cooldown not elapsed` → emit `Context_compression_skipped(Cooldown_active n)`, pass through.
  - `threshold=Some r, ratio≥r, cooldown elapsed` → apply strategy (or default Summarize if `context_strategy=None`), emit `Context_compressed`.
- `last_compress_iter` ref tracks cooldown state per agent run (not persisted; reset on restart — intentional for suspended workflow rehydration).

### Added — FFI / Python config (plan §2.8)

- `par_capi.ml` JSON parser now reads `context_compression_threshold`, `compression_cooldown_messages`, `context_window_override`, AND the previously-hardcoded `context_strategy` from JSON config. Existing Python/CLI configs without these fields continue to behave as before (backward compatible). Unknown `context_strategy` tags fail-fast (typed rigor — no silent fallback).

### Tests

- 17 new tests in `test/test_context_manager.ml` (was 4, now 21): covering `default_context_window` table lookups, `resolve_context_window` three-tier precedence, `estimated_tokens_with_margin` 1.2× factor, and `should_compress` purity (threshold hit/miss, cooldown active/elapsed, no-window-size, manual-mode).
- 5 new tests in `test/test_context_compression.ml`: engine integration covering manual mode, auto-fire above threshold, skip below threshold, cooldown blocking, and `Context_compressed` payload verification.
- 14 new tests in `bindings/python/tests/test_config.py`: JSON config round-trip for all 3 new fields + `context_strategy` (3 variants + unknown-tag failure + backward compat).
- All 1000+ existing OCaml tests + 60+ Python tests remain green.

### Strategic motivation

Production-readiness gap surfaced by integration feedback: long conversations hit `Context_length_exceeded` errors with no graceful recovery. The reactive arm at engine.ml:539 catches the error and re-applies strategy, but by then the LLM call has already wasted tokens and latency. PAR-p70 fires pre-emptively at 80% — better than Letta and CrewAI which fire reactively. The typed `context_compression_skip_reason` polymorphic variant is a direct expression of STRATEGY.md §4 axis #1 (类型严谨): competitors use string error messages; PAR uses a typed ADT.

### Not in v0.6.3 scope

- Real tokenizer (tiktoken binding) — keeping chars/4 + 1.2× margin; document as future work.
- `Runtime.invoke_generate` path (Generate.run) — separate from ReAct loop, intentionally skips context_strategy. Long-output generation has its own continuation logic via `on_max_tokens`. Open follow-up if integrators need it.
- `Runtime.invoke_structured` — uses middleware only, not context_strategy.
- Tool-call/tool-result pairing invariant (LangChain `start_on` / Letta `is_valid_cutoff` pattern) — current `apply_summarize` uses "keep last 4" heuristic. Future hardening.

---

## v0.6.2 — STABLE

> Workflow engine fix cycle: closed the suspend → gate → resume loop and aligned API/docs with integration feedback. All 11 reported defects addressed.

### Added — Closed loop: suspend → gate → resume (§1.1, §1.2)

- **NEW** `Runtime.resume_workflow` — real implementation (was stub returning "not yet implemented"). Replays checkpoint, walks step_path, re-enters execution at the suspended Human_approval, treats it as approved, runs remaining siblings. Supports Sequential + Conditional resume; Parallel/Map_reduce return explicit `Error` (documented limitation).
- **NEW** `Runtime.approve_workflow` — was no-op (`approver:_` discarded). Now validates `approver` against `checkpoint.allowed_roles` (returns `Permission_denied` on mismatch), publishes `Approval_granted` event, cancels deadline watcher, triggers `resume_workflow`.
- **NEW** `Workflow_engine.resume_from_checkpoint` — public algorithm: `exec_context -> workflow_step -> workflow_checkpoint -> (Yojson.t, error_category) result`.

### Added — Lifecycle events (§1.4)

- The engine defined 7 workflow event variants but emitted ZERO. Now publishes at every state transition:
  - `Workflow_started { workflow_run_id }` on submit
  - `Workflow_step_completed { step_id }` per step (stable dot-separated ID like `"0.1.2"`)
  - `Workflow_completed { workflow_run_id }` on terminal success
  - `Workflow_failed { workflow_run_id; error }` on terminal failure or timeout
  - `Approval_requested { prompt; allowed_roles }` on Human_approval suspend
  - `Approval_granted { approver }` on successful approve
  - `Approval_timeout` on deadline watcher firing

### Added — Durability (§2.1)

- `Runtime.create` now rehydrates suspended workflow runs from SQLite at boot via new `load_all_suspended_workflows_fn`. Runs are RESUMABLE (call `resume_workflow`) but NOT auto-resumed.

### Added — Async + parameterized submit (§2.2, §2.3)

- **NEW** `Runtime.submit_workflow_async` — fire-and-forget variant. Forks execution in background fiber, returns run_id immediately. Caller tracks progress via `get_workflow_status` or event bus subscription.
- **NEW** `Runtime.invoke_workflow_sync` — convenience wrapper. Returns `Some result | None (suspended) | Error`. Useful for tests and short workflows.
- All three submit functions (`submit_workflow`, `submit_workflow_async`, `invoke_workflow_sync`) now accept `?inputs:(string * Yojson.Safe.t) list` for per-run parameterization without mutating the workflow definition.

### Changed — Engine internals (§1.3, §4.2, §4.3)

- **Sequential result propagation** (§1.3): each step's result is now bound to variables visible to subsequent steps as `result` (most recent), `result_N` (indexed by position), `results` (accumulated array), plus flat dotted bindings for `Assoc` results (`result.text`, `result.tool_calls`, `result_0.text`, etc.). The doc example `"Critique: {{result}}"` now actually works.
- **Tool_call input substitution** (§4.2): `{{var}}` template substitution is applied recursively to all string leaves of `Tool_call.input` JSON (previously only `Agent_call.prompt_template` and `Human_approval.prompt_template` were substituted).
- **Agent_call structured output** (§4.3): step result is now `` `Assoc [("text", ...); ("tool_calls", ...)] `` instead of just `` `String text ``. Downstream steps can reference `{{result.text}}` and `{{result.tool_calls}}`.
- `execute_step` and all `execute_*` functions thread `?path:int list` for accurate `step_path` tracking in checkpoints. `on_step_complete` callback type changed from `(string -> ...)` to `(int list -> ...)` to receive the actual path.
- `execute_sequential` gains `?start_idx:int` parameter so resumed steps continue indexing correctly.

### Changed — Type split (§4.1, BREAKING in 0.x per SemVer §4)

- `workflow` type split into `workflow_def` (serializable record with `[@@deriving yojson]`) + `workflow = { def : workflow_def; on_complete : (workflow_result -> unit) option }`. Enables JSON-driven workflow registration.
- **Migration**: every `wf.id` / `wf.variables` / `wf.steps` etc. becomes `wf.def.id` / `wf.def.variables` / `wf.def.steps`. `wf.on_complete` unchanged.
- `workflow_checkpoint` gains two fields: `workflow_id : string` (for resume to look up workflow def) and `allowed_roles : string list option` (None = unrestricted, backward compat with old checkpoints).
- `exec_context` gains `workflow_id_resolver : unit -> string option` (wires workflow_id into checkpoints at suspend time).

### Docs (§3.1)

- `docs/sdk/workflow.md` rewritten (+172 / -58 lines): all examples updated to new `workflow_def + workflow` shape, new sections for "Workflow lifecycle events" and "Persistence and recovery", Sequential section explains result propagation, Tool_call section shows input substitution, approve/resume sections reflect actual behavior.

### Tests

- 22 new tests in `test/test_workflow_engine.ml` (was 30, now 52): 7 resume tests (sequential, nested, conditional, parallel rejection, invalid path, variable restoration, e2e runtime), 3 approve role-validation tests, 2 rehydration tests, 4 lifecycle event tests, 2 checkpoint round-trip tests, plus step_path tracking and tool/agent step-result tests.
- All 195+ existing tests across the suite remain green (zero regressions).

### Strategic motivation

Integration feedback reported that the suspend → gate → resume closed loop was broken in three of four places: resume was a stub, approve was a no-op, and step results didn't propagate. Combined with §2.1 durability gap, the workflow engine was unfit for production Human-in-the-Loop scenarios. This cycle closes all 11 reported defects and brings the engine to functional parity with the documented API.

---

## v0.6.1 — STABLE

> Long-output generation mode: typed `on_max_tokens` option + first-class `invoke_generate` API. Closes the gap surfaced by integration feedback (long-output agents were bypassing PAR's ReAct loop to call LLM directly).

### Added — Long-output generation mode (plan §3)

- **NEW** `Runtime.invoke_generate` — pure generation path that skips the ReAct loop and auto-continues on `Max_tokens` truncation. Use for long text artifacts (PRDs, HTML mockups, plans, documentation) where no tool calls are needed.
- **NEW** `Generate.run` module (`lib/core/generate.ml`) — decoupled Continue sub-loop implementation per plan §3.1.3.
- **NEW** `generate_result` type — first-class return: `text`, `finish_reason`, `continuations`, `total_tokens`, `session_id`, `elapsed`.
- **NEW** `Generate_continuation` event variant — fired per continuation chunk with `chunk_index` and `chars_added` for observability.
- **NEW** `Engine.resolve_on_max_tokens` / `Engine.resolve_max_continuation_chunks` — public helpers exposing the Auto resolution logic.
- **NEW** `par_generate` FFI + `Runtime.invoke_generate` Python method.

### Changed — Typed on_max_tokens option (plan §2, BREAKING in 0.x per SemVer §4)

- `agent_config.on_max_tokens` field type changed from `on_max_tokens_behavior` to `on_max_tokens_behavior option`. `None` (new default) means Auto.
- `agent_config.max_continuation_chunks` field type changed from `int` to `int option`. `None` (new default) means Auto.
- **Auto resolution**: tool-less agents (effective_tools=[]) get `Continue` with `max_int` chunks (effectively unbounded, suitable for long-output generation). Tool-bearing agents get `Return_partial` with cap 3 (backwards-compatible default).
- Explicit `Some X` always overrides Auto.
- `Runtime.make_agent` defaults updated: `?(on_max_tokens = None)`, `?(max_continuation_chunks = None)`.
- FFI `parse_agent_config` now treats omitted fields as `None` (Auto). Unknown `on_max_tokens` string values fail-fast (was silent fallback to `Return_partial`).
- Python binding: JSON-transparent — no Python code changes needed.

### Fixed — Option C: distinguish Max_tokens-induced iter exhaustion (plan §2.2)

- Retry path + iter exhaustion now reports `"Max iterations exceeded with truncated output"` (was generic `"Max iterations exceeded"`).
- Empty-content Continue path and early_stopping `Force` path retain `"Max iterations exceeded"` (backwards-compatible with existing test assertions).

### Mitigated — R1 wall-clock sub-cap (plan §2.5)

- Continue sub-loop now bounded by 50% of `max_execution_time`. Guards against runaway models that emit >500 chars per chunk and would otherwise slip past the diminishing-returns guard. Returns partial `Max_tokens` result on sub-cap hit.

### Strategic motivation (plan §1)

Integration feedback reported that long-output agents bypass PAR's ReAct loop and call LLM directly. Survey of 4 mainstream coding agents (Claude Code, Codex CLI, OpenCode, and a fourth comparable coding agent) confirmed none treat `Max_tokens` as iteration-consuming failure. PAR v0.6.0 was the only one still treating it as a loop-budget event. This change closes that gap and re-aligns with the strategic positioning in `docs/STRATEGY.md`.

### Tests

- 8 new tests in `test/test_truncation_config.ml` covering Auto resolution, explicit overrides, tool-less unbounded, skill overlay.
- 6 new OCaml tests in `test/test_generate.ml` covering basic, auto-continue, timeout, events, session persistence, skill overlay.
- 6 new Python e2e tests in `bindings/python/tests/test_generate.py`.
- All existing tests updated for the option type change (5 test files).
- Full suite (1000+ existing tests) — zero regressions.

### Docs

- Updated `docs/sdk/agent.md` (+ ZH mirror) for the option type semantics.
- New `docs/sdk/generate.md` (+ ZH mirror) — complete `invoke_generate` documentation.

---

## v0.6.0-beta.20260628 — BETA

> Configurable truncation behavior + GH issue audit sweep (14 bug fixes).

### Fixed — GH issue audit sweep (14 fixes)

**Security**:
- **GH#1**: `http_client.ml` now uses `Ca_certs.authenticator()` for TLS verification. Previously all OpenAI/Anthropic API calls were MITM-vulnerable (hardcoded `no_auth`).
- **GH#2**: All 6 file tools (read/write/edit/ls/find/grep) now reject paths with `..` components. Previously vulnerable to path traversal (e.g. `../../etc/passwd`).

**Python binding**:
- **GH#19**: Fixed `str | None` → `Optional[str]` in `_ffi.py` (Python 3.8 compat). Added `@staticmethod` to `Runtime.version()`. Package now imports on Python 3.8/3.9 as declared.
- **GH#11**: `_callbacks` uses monotonic counter + per-instance tracking. `Runtime.close()` cleans up owned callbacks.

**FFI**:
- **GH#10**: `par_save/load_conversation` now check `Is_exception_result` before `Int_val`. Prevents silent error swallowing.
- **GH#8**: Removed `Obj.magic` from skill activation path — the abstract `type runtime` forward declaration was dead code (activate function ignored the parameter).

**Core**:
- **GH#18**: `resume_workflow` returns `Error(Internal)` instead of running dummy echo workflow (silent data loss). Full implementation tracked as PAR-uy3.
- **GH 漏报**: Conversation/session resume (`par -c` / `par -r`) now works — REPL seeds from loaded conversation, auto-saves after each turn, reuses session ID.
- **GH#17**: Engine-level `tool_timeout` field on `agent_config`. Old `timeout_middleware` deprecated with warning.
- **GH#16**: Retry counter isolated per-conversation (was shared across concurrent fibers).
- **GH#6**: `Approval_deadline.table` migrated to `protected_hashtbl` for consistency.

**Test/CI**:
- **GH#12**: `test_skill_e2e` and `test_http_timeout` changed from `(executable)` to `(test)` — they now actually run.
- **GH#14**: `pypi-publish.yml` checksum merge fixed — downloads to separate subdirs, correct glob.
- **GH#15**: `SECURITY.md` version table updated from 0.3.1 to 0.6.x/0.5.x.

### Added — Configurable on_max_tokens_behavior policy (PAR-cx3)

Two new optional fields on `agent_config`:

- `on_max_tokens : on_max_tokens_behavior` — controls what happens when the LLM returns `finish_reason=Max_tokens`. Type: `Retry | Continue | Return_partial`. Default: `Return_partial` (Phase 1 behavior).
- `max_continuation_chunks : int` — caps the number of continuation chunks in `Continue` mode. Default: 3.

**New event variant**: `Llm_response_truncated of { task_id; model; finish_reason }` — emitted on every Max_tokens truncation for observability. Surfaced via the existing `on_tool_event` callback and `par history`.

**Policy behaviors**:

| Policy | Behavior |
|--------|----------|
| `Return_partial` (default) | Preserve truncated text, return `Ok` with partial result. Matches v0.5.5 Phase 1 behavior. |
| `Retry` | Preserve truncated message for context, re-enter the ReAct loop. Bounded by `max_iterations`. |
| `Continue` | Inject "continue from where you stopped" follow-up, concatenate chunks. Capped by `max_continuation_chunks`. Diminishing-returns guard: stops if a continuation chunk adds <500 chars. Inspired by Claude Code's escalate+retry approach. |

**Design context**: 3-way research compared Claude Code (Retry+escalate×3), OpenAI Codex CLI (blind retry — known bug openai/codex#14753), and a fourth comparable coding agent (Return_partial). PAR's typed ADT approach is a strict improvement over Codex's string-based generic retry, and more configurable than Claude Code's hardcoded constants.

**Python binding**: No code changes needed. Set via JSON: `{"on_max_tokens": "continue", "max_continuation_chunks": 3}`.

**Verified**: `test/test_truncation_config.ml` — 5 test cases covering all three policies, max_chunks cap, diminishing-returns guard, and event emission. Full test suite: zero regressions.

---

## v0.5.5-beta (2026-06-27) — BETA

> **Theme**: Critical ReAct loop truncation bug fix.

### Fixed — Max_tokens truncation discards partial output (critical)

**Problem**: When an LLM returned `finish_reason=Max_tokens` (truncated response), the engine discarded the partial output, left the conversation unchanged, and re-issued the identical prompt. This burned all iterations and failed with "Max iterations exceeded" — even though valid partial content existed on every call. Pure-generation agents (HTML mockups, long code, document drafting) were effectively unusable when the model's `max_tokens` was below the natural output length.

**Root cause**: `engine.ml` Max_tokens branch never called `add_assistant_message` (unlike the tool-call branch and the normal-stop branch). The truncated `resp` was silently dropped, the conversation stayed byte-identical, and the next loop iteration sent the same prompt → identical truncation → loop until `global_max`.

**Fix** (one change to `lib/core/engine.ml:657-660`):
- Content detection: if the truncated response has non-empty text (`String.trim` non-empty), preserve it via `add_assistant_message`, drain queued steering via `drain_into_conv`, and return `Ok (resp, conv)` — the partial result is a valid final answer.
- Empty/think-only truncations retain the previous error-or-retry behavior (no silent success on empty output).

**Verified**: `test/test_truncation_fix.ml` — 3 new test cases:
1. `Max_tokens with content returns partial result` — asserts `Ok` with truncated text + assistant message preserved in conversation.
2. `Max_tokens with empty text keeps error behavior` — regression guard; asserts `Error (Internal "Max iterations exceeded")`.
3. `Max_tokens with content does not burn iterations` — asserts only 1 LLM call is made (counter-tracked mock), proving the loop terminates immediately instead of re-entering.

Full test suite: zero regressions (all existing tests pass).

**Design note**: This mirrors a comparable coding agent's classify-style approach (content-present truncation = valid `final`), avoiding the anti-pattern seen in OpenAI Codex CLI (openai/codex#14753, closed without fix) where truncation is bundled into the generic stream-error retry path. A configurable `on_max_tokens_behavior` policy (Retry | Continue | Return_partial) is planned for v0.6.0.

---

## v0.5.4-beta (2026-06-26) — BETA

> **Theme**: Production-Ready Multi-Provider.

### Added — Multi-provider support (PAR-tiu)
- Provider_registry: thread-safe Hashtbl built on protected_hashtbl. Runtime.register_llm_provider / list_llm_providers / set_default_provider / get_llm_service.
- Cross-provider fallback (A.3): Runtime.set_fallback_policy with No_fallback | Ordered of string list | Tagged. Emits Provider_fallback_attempted event. invoke only.
- Model discovery (A.2): Runtime.list_models + par models CLI. Mock returns ["mock-model"].
- FFI Anthropic gap fix: par_capi.ml:188-193 previously returned None for Anthropic/Custom. Now constructs real services.
- Python FFI: Runtime.list_llm_providers / set_default_llm_provider.

### Added — Session resume (PAR-mkm)
- conversations table (whole-blob per session: session_id PK, messages_json, metadata_json, updated_at, turn_count). SQLite + Noop only.
- CLI: par -c <session-id> / par -r (resume most recent).
- Python FFI: Runtime.set_session_id / get_session_id / save_conversation / load_conversation.
- Known limitation: no automatic pruning. TTL + par history --prune deferred.

### Added — Skill CLI gap closure (PAR-bd8)
- REPL: /skill use, /skill unuse, /skill create (interactive wizard, all 8 fields).
- CLI: par skill list/show/use/create/reload subcommands.
- repl_input.ml: isatty fallback for piped stdin.

### Added — par_cancel_stream FFI (closes v0.5.3 Known Limitation)
- Flag-check pattern (rt.cancel_stream_requested checked by on_chunk). NOT Eio.Cancel. Cancel latency ~50-300ms.

### Added — Interactive tutorials (Diataxis)
- docs/tutorials/01-rag-qa-bot.md, 02-streaming-ui.md + 2 stubs.

### Removed — PostgreSQL persistence backend
- Deleted lib/postgres/ (postgres_persistence.ml + .mli + dune), par_postgres.opam.
- Removed [`Postgresql of string] variant from public persistence type (breaking change for SDK users who pattern-matched on it).
- Dropped caqti-eio dependency from lib/dune and dune-project.
- CLI --db-uri now means "SQLite database path" (was "PostgreSQL connection URI").
- Recovery: if PostgreSQL support is needed in the future, restore from git commit cb5d795 (pre-removal).

### Known limitations
- FFI registers only first provider as "default". Full multi-provider wire-up deferred.
- par models returns models only for Mock. OpenAI/Anthropic list_models deferred.
- No conversation pruning.

---

## v0.5.3 (2026-06-24) — STABLE

> **Theme**: Critical bug fixes + true incremental streaming. Both items deferred from v0.5.2 release (per the "Known Limitations" section) and shipped here.

### Fixed — RAG sqlite-vec path resolution (critical shipping bug)

**Problem**: `vec_extension_path` in `lib/ffi/par_capi.ml` was a hardcoded relative path (`vendor/sqlite-vec/linux-x86_64/vec0.so`). When Python `pip install par-runtime` users ran `rt.add_documents(...)` from any cwd other than the PAR source tree, the path didn't resolve and `add_documents` silently returned `-5`. The vector store couldn't be initialized, breaking all RAG functionality for pip users.

**Root cause**: `Sys.executable_name` in OCaml returns the host binary path (e.g. `python3`), not `par_capi.so`'s location. There was no mechanism for Python to tell OCaml where the bundled `.so` actually lives.

**Fix** (three changes):
1. New FFI entry point `par_set_vec_extension_path(const char* path)` (`lib/ffi/par_ffi.c`, `par_ffi.h`) — lets Python pass the absolute path to OCaml before `par_init`.
2. `_vec_extension_path()` helper in `bindings/python/par_runtime/_ffi.py` — locates `vec0.so` / `vec0.dylib` in the wheel layout and calls `par_set_vec_extension_path` at module import time, before any `Runtime(...)` is constructed.
3. Dune rule in `lib/ffi/dune` copies `vendor/sqlite-vec/<platform>/vec0.*` next to the built `par_capi.so` so `_build/default/lib/ffi/` contains both; the PyPI publish workflow (`pypi-publish.yml`) was updated to copy `vec0.so` into the wheel alongside `par_capi.so`.

**Resolution order in OCaml** (`lib/ffi/par_capi.ml`):
1. Explicit override set via `par_set_vec_extension_path` (wheel layout — used by `pip install par-runtime`)
2. `Sys.executable_name` directory (OCaml-built binaries like `par` CLI)
3. `/usr/local/lib/par/` and `/usr/local/share/par/` (CLI install location)
4. `vendor/sqlite-vec/<platform>/` relative to cwd (dev builds from project root)

**Verified**: `pytest test_rag_e2e.py` from `/tmp/rag_verify/` (cwd != project root) — all 3 tests pass.

### Changed — True incremental streaming (B.3, was v0.5.2 deferred)

**Problem**: v0.5.1's streaming fix removed the Python daemon thread (which crashed with `Fatal: no domain lock held`) by buffering all chunks in OCaml and returning them as a single JSON payload at the end of `par_invoke_stream`. The user-visible symptom: `for event in rt.invoke_stream(...)` showed nothing until the LLM finished, then dumped everything at once. Long responses looked like the system was frozen.

**Root cause**: `do_invoke_stream` in `lib/ffi/par_capi.ml` accumulated chunks in a `chunk_buf` ref list, serialized the whole list as JSON, and returned it as the C return value. The C-side chunk callback (`par_chunk_callback` typedef, `caml_dispatch_chunk_to_c` C function, and `g_chunk_callback` / `g_chunk_user_data` globals) was wired at the C layer but **never invoked from OCaml** — there was no `external` declaration, so `do_invoke_stream` had no way to call back into C mid-stream.

**Fix** (two changes):
1. Added `external caml_dispatch_chunk_to_c : string -> unit = "caml_dispatch_chunk_to_c"` in `lib/ffi/par_capi.ml`, and called it inside the `on_chunk` closure of `do_invoke_stream` BEFORE appending to `chunk_buf`. Now every chunk produced by `Runtime.invoke ~on_chunk` fires the C callback immediately, which fires the Python ctypes closure, which pushes onto a `queue.Queue`.
2. Rewrote `bindings/python/par_runtime/runtime.py::_StreamReader` to run `par_invoke_stream` in a **background daemon thread** while `__iter__` consumes the `queue.Queue` concurrently. The ctypes closure pushes each JSON chunk onto the queue as the OCaml SSE parser produces it; the iterator's `__next__` blocks on `queue.get(timeout=...)` and yields events in real time. Chunks arrive at the caller within milliseconds of the LLM producing them — for a 30-second response, the first token arrives in <1 second (was: 30s).

**Threading model**: The background thread holds the C `ocaml_lock` for the duration of `par_invoke_stream`. The ctypes closure is fired from the OCaml Eio domain (a separate OCaml Domain) which acquires the GIL via ctypes CFUNCTYPE dispatch to run the Python callback. The callback only does `queue.put_nowait` (non-blocking, unbounded) and never re-enters `par_*`, so no deadlock is possible.

**Verified end-to-end**: Test `test_stream_reader_chunks_arrive_incrementally_v0_5_3` mocks `par_invoke_stream` with 100ms inter-chunk delays and asserts the reader delivers events with gaps >50ms (proving concurrent consumption, not buffered dump). Manual timing run confirmed events arrive at 1ms, 101ms, 202ms, 302ms.

**Backward compatibility**: The buffered JSON envelope (`"chunks": [...]` in the response) is still returned by `par_invoke_stream` for callers reading `parsed["chunks"]` directly. The queue-based path is additive.

**Test infrastructure note**: ctypes `CFUNCTYPE` closures only fire their Python callback when called from C, not from Python. Tests that need to exercise the real incremental path mock `_lib.par_invoke_stream` with a `side_effect` that fires the ctypes callback with realistic delays — the mock runs synchronously inside `_StreamReader`'s own background daemon thread, so `__iter__` on the main thread consumes the queue concurrently. The `test_stream_reader_chunks_arrive_incrementally_v0_5_3` test uses this pattern with 100ms inter-chunk delays and asserts `min_gap > 50ms` + `iter_total > 250ms`. Oracle verified the test is discriminating: reverting the threading fix collapses `min_gap` to 0.02ms → assertion fails.

### Changed — Build infrastructure

- `lib/ffi/dune` — new rule copies `vec0.so` (Linux) or `vec0.dylib` (macOS) into `_build/default/lib/ffi/` next to `par_capi.so`. Required for both source-build testing and wheel packaging.
- `Makefile` `install-dev` target — installs `vec0.{so,dylib}` to `/usr/local/lib/par/` so the `par` CLI can find the sqlite-vec extension.
- `.github/workflows/pypi-publish.yml` — copies `vec0.{so,dylib}` from `_build/default/lib/ffi/` into `bindings/python/par_runtime/lib/` before wheel build, so the wheel bundles both binaries.
- `bindings/python/pyproject.toml` — `package-data` extended to include `lib/vec0.*` (was only `lib/*.so`).

### Verified

- **OCaml**: 63 test suites, 1041 assertions pass (`dune runtest --force`)
- **Python**: 64 tests pass from `/tmp/rag_verify/` (cwd != project root) — RAG e2e test that previously returned -5 now passes
- **Streaming**: 13 streaming tests pass, including new `test_stream_reader_chunks_arrive_incrementally_v0_5_3` that proves chunks arrive incrementally (100ms inter-chunk delays, asserts `min_gap > 50ms`; Oracle verified the test is discriminating by reverting the fix and confirming `min_gap` collapses to 0.02ms → assertion fails)
- **RAG**: 3/3 RAG e2e tests pass from arbitrary cwd
- **Symbols exported**: `nm -D par_capi.so` confirms `caml_dispatch_chunk_to_c` and `par_set_vec_extension_path` are both in the dynamic symbol table

### Test Count

- 1041 OCaml assertions (was 1043 in v0.5.2 — minor test restructuring, no test removed)
- 64 Python tests passing (was 36 — added new streaming tests + kept RAG e2e)

### Known Limitation: early break from `invoke_stream` blocks subsequent calls

`invoke_stream` runs `par_invoke_stream` in a background daemon thread that holds the process-global C `ocaml_lock` (`par_ffi.c:27`) for the entire duration of the LLM stream. If the caller `break`s early from the iterator (or a `queue_timeout` fires), the daemon thread continues running until the LLM stream completes naturally — and during that window, **every subsequent `par_*` call on any Runtime instance blocks** on `pthread_mutex_lock(&ocaml_lock)`.

This is a behavior regression vs the buffered v0.5.1 streaming (where breaking early just stopped draining an already-complete queue, and `ocaml_lock` was already released). It is bounded (the stream completes naturally) and consistent with the documented single-stream-at-a-time design (`par_ffi.c:32-37`), but callers should be aware.

**Workaround**: consume the iterator fully (don't `break` early) if you intend to make further `par_*` calls. If you must break early, expect a delay equal to the remaining LLM generation time before the next call unblocks.

**Planned fix (v0.5.4)**: a `par_cancel_stream` FFI entry + Eio cancellation wiring that lets the caller interrupt an in-flight stream and release `ocaml_lock` immediately.

### Upgrade Notes

- **No breaking changes**. Both fixes are transparent.
- RAG `add_documents` now works from any cwd without any code change.
- `invoke_stream` now yields events incrementally — existing iterators work unchanged but feel dramatically more responsive.
- If you have existing code that reads `parsed["chunks"]` from the final response, it still works (the buffered envelope is preserved for back-comat).
- **Caveat**: see "Known Limitation" above — breaking early from `invoke_stream` will block subsequent `par_*` calls until the LLM stream finishes. Consume fully or wait.

### Contributors

@Neo20250413 (code, design, packaging)

---

## v0.5.2 (2026-06-24) — STABLE

> **Theme**: Skill system (filesystem-loaded, auto-activated) + tech debt pass + documentation refresh.

### Added — Skill System (Track A, complete)

The headline feature of v0.5.2. Skills are reusable prompt + tool bundles that auto-activate during `Runtime.invoke` based on trigger conditions. Inspired by the Claude Code / Anthropic skill pattern — skills are filesystem-based (no code), composable, and verifiable.

**New public API** (OCaml SDK):
- `Types.skill_descriptor` — name, description, triggers, system_prompt_override, tool_filter, activation_function
- `Types.skill_trigger` — `Auto | Manual | Keyword of { keywords: string list }`
- `Types.skill_effect` — produced by activation, applied to `agent_config` before LLM call
- `Types.skill_binding` — descriptor + optional activation function
- `Runtime.register_skill` / `Runtime.list_skills` — register and inspect skills
- `Runtime.compute_active_skill_effects` / `Runtime.compose_skill_effects` / `Runtime.apply_skill_effect_to_config` — exposed for testing and advanced use
- `compute_active_skill_effects` wired into `Runtime.invoke` (3-line integration) — skills auto-activate on every invocation

**New public API** (Python SDK):
- `Runtime.register_skill(name, description, frontmatter_yaml)` — register from Python
- `Runtime.list_skills() -> list[dict]` — inspect registered skills

**New public API** (CLI):
- `/skills` — list all registered skills
- `/skill <id>` — show skill details
- Skills auto-discovered from `~/.par/skills/<id>/skill.md` at startup

**Skill effects composition** (intersection semantics):
- `system_prompt_override`: last non-None wins
- `tool_filter`:
  - `All` = identity
  - `Only [tools]` ∩ `Only [tools]` = intersection
  - `Except [tools]` ∪ `Except [tools]` = union
  - `All` + `Only` = `Only`
  - `All` + `Except` = `Except`

**Trigger evaluation**:
- `Auto` — always active
- `Manual` — never auto-activates (user must invoke via CLI)
- `Keyword keywords` — substring match against `agent_config.instructions` + user message

**Built-in skills** (4 shipped):
1. `code-reviewer` — Auto-triggered; reviews code blocks in user input
2. `summarizer` — Auto-triggered; produces concise summaries
3. `translator` — Auto-triggered; translates text to target language
4. `rag-assistant` — Auto-triggered when RAG context is present

**Loader**: `lib/skills/skill_loader.ml` — hand-rolled YAML frontmatter parser (no new dep, ~200 lines). Discovers skills from `~/.par/skills/<id>/skill.md` and any directory passed to `Runtime.register_skill`.

### Changed — Tech Debt (Track B, 5 of 6 items)

- **B.1 Ollama CLI dispatch** — `bin/main.ml` now routes Ollama to native `ollama` CLI (Ollama API stays available via SDK). User-facing change: `par ask` against Ollama now uses local CLI by default.
- **B.2 FFI stale-skip removal** — `lib/ffi/par_capi.ml` no longer silently skips already-registered tools. Duplicate registration now raises a clear error (was a latent bug — wasted FFI calls).
- **B.4 MCP / fetch_url timeouts** — `lib/mcp/mcp_transport_http.ml` and `lib/builtin/fetch_url.ml` now use the `Http_client.with_timeout` wrapper added in v0.5.1. Stuck MCP servers and slow URL fetches no longer wedge the Runtime.
- **B.5 RAG event types** — added `Rag_search_started`, `Rag_documents_retrieved`, `Rag_context_injected`, `Rag_failed` to `Types.event` ADT. Subscribers can now observe the RAG pipeline via the event bus.
- **B.6 Documentation drift cleanup** — removed stale `agent_config.temperature` references, fixed broken internal links, normalized CLI flag examples.

### Changed — Documentation (Track C, 6 of 7 items)

- **C.1 Nav sync** — `docs/index.md` and `docs/SUMMARY.md` (auto-generated) include all new v0.5.2 pages.
- **C.2 RAG how-to guide** — `docs/howto/rag.md` — 5 worked examples (custom embedding model, hybrid search, batch ingest, chunking strategies, external vector store migration).
- **C.3 RAG reference expansion** — `docs/sdk/rag.md` grew from 8KB → 22KB, with complete API coverage, performance characteristics, and error handling.
- **C.4 FAQ** — `docs/faq.md` — 20 common questions across 5 categories (install, runtime, providers, RAG, skills).
- **C.5 Observability** — `docs/explanation/observability.md` — events, structured logs, metrics, and tracing patterns. Includes a "what to log at each layer" guide.
- **C.6 Three explanation pages** — `docs/explanation/effects.md` (OCaml 5 effects primer), `docs/explanation/why-ocaml.md` (rationale for OCaml over Python), `docs/explanation/skills-vs-tools.md` (skills vs tools vs middleware decision guide).

### Changed — Strategy & Quality Gates (Track D)

- **D.1 STRATEGY.md pivot** — `docs/STRATEGY.md` updated: §7 now mandates skill support (was "deferred to v1.0+"). Rationale: an integrator has begun adoption.
- **D.3 Acceptance test** — `test/test_acceptance_skill.ml` validates end-to-end skill activation with Mock provider, asserting the overridden system_prompt is actually sent to the LLM.

### Verified

- Skill activation pipeline **E2E verified with Mock provider**:
  - `compute_active_skill_effects` correctly called during `Runtime.invoke` (3 risk points)
  - System prompt override actually reaches the LLM (mock recorded `"OVERRIDDEN"` not `"ORIGINAL"`)
  - 110 OCaml tests + 1043 assertions pass
  - 36 Python tests pass (1 pre-existing RAG e2e failure unrelated to v0.5.2 — see "Known Limitations")

### Test Count

- 110 OCaml tests (1043 assertions)
- 36 Python tests passing, 1 pre-existing failure (RAG e2e — `add_documents` returns -5 on certain test fixtures, tracked separately)

### Known Limitations (deferred to v0.5.3)

- **B.3 Incremental streaming** — current implementation buffers chunks and returns all at once (per v0.5.1 trade-off). True incremental streaming planned.
- **C.7 Tutorials** — interactive Jupyter notebook tutorials not yet shipped. Markdown how-to guides are the current surface.
- **`apply_skill_effect_to_config` for `tool_filter`** filters `agent_config.tools` list but not the runtime's `tool_registry`. Defense-in-depth gap, not blocking. (If a skill lists `Only [foo; bar]` but a tool `baz` is already registered globally, `baz` is still callable via direct FFI. For most usage this is correct behavior — skills filter what's offered to the LLM, not what's technically available.)

### Upgrade Notes

- **No breaking changes from v0.5.1**. The skill system is purely additive.
- Skills are optional — existing agents work unchanged.
- To use skills: drop a `skill.md` file in `~/.par/skills/<id>/` (or call `Runtime.register_skill` from Python). See `docs/sdk/skills.md`.

### Contributors

@Neo20250413 (code, design, docs)

---

## v0.5.1-beta.20260623 (IN DEVELOPMENT)

> **Theme**: RAG foundation + Python streaming (buffered) + FFI work-loop architecture + configurable embedding model + HTTP timeout fix + ReAct loop hardening.

### Changed — ReAct loop retry/timeout hardening (7 fixes)

**Problem**: Engine ReAct loop had multiple retry/timeout bugs: retries didn't consume iteration budget (max_iter=1 could make 4+ LLM calls), Timeout middleware caused infinite retries, no wall-clock timeout, Retry middleware reset per iteration, no `<think>` tag handling.

**Fixes** (based on competitive analysis of LangChain, OpenAI Agents SDK, CrewAI, AutoGen):
1. **Wall-clock timeout**: `agent_config.max_execution_time : float option` — loop checks elapsed time, returns `Timeout` error if exceeded
2. **Retries consume iterations**: retry path now passes `iterations + 1` (was unchanged) — industry consensus from all competitors
3. **Timeout middleware on_error removed**: eliminates infinite-retry causal chain (Timeout mw → retryable=true → Retry mw → repeat)
4. **Retry budget per-invocation**: removed per-iteration reset of retry counter — 3 retries is the total, not per-iteration
5. **Graceful degradation**: `agent_config.early_stopping_method` (`Force` | `Generate`) — when iterations exhausted and `Generate`, makes one final LLM call for best-effort answer
6. **`<think>`/`<reasoning>` tag stripping**: `json_extract.ml` now strips reasoning blocks before JSON parsing — prevents spurious repair loops with DeepSeek-R1, QwQ, MiniMax-M3
7. **Context-length error classification**: engine detects context-length-exceeded errors from provider messages, applies context strategy, retries

**New types**: `Types.early_stopping_method = Force | Generate`
**New agent_config fields**: `max_execution_time : float option`, `early_stopping_method : early_stopping_method`

### Changed — HTTP request timeout (fixes engine hang on long prompts)

**Root cause**: cohttp-eio `Client.call` and `Buf_read.take_all` had no timeout. When LLM response was slow (correlated with 800-1500 char prompts), the HTTP read blocked indefinitely. Combined with the single-threaded work loop, one stuck request wedged the entire Runtime.

**Fix**: Added `Http_client.with_timeout` — each `do_request`/`do_request_streaming` forks a daemon fiber that sleeps 60s then fails the switch. Timeout errors are mapped to `Types.Timeout` (not `Invalid_input`), enabling `Retry` middleware to retry automatically.

**Known limitation**: MCP HTTP/SSE transport (`mcp_transport_http.ml`) and `fetch_url` builtin tool do not yet have timeouts. A stuck MCP server or URL fetch can still wedge the Runtime. Deferred to v0.5.2.

### Changed — Streaming architecture (buffered, no daemon thread)

**Root cause fixed**: Python `_StreamReader` previously ran `par_invoke_stream` on a daemon `threading.Thread` that had no OCaml domain lock, causing `Fatal: no domain lock held` on every streaming call. Fix: removed the daemon thread entirely. `_StreamReader` now calls `par_invoke_stream` on the main thread. The OCaml work loop buffers chunks internally and returns them all with the final result as JSON. Python parses the chunks array and yields Events.

Trade-off: chunks arrive all at once after the LLM completes (buffered, not incremental). True incremental streaming is planned for v0.5.2.

### Changed — Configurable embedding model

Added `embedding_model : string option` to the `Openai` provider config variant. When set, overrides the default `"text-embedding-3-small"`. Example:
```json
["Openai", {"api_key": "...", "embedding_model": "Qwen/Qwen3-Embedding-8B"}]
```
The `Ollama` variant does not yet have this field — Ollama embeddings use the OpenAI default (tracked as known limitation).

### Changed — Dead code cleanup

Removed `import queue`, `import threading`, `_DONE` sentinel from `runtime.py` (no longer needed after streaming refactor).

### Changed — Error handling

`_StreamReader._fetch` now raises `PARInvokeError` on `status != "ok"` instead of silently returning an empty iterator.

### Changed — Documentation

Updated `docs/sdk/streaming.md` implementation notes to describe the buffered architecture. Updated `invoke_stream` docstring in `runtime.py`.

### Real API Verification (SiliconFlow)

All 5 endpoints verified against real API:
- embed (Qwen3-Embedding-8B, 4096 dims): PASS
- add_documents: PASS
- invoke (Qwen2.5-7B-Instruct): PASS
- invoke_with_rag: PASS
- invoke_stream (4 chunks, no crash): PASS

### Test Count

- 998 OCaml tests
- 57 Python tests (1 skipped)

---

## v0.5.1-beta.20260622

> **Theme**: RAG foundation (OCaml SDK) + Python streaming output + full FFI work-loop architecture. First feature release of the 0.5.x series.
>
> **Status**: Beta — OCaml SDK has full RAG + streaming. Python SDK has streaming (13 tests), `rt.embed()` (real end-to-end via mock HTTP server), and `add_documents`/`invoke_with_rag` (real end-to-end with internal vector store).

### Added — Track B (RAG Foundation, OCaml SDK)

- `Runtime.embed : runtime -> string list -> (float array list, error_category) result` — batch embedding API (OpenAI, Mock, Anthropic-raises-unsupported)
- `lib/core/vector_store.ml` — embedding-agnostic vector store with SQLite + sqlite-vec backend (cosine similarity, upsert, KNN search)
- `lib/core/chunking.ml` — text chunking (char/token/recursive splitters, LangChain-compatible)
- `Runtime.invoke_with_rag` — RAG orchestration (embed → search → augment → invoke)
- `EMBEDDING_SERVICE` module type + `embedding_service` record in types.ml
- `Embedding_unsupported` error constructor
- sqlite-vec v0.1.9 vendored at `vendor/sqlite-vec/linux-x86_64/vec0.so` and `vendor/sqlite-vec/macos-aarch64/vec0.dylib`

### Added — Track C (Python Streaming, full)

- `Runtime.invoke_stream(agent_id, message) -> Iterator[Event]` — Python generator yielding streaming events
- `Event` union: `TextDelta`, `ToolCallStart`, `ToolCallDelta`, `UsageUpdate`, `Done` (all exported from `par_runtime` package)
- `par_invoke_stream` C entrypoint + `par_chunk_callback` typedef in FFI
- `par_event_subscribe` wired (was stub)
- `docs/sdk/streaming.md` — design + 3 runnable examples
- 13 streaming tests (all passing)

### Added — Documentation

- `docs/sdk/rag.md` — RAG API reference with 3 examples
- `docs/sdk/streaming.md` — streaming design + examples
- `docs/plans/b2-vector-store-design.md` — vector store interface design rationale
- `docs/v0.5.1-ROADMAP.md` — release roadmap with execution tracker

### Changed — FFI Architecture Overhaul (方案 1: config-based embedding)

The Python FFI bridge was rebuilt to fix a fundamental Eio context issue.

- **Persistent Eio domain per Runtime**: `do_init` now spawns a long-lived Domain running `Eio_main.run` with a work-loop. All FFI callbacks (`par_invoke`, `par_embed`, `par_register_tool`, etc.) dispatch work items through a `Mutex`/`Condition`/`Queue` to this domain. The runtime value never crosses domain boundaries — eliminating the prior `Stdlib.Effect.Unhandled(Eio__core__Cancel.Get_context)` crash that affected every end-to-end LLM call.
- **Config-based provider wiring**: when `llm_providers` is set in the config JSON, `do_init` automatically constructs both an `llm_service` (wired to `Openai_provider.complete`/`stream`/`close`) and an `embedding_service` (wired to `Openai_provider.embed`/`close`). Ollama providers are mapped to an OpenAI-compatible endpoint with a placeholder API key. Anthropic and Custom providers raise a clear "not yet supported" log message and fall back to the default no-op service.
- **HTTP_client gained `http://` support**: `parsed_url` now carries a `use_tls` flag, and `do_request`/`do_request_streaming` skip TLS for plain HTTP URLs. Enables testing against local mock OpenAI-compatible servers and connecting to local Ollama without TLS.
- **`Mirage_crypto_rng_unix.use_default ()`** is now called inside `Eio_main.run` so HTTPS/TLS works on first call (previously failed with "default generator is not yet initialized").
- **Shutdown via sentinel**: `do_shutdown` enqueues a sentinel work item after the `Runtime.close` work item; the work loop exits cleanly when it sees the sentinel, and `Domain.join` reaps the domain. Avoids `Domain.terminate` (broken in OCaml 5) and ensures no leaked domains.
- **Debug logging gated by `PAR_FFI_DEBUG=1`**: `fd_log` writes directly to fd 2 (bypassing per-domain stderr buffering); enable with `PAR_FFI_DEBUG=1` to see work-loop activity.

### Added — Python package exports

- `Done`, `Event`, `TextDelta`, `ToolCallStart`, `ToolCallDelta`, `UsageUpdate` are now exported from the top-level `par_runtime` package (previously only accessible via `par_runtime.runtime`).

### Known Limitations (beta)

- **Event bus types** (`Embedding_request_sent`, etc.) — not added (skipped to avoid cascading pattern match changes).
- **Python streaming against real LLM** — `par_invoke_stream` is wired through the work loop, but no end-to-end test exists yet (streaming chunk callback runs in the work-loop domain).

### Test Count

- 998 OCaml tests (987 baseline + 8 embedding/chunking + 3 RAG integration)
- 58 Python tests (32 baseline + 13 streaming + 4 embed + 2 RAG provider + 3 end-to-end mock server + 4 misc, 1 skipped)

---

## v0.5.0 (RELEASED 2026-06-21)

> Apple Silicon macOS native wheel added. `pip install par-runtime` now works natively on Apple Silicon Macs, no source build or Rosetta required. Intel Mac users (`x86_64`) cannot `pip install` in v0.5.0 (no `macosx_*_x86_64` wheel and no sdist shipped — `macos-13` runner permanently abandoned 2026-06-19, see `ci.yml` L16); they can either (a) stay on `par-runtime==0.4.13` until v0.5.1 ships an sdist, or (b) build from source via `git clone && make install`. ARM64 Linux wheel **deferred to v0.5.1+** — GitHub Actions free-tier ARM64 runners are saturated (queue 45min+, never dispatched) and qemu-binfmt on x86_64 host crashes manylinux container on start.

### Added

- **`par_runtime-0.5.0-py3-none-macosx_11_0_arm64.whl`** (6.5 MB) — ARM64 macOS wheel. Built on `macos-15` runner, `brew install gmp sqlite3`, `delocate-wheel` for dylib bundling, `wheel tags --platform-tag macosx_11_0_arm64` to set the platform tag (ctypes .so gets `py3-none-any` by default from setuptools).

### Changed

- **`pypi-publish.yml`**: single hardcoded job refactored into a 2-job matrix `{linux-x86_64, macos-arm64}`. `gh-release-upload` and `pypi-upload` jobs download both artifacts and publish together. `auditwheel` for Linux (existing v0.4.13 path unchanged), `delocate-wheel` + `wheel tags` for macOS.
- **`release-acceptance.yml`**: split into 2 jobs (`accept-linux-x64` 3-container matrix + `accept-macos-arm64` native runner). Removed the v0.4.13 `WHEEL_COUNT -ne 1` guard (each job downloads its matching wheel by glob pattern, e.g. `*-manylinux_2_28_x86_64.whl`).

### Trade-offs accepted

- **No ARM64 Linux wheel in v0.5.0.** Attempted `ubuntu-22.04-arm64`, `ubuntu-24.04-arm64` runners — both saturated 45min+ on free tier. Attempted qemu-binfmt on `ubuntu-22.04` host with `quay.io/pypa/manylinux_2_28_aarch64:latest` container — container crashes on start (`Error response from daemon: container is not running`). User decision 2026-06-21: skip ARM64 Linux for v0.5.0, defer to v0.5.1+ when GH Actions ARM quota improves OR self-hosted runner is available.
- **No Intel Mac native wheel.** `macos-13` (Intel) runner queue 24h+ then max-execution-time on free tier (`ci.yml` L16). True `universal2` (which needs both `macos-13` + `macos-15` slices) is NOT achievable without paid minutes. Intel Mac users continue to fall back to source distribution (PyPI 2026 Intel Mac share <5%).

### Verification Evidence

- **PyPI**: https://pypi.org/project/par-runtime/0.5.0/ — 2 wheels: `par_runtime-0.5.0-py3-none-manylinux_2_28_x86_64.whl` (11.3 MB) + `par_runtime-0.5.0-py3-none-macosx_11_0_arm64.whl` (6.5 MB)
- **GH Release**: https://github.com/jcz2020/par/releases/tag/v0.5.0 — 2 wheel assets
- **CI iterations**: 8 (post1 → post8). Key fixes: (a) drop aarch64 job after ARM runner saturation; (b) rename macos wheel from `py3-none-any` to `macosx_11_0_arm64` via `wheel tags` (filename-only rename fails PyPI 400 — internal WHEEL Tag field must match); (c) remove stale aarch64 download steps after matrix shrink.

---

## v0.4.13 (RELEASED 2026-06-21)

> Wheel platform tag fix: `py3-none-any` → `py3-none-manylinux_2_28_x86_64`. Resolves the misleading tag that claimed "any platform" while shipping a 29 MB x86_64 Linux ELF binary. Built inside `quay.io/pypa/manylinux_2_28_x86_64` container so glibc baseline is 2.28 (RHEL 8+, Ubuntu 18.10+, Debian 10+). GMP and sqlite3 bundled via auditwheel.

### Fixed

- **Wheel platform tag** (PAR-cog class): wheel was tagged `py3-none-any` (any platform) but actually requires x86_64 Linux + glibc ≥ 2.35 (ubuntu-22.04 build host). macOS / Windows / ARM users would `pip install` successfully, then crash at `import par_runtime` with `OSError: cannot open shared object file`. Now built in manylinux_2_28 container, repaired with auditwheel, and correctly tagged `manylinux_2_28_x86_64`.

### Changed

- **`pypi-publish.yml`**: `build-wheel` job now runs inside `quay.io/pypa/manylinux_2_28_x86_64:latest` container (was `ubuntu-22.04`). Installs opam + OCaml 5.4 + PAR deps inside the container, builds `par_capi.so` against glibc 2.28, runs `auditwheel repair --plat manylinux_2_28_x86_64` to bundle GMP + sqlite3 and tag the wheel. Uses `ocaml/setup-ocaml@v3` inside the container (handles opam pinning) plus `opam install par_cli --deps-only -y` to fetch runtime deps (gmp, sqlite3, etc.) in the manylinux env.

### Removed (after iteration)

- **`bindings/python/par_runtime/_loader.c`** and **`bindings/python/setup.py`** (added then removed across post1-post8). Initially added to give auditwheel a DT_NEEDED entry that the bare ctypes-loaded `.so` lacked (pypa/auditwheel#197). Removed when confirmed that modern auditwheel v6+ uses `allow_graft=True` by default and walks ALL ELF files in the wheel tree, including ctypes-loaded `.so` referenced via `package_data`. No dummy extension is needed.

### Verification Evidence

- **PyPI**: https://pypi.org/project/par-runtime/0.4.13/ — `par_runtime-0.4.13-py3-none-manylinux_2_28_x86_64.whl` (11.3 MB)
- **GH Release**: https://github.com/jcz2020/par/releases/tag/v0.4.13 — wheel asset uploaded
- **Acceptance CI** (run #27902139530): success on `debian:12`, `ubuntu:22.04`, `ubuntu:24.04`
- **CI iterations**: 12 (post1 → post12) — key fixes were (a) use `ocaml/setup-ocaml@v3` inside container instead of bare `opam install`, (b) drop `_loader.c` after auditwheel proved it walks ctypes `.so` via `allow_graft`, (c) separate `gh-release-upload` job outside container (gh CLI not in manylinux image)

### Test Count

- 987 OCaml tests (unchanged — no `.ml` files modified).
- 33 Python tests (unchanged).

---

## v0.4.12 (RELEASED 2026-06-21)

> CI/release pipeline hardening + audit pass. No user-facing OCaml/Python API changes. All work is in `.github/workflows/`, `docker/`, and test infrastructure.

### Fixed

- **3-way GH Release race**: `release.yml`, `pypi-publish.yml`, and `opam-publish.yml` all called `softprops/action-gh-release@v2` on the same tag push, causing intermittent "Validation Failed: already_exists" failures (notably opam-publish on v0.4.11). Now `release.yml` is the sole release creator; `pypi-publish.yml` and `opam-publish.yml` use `gh release upload --clobber` after polling for the release to exist (30 retries × 10s).
- **opam-publish.yml `${VERSION}` unset bug**: the `Print manual instructions` step referenced a shell variable that was scoped to a different step. Now derived from `github.ref_name` at step level.
- **opam package surface inconsistency**: `pypi-publish.yml` and `opam-publish.yml` used `*.opam` wildcard (would include `par_postgres.opam`, which CI explicitly excludes). Now all 4 release-related workflows use the explicit list `par.opam + par_cli.opam`, matching CI.

### Added

- **Nightly build** (`.github/workflows/nightly.yml`): scheduled 06:00 UTC daily, runs full OCaml + Python test suite on `ubuntu-22.04` + `macos-15` matrix. Catches upstream bit-rot from opam dependencies. Includes `workflow_dispatch` for manual re-runs and `pull_request: paths:` trigger so PRs that touch the nightly YAML can test it without waiting for midnight.
- **CodeQL security scan** (`.github/workflows/codeql.yml`): weekly scan of Python bindings + GitHub Actions workflows. CodeQL does NOT support OCaml (verified 2026-06-21 against the official supported-languages list), so OCaml source is excluded — the ctypes surface and workflow injection paths are the real vuln surface anyway.
- **Dependency Review** (`.github/workflows/dependency-review.yml`): every PR to main gets a vulnerability scan via `actions/dependency-review-action@v4`. Fails on high-severity runtime vulnerabilities. Comments on PR only on failure (avoids spam). Shows OpenSSF scorecard for newly-added deps.
- **Python version matrix** in `ci.yml`: expanded from `3.11` only to `3.8 / 3.9 / 3.10 / 3.11 / 3.12 / 3.13 / pypy3.10`. ctypes is version-agnostic in theory, but Python 3.13 changed `RTLD_GLOBAL` default and PyPy has its own quirks.
- **OIDC PyPI trusted publisher** in `pypi-publish.yml`: new `pypi-upload` job uses `pypa/gh-action-pypi-publish@release/v1` with `id-token: write` permission. **Requires one-time user setup**: register the trusted publisher at `https://pypi.org/manage/project/par-runtime/settings/publishing/` (owner=`jcz2020`, repo=`par`, workflow=`pypi-publish.yml`, environment=`pypi`). Until done, this job fails with 403 and the manual `twine upload` fallback in `build-wheel` is used.
- **manylinux Dockerfile** (`docker/manylinux-ocaml-5.4/Dockerfile`): scaffold for future manylinux_2_28_x86_64 wheel builds. Not yet integrated into `pypi-publish.yml` — requires auditwheel + dummy C extension work that was deferred to v0.4.13+.

### Changed

- `bindings/python/pyproject.toml`: added `wheel` to `[build-system] requires` (standard practice; was implicit).

### Verification Evidence

- **v0.4.12-beta.20260621** CI run URLs:
  - CI (main): https://github.com/jcz2020/par/actions/runs/27886279614 — 4m53s SUCCESS (Python 3.8-3.13 + pypy3.10 matrix)
  - CodeQL: https://github.com/jcz2020/par/actions/runs/27886279621 — 1m7s SUCCESS (Python + Actions, no OCaml)
  - Release: https://github.com/jcz2020/par/actions/runs/27886279613 — 7m55s SUCCESS
  - opam publish: https://github.com/jcz2020/par/actions/runs/27886279620 — 8m2s SUCCESS (race fix verified — no more "already_exists")
  - PyPI publish (build-wheel): SUCCESS — wheel `par_runtime-0.4.12b20260621-py3-none-any.whl` on GH Release
  - PyPI publish (pypi-upload OIDC): FAILED (expected — user has not yet registered trusted publisher on PyPI). `continue-on-error: true` prevents cascade failure.
  - Release acceptance (manual re-trigger): https://github.com/jcz2020/par/actions/runs/27886492611 — SUCCESS on all 3 platforms (debian:12, ubuntu:22.04, ubuntu:24.04)
- **Race fix verified**: opam-publish succeeded (was failing in v0.4.11 with "already_exists").
- **New workflows verified working**: CodeQL ran successfully on first push. Nightly + Dependency-review will trigger on schedule / next PR respectively.
- **PyPI verification**: v0.4.12 stable wheel will be uploaded via manual `twine upload` (OIDC not yet active). URL: https://pypi.org/project/par-runtime/0.4.12/ (after upload)

### Test Count

- **987 OCaml tests (unchanged from v0.4.11)**. v0.4.12 changes are CI workflows + Docker scaffolding + pyproject.toml only; no `.ml` files in `lib/`, `bin/`, or `test/` were modified.
- 33 Python tests passing (unchanged).

---

## v0.4.11 (RELEASED 2026-06-21)

> Release engineering fix: thoroughly solve 3 P0 release bugs from v0.4.8/9/10 + add end-to-end acceptance test to prevent recurrence. PAR-j8i epic.

### Bug Fixes

- **PAR-0qf** (P0): wheel missing `par_capi.so` — fixed in v0.4.9 (workflow path correction), prevention mechanism added in v0.4.11.
- **PAR-8cs** (P0): binaries + wheel required `GLIBC_2.38` — binary fixed in v0.4.10 (ubuntu-latest → ubuntu-22.04), prevention mechanism added in v0.4.11.
- **PAR-cog** (P0): wheel built as `UNKNOWN-0.0.0` due to setuptools <61 — fixed in v0.4.11 by using a fresh venv for the setuptools upgrade step (the simple `pip install --upgrade` was insufficient when site-packages is read-only on ubuntu-22.04).

### New Infrastructure

- **`scripts/release-acceptance-test.py`**: end-to-end install test (Level 1: import + version, Level 2: Runtime lifecycle, Level 3: informational). Stdlib-only Python 3, runnable locally and in CI. Verified working on debian:12, ubuntu:22.04, ubuntu:24.04, and real Debian 12 dev box.
- **`.github/workflows/release-acceptance.yml`**: 3-platform matrix (debian:12, ubuntu:22.04, ubuntu:24.04) runs the acceptance script after `pypi-publish` completes. GATES PyPI upload — if any platform fails Level 1 or 2, the release is broken and must not be uploaded.
- **`scripts/release-local-test.sh`**: Docker-based local dry-run. Builds wheel locally, runs acceptance test in each container, reports per-platform pass/fail.

### Workflow Changes

- `pypi-publish.yml`: create fresh venv and `pip install --upgrade pip setuptools wheel` before `pip wheel` (PAR-cog fix). The simple `pip install --upgrade` was insufficient when ubuntu-22.04's system site-packages is read-only — the new setuptools ended up in `~/.local` and was not picked up by the subsequent `pip wheel` invocation.
- (Already in v0.4.10) All workflows pin `ubuntu-22.04` instead of `ubuntu-latest`.
- (Already in v0.4.9) `pypi-publish.yml` copies `par_capi.so` to `bindings/python/par_runtime/lib/`.

### Verification

- Acceptance test PASS on all 3 platforms (CI run #27884516848, manual re-trigger on v0.4.11-beta.20260621.post2 release)
- Acceptance test PASS on v0.4.11 stable (CI run #27884715322, workflow_run trigger from pypi-publish)
- Real-machine install on Debian 12 (glibc 2.36) dev box: PASS
- PyPI install: `pip install par-runtime==0.4.11` (from official PyPI) then `import par_runtime` then `Runtime(config)` lifecycle: PASS
- Wheel `par_runtime-0.4.11-py3-none-any.whl` uploaded to PyPI
- URL: https://pypi.org/project/par-runtime/0.4.11/

### Documentation

- `docs/rules/release.md`: new "End-to-End Release Test" section documents the 4-step mandatory procedure (local dry-run, CI gate, manual twine upload, post-upload matrix verification).
- `docs/release-pipeline-redesign.md`: postmortem + scope split (v0.4.11 MVP vs v0.5+ stretch goals like manylinux).

### Test Count

- **987 OCaml tests (unchanged from v0.4.10)**. v0.4.11 changes are CI workflows + Python scripts + docs only; no `.ml` files in `lib/`, `bin/`, or `test/` were modified (verified via `git diff --name-only v0.4.10..v0.4.11 | grep '\.ml$'` returns empty).
- 33 Python tests passing (verified via `grep -c "def test_" bindings/python/tests/*.py` returns 33).

### Verification Evidence

- **v0.4.11 stable** CI run URLs (all green):
  - CI (main): https://github.com/jcz2020/par/actions/runs/27884642182 — 5m13s
  - PyPI publish: https://github.com/jcz2020/par/actions/runs/27884642217 — 3m3s
  - opam publish: https://github.com/jcz2020/par/actions/runs/27884642230 — 3m31s
  - Release acceptance: https://github.com/jcz2020/par/actions/runs/27884715322 — 14s
- **v0.4.11-beta.20260621.post2** (advance verification) CI run URLs (all green):
  - Manual re-trigger acceptance: https://github.com/jcz2020/par/actions/runs/27884516848 — 16s
- **PyPI verification**: https://pypi.org/project/par-runtime/0.4.11/ shows v0.4.11 stable; `pip install par-runtime==0.4.11` succeeds in a clean venv.
- **Real-machine install matrix**:
  - Debian 12 (glibc 2.36) dev box: `pip install par-runtime==0.4.11` + `import par_runtime` + `Runtime(config)` lifecycle + `rt.close()`: PASS
  - debian:12 container (CI): PASS (run 27884715322)
  - ubuntu:22.04 container (CI): PASS (run 27884715322)
  - ubuntu:24.04 container (CI): PASS (run 27884715322)
- **Issues resolved**: PAR-0qf, PAR-8cs, PAR-cog, PAR-j8i, PAR-b94.

## v0.4.10 (2026-06-21)

> Hotfix: CI builds now use ubuntu-22.04 (glibc 2.35 baseline) instead of ubuntu-latest (glibc 2.38). PAR-8cs.

### Bug Fixes

- **PAR-8cs** (P0, **CRITICAL**): All release artifacts built on `ubuntu-latest` (= Ubuntu 24.04, glibc 2.39) required `GLIBC_2.38` symbols. This excluded Debian 12 (glibc 2.36), Ubuntu 22.04 LTS (glibc 2.35), and RHEL 9 (glibc 2.34) — i.e. most production Linux distros. Users on these systems saw `version GLIBC_2.38 not found` when running `par --version` or `import par_runtime`. Fix: pin all 4 workflows (ci/release/opam-publish/pypi-publish) to `ubuntu-22.04`. Resulting binaries require only glibc 2.35, compatible with Ubuntu 22.04 LTS+, Debian 12+, RHEL 9+. RHEL 8 (glibc 2.28) and older still require source build — manylinux wheel is a separate follow-up.

### Workflow Changes

- `.github/workflows/ci.yml`: matrix `ubuntu-latest` → `ubuntu-22.04`; python job `runs-on` updated; artifact name `par-capi-ubuntu-latest` → `par-capi-ubuntu-22.04`.
- `.github/workflows/release.yml`: matrix `ubuntu-latest` → `ubuntu-22.04`; release job `runs-on` updated.
- `.github/workflows/opam-publish.yml`: `runs-on: ubuntu-latest` → `ubuntu-22.04`.
- `.github/workflows/pypi-publish.yml`: `runs-on: ubuntu-latest` → `ubuntu-22.04`.

### Test Count

- 987 OCaml tests (unchanged).
- 33 Python tests (unchanged).

## v0.4.9 (2026-06-21)

> Hotfix: par-runtime 0.4.8 wheel on PyPI was broken (missing `par_capi.so`). PAR-0qf.

### Bug Fixes

- **PAR-0qf** (P0, **CRITICAL**): `pypi-publish.yml` workflow copied `par_capi.so` to `bindings/python/par_runtime/` (package root), but `pyproject.toml` and `_ffi.py` expect it at `bindings/python/par_runtime/lib/par_capi.so`. Result: any user who ran `pip install par-runtime==0.4.8` got `OSError: par_capi.so: cannot open shared object file` on `import par_runtime`. Verified locally: fixed workflow builds wheel (9.9 MB) containing `par_runtime/lib/par_capi.so`; Runtime init + tool registration + close all work end-to-end in clean venv. v0.4.8 on PyPI should be yanked manually by maintainer (upload-scoped token lacks management scope).

### Workflow Changes

- `.github/workflows/pypi-publish.yml`: `Copy shared library for wheel` step now `mkdir -p bindings/python/par_runtime/lib` before `cp` (1-line fix).

### Test Count

- 987 OCaml tests (unchanged from v0.4.8).
- 33 Python tests (unchanged from v0.4.8).

## v0.4.8 (2026-06-21)

> Feature: Runtime.invoke_structured — schema-validated LLM output. PAR-xd5 + PAR-5cc.

### New Features

- **Structured output API** (PAR-xd5, P0): `Runtime.invoke_structured ~agent_id ~message ~response_schema` returns schema-validated JSON instead of free text. The function returns `structured_invoke_result = { value; raw_response; conversation; attempts }` so callers can chain follow-up turns and observe repair-loop behavior.
- **OpenAI native structured output** (WU-3): `Openai_provider.complete_structured` emits `response_format: { type: "json_schema", json_schema: { name, schema, strict: true } }` per the [OpenAI Structured Outputs spec](https://platform.openai.com/docs/guides/structured-outputs).
- **Schema normalization for OpenAI strict mode** (Oracle D5 must-fix): `Openai_provider.normalize_for_openai_strict` warns about silent server-side rewrites (forces `additionalProperties: false`, marks all properties `required`, converts `const → enum`). Without local normalization, users get semantically wrong output while PAR reports success.
- **Anthropic native structured output** (WU-4): `Anthropic_provider.complete_structured` uses the 2026 GA `output_config.format` field. JSON lands in `content[0].text` as a JSON-encoded string.
- **Engine feedback repair loop** (WU-2.2): on JSON parse or schema-validation failure, `Engine.run_structured` appends repair messages to conversation and retries up to `max_repair_attempts` (default 3). Cancellation token is checked at the top of each iteration (Oracle BS-1 must-fix). Middleware `on_before_llm` / `on_after_llm` hooks still fire (Oracle D2 must-fix); only `on_error` is bypassed because the loop is the repair authority.
- **Mock provider structured support** (WU-5): `Mock_provider.create` now accepts `?structured_response:Yojson.Safe.t` for test override, or synthesizes a minimal valid object from the request schema's top-level properties.
- **Generic fallback path**: when `llm_service.complete_structured_fn = None` (e.g. Ollama, Custom providers), the engine prepends a JSON Schema directive to the system prompt, calls `complete_fn`, then locally validates the response against the schema. Falls back gracefully without rejecting the provider.
- **Python FFI binding** (WU-7): `Runtime.invoke_structured(agent_id, message, response_schema)` accepts a Python dict schema, returns a parsed dict, raises `PARInvokeError` on failure. C ABI `par_invoke_structured` exposed alongside `par_invoke`.
- **New event type**: `Structured_output_completed of { attempts; schema_valid; task_id }` fires after every structured call for observability subscribers.
- **Lenient JSON extraction** (WU-2.1): `Json_extract.extract_json_from_text` strips markdown fences (` ```json `, ` ``` `), extracts balanced `{...}` / `[...]` blocks from prose, and skips over string literals to avoid false-depth scans.

### API Changes

- **`Types.llm_service`** (additive, non-breaking): new optional field `complete_structured_fn : (... -> Yojson.Safe.t -> (llm_response, error_category) result) option`. Default `None` means fallback path. Existing custom providers keep compiling; they just don't get native structured support until they populate the field.
- **`Types.structured_invoke_result`** (new type): `{ value : Yojson.Safe.t; raw_response : llm_response; conversation : conversation; attempts : int }`.
- **`Types.event`** (additive variant): new constructor `Structured_output_completed of { attempts : int; schema_valid : bool; task_id : Task_id.t }`. Exhaustive `match event with ...` consumers without a catch-all arm must add an explicit branch.
- **`Runtime.invoke_structured`** (new public val): signature in `runtime.mli` after `invoke`.
- **`Engine.run_structured`** (new public val): signature in `engine.mli` after `run_agent`.
- **`Mock_provider.create`** (additive, optional param): new `?structured_response:Yojson.Safe.t`.

### Limitations (documented per Oracle D4)

The in-tree JSON Schema validator (`Validation.validate_value`) checks **top-level object properties only** in the fallback path (type, required, enum, minimum/maximum, minLength/maxLength). Array `items`, nested object `properties`, and `oneOf` / `anyOf` are NOT validated locally. **Native providers (OpenAI strict mode, Anthropic output_config.format) validate deeply server-side** — the local limitation only affects the fallback path. Full nested validation deferred to v0.5.

### Test Count

- 987 OCaml tests (+13 new: engine_structured feedback loop, cancellation, middleware hooks, json_extract variants).
- 33 Python tests (+2 new: invoke_structured signature + error path).

## v0.4.7 (2026-06-19)

> Hotfix: ignore hallucinated tool_calls when agent has no tools.

### Bug Fixes

- **PAR-70i** (P1): When `agent.tools = []`, LLM providers that hallucinate tool_calls (e.g. MiniMax) no longer cause API 400 errors. Engine now checks `agent.tools <> []` before entering tool execution branch. Hallucinated tool_calls are safely ignored and `resp.text` is used as the final output.

## v0.4.6 (2026-06-18)

> CLI stability fix. 4 bugs fixed (2 P0 + 2 P3). Removes linenoise dependency.

### Bug Fixes

- **PAR-qyr** (P0, **VERIFIED**): CJK input and backspace now work correctly. Replaced both linenoise (byte-oriented, broke CJK) and input_line stdin (canonical mode, macOS Terminal.app doesn't handle CJK backspace). New `bin/repl_input.ml` uses raw mode (`c_icanon=false`) with custom UTF-8 character assembly and display-width-aware backspace (ASCII=1col, CJK=2cols). **Manually verified by user in real terminal.**
- **PAR-8yg** (P0): REPL no longer hangs after bash tool failure. Root cause: `input_line stdin` in bash_confirm was a blocking OCaml stdlib call inside the Eio event loop — it blocked the entire Eio domain, preventing LLM streaming and corrupting subsequent REPL input reads. Fix: replaced interactive y/n prompt with auto-approve + stderr notification. No stdin read during tool hooks = no Eio conflict. Engine post-failure path proven by 2 automated integration tests. **Note**: bash commands no longer prompt for y/n confirmation — they auto-run with stderr notification. Trade-off accepted pending TUI-based confirmation UX.
- **PAR-h7d** (P3): `execute_tool` now receives the LLM's `tool_call_id` instead of generating a fresh `Task_id`. Middleware chain sees the same id as the LLM returned, enabling proper trace correlation.
- **PAR-40a** (P3): Context manager summarization LLM call now emits `Llm_request_sent`/`Llm_response_received` events. Previously only the primary ReAct loop emitted these; `/stats` now counts all LLM calls.

### Breaking Changes

- **Removed dependency**: `linenoise` removed from `par_cli`. REPL arrow key line editing and history recall are no longer available. This is a deliberate trade-off: P0 (CJK input) >> P1 (arrow keys). A proper UTF-8-aware line editor is planned for a future version.

## v0.4.5 (2026-06-18)

> CLI bugfix beta. 11 bugs fixed (4 P0 + 5 P1 + 2 P2). 942 OCaml tests.

### Bug Fixes

- **PAR-zlm** (P0): `par ask` after tool call no longer fails with LLM API 400 "tool call id is invalid". Root cause: engine overwrote LLM-returned `tool_call.id` with a fresh `Task_id`, causing assistant message and tool message to carry mismatched ids.
- **PAR-rev** (P0): Tool execution no longer silently stops the ReAct loop. Same root cause as PAR-zlm — fixed by preserving LLM ids end-to-end.
- **PAR-pso** (P1): Conversation context now correctly includes assistant replies with tool calls. Same root cause as PAR-zlm.
- **PAR-xmb** (P0): REPL no longer dies when a tool handler raises an exception. Engine wraps handler calls in `try/with`, converts exceptions to `Error { category = Internal _ }`. Defense-in-depth: REPL catches all exceptions and continues.
- **PAR-mhs** (P0): REPL no longer corrupts terminal state. Migrated from bare `input_line stdin` to `linenoise` library for proper terminal control.
- **PAR-ngb** (P1): `Llm_request_sent` and `Llm_response_received` events now actually emitted at LLM call sites. Previously defined but never fired — `/stats` showed 0 LLM calls.
- **PAR-v5a** (P1): `par ask 本地有哪些文件夹？` now works without quotes. Switched from single positional `string` to `pos_all` to accept multi-token prompts.
- **PAR-wmj** (P1): Arrow keys (←→↑↓) now work in REPL for cursor movement and history recall.
- **PAR-r05** (P1): Chinese characters can now be deleted cleanly with backspace (UTF-8 aware editing via linenoise).
- **PAR-0yx** (P2): `Tool_completed` event now carries `result_preview : string option` (truncated to 500 chars) so persisted events show what a tool returned, not just that it completed.
- **PAR-br3** (P2): `/health` command now outputs colored human-readable format instead of raw JSON.

### API Changes

- **`Types.Tool_completed`**: Added `result_preview : string option` field. **Source-level breaking change** — consumers who construct or fully pattern-match `Tool_completed` must add the field. Consumers using `_` wildcard still compile. JSON persistence is backward-compatible (old events deserialize with `result_preview = None`).
- **`Anthropic_provider.process_stream_event`**: Now exposed in `.mli` for unit testing.
- **`Openai_provider.parse_stream_delta`**: Now exposed in `.mli` for unit testing.

### Dependencies

- **New**: `linenoise` (BSD-3-clause) added to `par_cli` package for REPL line editing, UTF-8 support, and command history.

## v0.4.4-beta (2026-06-17)

> MCP HTTP/SSE transport (Streamable HTTP, spec 2025-06-18). 918 OCaml tests.

### New Features (§4.1 MCP HTTP/SSE Transport)

- **Transport abstraction**: New `Mcp_transport` module (`lib/mcp/mcp_transport.ml`) defines a uniform `{ request_response; notify; close }` record. Stdio and HTTP both adapt into it, so `Mcp_server` no longer hardcodes a wire protocol.
- **HTTP/SSE transport**: New `Mcp_transport_http` module (`lib/mcp/mcp_transport_http.ml`) POSTs JSON-RPC to a single endpoint URL, handles direct JSON responses and SSE streams, captures the `Mcp-Session-Id` header, and drains notification bodies. Uses `cohttp-eio` with TLS upgrade via `Tls_eio` + `Ca_certs`.
- **`server_config` polymorphic variant**: `Mcp_types.server_config` is now `Stdio_server { command; args; env; cwd; ... } | Http_server { url; headers; ... }`. Both constructors carry `name` and `startup_timeout`. JSON encoding via `server_config_to_yojson` / `server_config_of_yojson`.
- **Relaxed runtime requirements**: `Runtime.create` no longer hard-requires `?mcp_process_mgr` when only HTTP servers are configured. New `?mcp_net` parameter (from `Eio.Stdenv.net env`) is required only when at least one `Http_server` is present.
- **`Mcp_server.spawn`**: Signature gains `?net`; `process_mgr` becomes optional. Dispatch is by config variant — stdio requires `process_mgr`, HTTP requires `net`.

### API Changes

- **`Mcp_types.server_config`**: Breaking change from record to polymorphic variant. All callers updated: `bin/main.ml`, `test/test_mcp_server.ml`, `test/test_mcp_client.ml`, `test/test_mcp_runtime.ml`. Use `Mcp_types.server_name` / `Mcp_types.server_startup_timeout` accessors.
- **`Mcp_server.spawn`**: Signature changed from `~process_mgr:... -> ...` to `?process_mgr:... ?net:... -> ...`. Existing stdio callers compile unchanged.
- **`Runtime.create`**: New optional parameter `?mcp_net:_ Eio.Net.t`. Error messages now distinguish stdio vs HTTP missing dependencies.
- **`Mcp_types.request_id_matches`**: New helper to compare `request_id` values by payload.

## v0.4.4-beta (2026-06-16)

> Multi-agent REPL, session management, bash confirmation. 904 OCaml tests.

### New Features (§5.1 Multi-Agent REPL)

- **Multi-agent config**: `~/.par/config.json` accepts an `"agents"` array with `id`, `system_prompt`, optional `model`, `tools` (subset), `max_iterations`. Backward compatible: no array = single `default-agent`.
- **Auto-generated handoff tools**: Each configured agent gets a `transfer_to_<id>` tool, enabling LLM-initiated handoff.
- **Handoff display**: `↪ from → to` on stderr when `Agent_handoff` event fires.
- **Active agent in prompt**: `par [agent_id]>` (multi-agent only).
- **`/agents`**: Lists registered agents with `(active)`/`(idle)` markers.
- **`/switch <agent_id>`**: Changes active agent.

### New Features (§5.2 Session Management)

- **`par sessions`**: New command lists recent sessions with readable timestamps. `--limit N` flag (default 10).
- **`par history <id>` pretty-print**: Human-readable event chain with `✓`/`✗` styling and `↪` handoff arrows. `--json` flag for raw JSON. `--verbose` for full payloads.
- **`par stats` enhanced**: Adds METRICS section with total events, LLM calls, tool calls, and top tools ranking.
- **`/session` REPL command**: Shows active agent + conversation message count.

### New Features (§5.3 Bash Confirmation)

- **Bash confirmation prompt**: Dangerous bash commands show `⚠ bash: <cmd>\nProceed? [y/n]` in REPL mode. `par ask` auto-allows.
- **`Bash_confirm.make_hook` callback**: Accepts optional `?confirm_fn:(string -> bool)` for custom confirmation logic.
- **`setup_runtime ~interactive:bool`**: REPL = interactive (prompts), `par ask` = non-interactive (auto-allow).

### API Changes

- **`Runtime.list_agents : runtime -> agent_config list`**: New SDK function. Returns all registered agents. Backs the CLI's `/agents` command and enables other consumers (Python binding, future tools) to enumerate agents.

### CLI Changes

- `repl` signature changed from `repl rt agent_id_val` to `repl rt ~agent_ids:string list`
- `setup_runtime` registers multiple agents from config (loop over `cfg.agents`)
- `make_tool_event_callback` handles `Agent_handoff` event variant
- `print_help` documents `/agents` and `/switch`
- `merge_config` carries through `agents` field

## v0.4.2-beta (2026-06-15)

> Typed agent handoff: mid-conversation agent switching via typed ADT signal. Running max-of-chain iteration budget. 901 OCaml tests.

### New Features

- **Typed agent handoff**: Tools can now return `Handoff of { target_agent_id; carry_context; task }` as a typed signal to switch agents mid-conversation. This is a first-class ADT constructor on `handler_result`, not a JSON convention — OCaml's exhaustive pattern matching ensures all code paths handle handoff correctly at compile time. Industry research across OpenAI Agents SDK, LangGraph, AutoGen, and Google ADK confirmed typed ADT is strictly stronger than the JSON-encoded or metadata-dict approaches used by other frameworks.
- **Running max-of-chain iteration budget**: When agent A hands off to agent B, the iteration counter is inherited (prevents infinite handoff loops) but checked against `max(all agents' max_iterations in the chain)` rather than just the target agent's limit. This avoids the "instant-exit surprise" where a downstream agent with a smaller budget would terminate immediately after handoff. Matches the inherited-budget consensus from OpenAI/LangGraph/ADK while improving on their DX.
- **System prompt replacement**: On handoff, the source agent's system prompt is replaced with the target agent's (computed via `Template.effective_system_prompt`). The conversation history (user/assistant/tool messages) is preserved when `carry_context=true`, or reset to just the target's system prompt + task when `carry_context=false`.
- **Agent_handoff event**: New event variant `Agent_handoff of { from_agent; to_agent; task_id }` emitted on every handoff for observability. The `task_id` links to the triggering tool call for `par replay` traceability.
- **Partition-first semantics**: When tools run in parallel and return a mix of `Success` and `Handoff` results, the non-handoff results are folded into the conversation BEFORE the handoff is processed. No silent data loss.
- **`?enable_handoff` flag**: `Runtime.invoke` and `Engine.run_agent` gain `?enable_handoff:bool` (default false) for backward compatibility. When false, any tool returning `Handoff` is treated as an `Invalid_input` error.

### Type Changes

- **`Handoff` variant on `handler_result`**: New third constructor `Handoff of { target_agent_id : string; carry_context : bool; task : string option }`. When `carry_context=false`, the `task` field is required and becomes the target agent's initial user message.
- **`Agent_handoff` variant on `event`**: New event for handoff observability. `extract_task_id` handles this variant (returns the linked tool call's task_id).
- **`Engine.run_agent` signature**: Gains `?agent_resolver:(string -> agent_config option)` and `?enable_handoff:bool` optional parameters.
- **`Runtime.invoke` signature**: Gains `?enable_handoff:bool` optional parameter. When true, passes `~agent_resolver:(fun aid -> htbl_get rt.agents aid)` to the engine.

### Design Decisions (Oracle-reviewed)

Four hard design questions were resolved via cross-framework research + Oracle review (see `docs/v0.4-ROADMAP.md` §3.1 Design Decisions Log):

1. **History shape**: Source system prompt replaced with target's (not just dropped). `carry_context=true` preserves conversation history; `carry_context=false` resets to target's system prompt + task.
2. **Stale tool_call_ids**: Carried as-is by default (matches OpenAI/ADK). No filter implementation — gpt-5 reasoning-chain breakage makes filtering a foot-gun.
3. **Middleware chain**: Implicit full swap on handoff. Per-agent state isolation (Retry/Rate_limit counters reset). Diverges from OpenAI's scoped guardrails — simpler and safer.
4. **max_iterations budget**: Inherited iterations, checked against running max-of-chain. Prevents infinite handoff loops while avoiding the instant-exit surprise.

### Error Cases

All error cases return `Result.Error (Invalid_input _, conversation)`:
- Handoff target not found (agent_resolver returns None)
- `carry_context=false` without a `task` field
- Tool returns `Handoff` when `enable_handoff=false`
- Multiple handoffs in a single tool batch (ambiguous, fail loud)
- Handoff in a workflow `Tool_call` step (workflows don't support handoff)

## v0.4.1-beta (2026-06-15)

> Event persistence now functional end-to-end. Session scoping. CLI history/stats. 885 OCaml tests.

### New Features

- **Event persistence wired**: Events published during `Runtime.invoke` are now persisted to the database via an async buffered writer subscribed to the event bus. The engine's `save_events_fn` is now called for every event.
- **Session scoping**: Each `Runtime.invoke` call generates a fresh `session_id`. Every event envelope carries this `session_id` in its metadata. Events can be queried by session.
- **`par history <session_id>` CLI command**: Shows all events for a given session, formatted as JSON.
- **`par stats` CLI command**: Shows recent sessions with event counts and timestamps in a table format.
- **`Persistence_writer` module**: Async buffered writer that batches events (50ms flush interval, 1000-event buffer capacity) and writes to persistence without blocking the event bus dispatcher. Flushes synchronously on `Runtime.close`.

### Type Changes

- **`session_id` field on `event_metadata`**: Every event envelope now carries a session identifier.
- **`event_bus_service` record type**: Replaces the `EVENT_BUS_SERVICE` module type with a plain record. Runtime event bus injection now uses the record directly.
- **`session_summary` type**: Summary shape for session listings (`session_id`, `event_count`, `first_event_at`, `last_event_at`).
- **`save_events_fn` now accepts `event_envelope list`**: Preserves session and delivery metadata through persistence.

### Bug Fixes

- **Remove `Obj.magic` hack**: Runtime→event_bus path was unsound (fabricated bus instance). Now uses a concrete record.
- **Event_bus.start_dispatcher uses `fork_daemon`**: Was using `fork`, causing switches to hang when dispatcher loops forever.

### Schema Migration

- **SQLite/PostgreSQL**: Added `session_id TEXT NOT NULL DEFAULT ''` column to events table. ALTER TABLE migration for existing databases (idempotent).

## v0.4.0-beta.20260610 (2026-06-10)

> Python callback tools, bash interactive confirmation, structured output validation, SSE stream termination fix, par update no longer rate-limited. 879 OCaml tests, 30 Python tests.

### New Features

- **Python `register_tool_with_handler`**: Register tools with Python callback handlers via C FFI bridge (`par_store_python_handler` + `caml_invoke_python_handler`). 5-arg ABI, backward compatible with existing 4-arg `par_register_tool`.
- **Bash interactive confirmation**: `Bash_confirm` hook module with `confirm_policy` (`Always | Never | Dangerous_only`). Wired into CLI before logging hook.
- **Structured output validation middleware**: `Output_validation` middleware validates tool output against `output_schema` on `tool_descriptor`. Wired into engine `execute_tool`.

### Bug Fixes

- **Fix `par update` GitHub API 403 (rate limit)**: Replaced `api.github.com/repos/.../releases/latest` (anonymous API, 60 req/hr limit) with `github.com/.../releases/latest/download/sha512-checksums.txt` (CDN redirect, no API call, no rate limit). Version is extracted from checksums filenames instead of JSON API response.
- **Fix CLI REPL hang after tool call**: Both OpenAI and Anthropic SSE stream parsers (`process_lines`) never terminated — after receiving `[DONE]` (OpenAI) or `message_stop` (Anthropic), the loop continued calling `read_line()` which blocked forever waiting for data the server would never send. Added a `stop` ref flag checked before each `read_line()` call; set when the terminal SSE event is received. This is the root cause of the v0.3.5-v0.3.7 "REPL dies after ls tool" bug.
- **Fix Python FFI init (`Eio_main.run` in callback)**: `do_init` now spawns `Eio_main.run` in a fresh `Domain` and joins the result. End-to-end Python callbacks now work.
- **Fix Python wrapper config defaults**: `Runtime.__init__` now fills in required OCaml `runtime_config` fields that Python callers commonly omit.
- **Fix Python wrapper `__del__` AttributeError**: `Runtime.__del__` and `Runtime.close` now guard against missing `_handle`.
- **Un-skip Python health/metrics tests**: No longer skipped — FFI init bug fixed.
- **Fix Python test_version_format regex**: Now accepts both `X.Y.Z` and `X.Y.Z-beta-YYYYMMDD`.
- **Fix Python test configs**: Field names updated to match OCaml types.
- **Fix hardcoded version**: `do_version` now uses `Par.Version.version`.

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