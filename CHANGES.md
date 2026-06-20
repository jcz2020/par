# CHANGES

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
- **bd issue closures**: PAR-0qf, PAR-8cs, PAR-cog, PAR-j8i, PAR-b94 all CLOSED via `bd close` and pushed to Dolt remote.

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