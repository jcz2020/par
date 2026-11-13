# Knowledge — Patterns and Traps

## Structured output

- **Two-phase is the correct pattern for tools + schema** (v0.7.4). Don't try interleaved (sending `tools` + `response_format` in the same API call) — CrewAI v1.9.0 proved it breaks on vLLM and non-OpenAI providers. LangGraph, CrewAI (fixed), and PAR all settled on two-phase: ReAct loop first, then separate structured call.
- **`complete_structured_fn = None` for all real providers** in `par_capi.ml` (L180/195/210/225). Only mock provider sets `Some`. This means structured output always uses text-injection fallback (schema directive appended to system prompt). Wiring up real providers' `complete_structured` is a known TODO.
- **`json_extract.ml` processing order matters**: `strip_think_tags → trim → strip_markdown_fences → trim`. Don't reorder — think-tag removal leaves whitespace at position 0, which breaks fence detection if trim doesn't run first.

## Engine internals

- **`run_structured` does NOT execute tool calls** — it passes `tools` to the LLM but only reads `llm_resp.text` for JSON extraction. Tool calls in the response are silently ignored. This is by design for the lightweight path; use `run_agent_structured` when tools need execution.
- **`invoke_handle_cancel` uses CAS loop** (invoke_context.ml L69-79). `fork_invoke` also uses CAS for `Completed` status (L94). Both must use `Atomic.compare_and_set`, not `Atomic.set`, to avoid status flip races.
- **Double-appendix fix stores appendix in conversation metadata** under key `_par_system_prompt_appendix` (defined in `invoke_context.ml:81`). On resume, stored appendix is stripped from system message before applying current. `make_conversation` stores it at creation.

## FFI

- **`caml_copy_string`/`caml_copy_double` must be OUTSIDE `PAR_MUTEX_LOCK`** in `par_ffi.c`. OCaml GC can trigger longjmp on OOM, which would skip `pthread_mutex_unlock` → deadlock. All 5 violations fixed in v0.7.3.

## Testing

- **`per_call_registry_isolation spawn cwd` test fails on CI** — pre-existing, cwd resolution differences. Not a regression. Don't fix without understanding the CI environment's cwd layout.
- **Oracle mock server tests need `mcp_mock_server.exe`** — not built in all environments. Pre-existing.
- **Mutate the implementation, not just the test.** Every fix in v0.16 was checked by removing the implementation and watching the new case fail. A test that passes both before and after the fix proves nothing; the session-restore, lease, approval-terminal, TLS-classification and glob changes were all mutation-checked.
- **Tests that only assert `Success` hide wrong output.** The find/grep bug survived because the old cases checked `Success _`, not a non-empty or exact result. Assert the value, and use a fixture tree whose depth makes the semantics observable.

## TLS / HTTP

- **`Tls_eio.client_of_flow` without `~host` or `~ip` checks the chain but not the certificate identity.** It accepts a valid certificate issued for any name. Every TLS entry point must pass one of the two; "the chain validated" is not enough.
- **`Domain_name.host` rejects IP literals** (`192.168.1.5`, `::1`). A wrapper that only tries `Domain_name` silently falls into the no-identity branch for every IP endpoint. Classify with `Ipaddr.of_string` first and pass `~ip`; fail closed if neither parser accepts the host.
- **Use `Par.Tls_client` for all TLS.** Provider HTTP, MCP HTTP and the built-in HTTP tools share it; do not re-implement host parsing at a new call site.
- **Current fail-open remains:** `Ca_certs.authenticator ()` failure falls back to `no_auth` in the provider/MCP/builtin TLS configs (tracked as `PAR-is4`). Do not add new call sites before that is changed to fail closed.
- **cohttp-eio 6.3.0 body-chunk trap:** `Reader_flow.send` copies from offset 0 on the second and later partial `single_read` in a chunk. Corruption needs a chunk more than twice the reader's free buffer; PAR's 4096-byte readers normally avoid it. The fix is in cohttp's unreleased `dev`; upgrade when 6.4 ships. A local spike with a 100 KB header and 64 KB chunk read every byte correctly.

## Event bus / sessions

- **The event-bus session is one mutable field per runtime, not per fiber.** Tag with the run's session, then restore the caller's; an unset prior session restores the explicit empty string.
- **`with_bus_session ~prepare`:** `prepare` receives the caller's session and returns the run's session plus the state to run with. This keeps capture and minting in one place; passing a caller-captured `previous_session` is how PAR-48p's ordering bug happened.
- **Validate the target before minting.** `invoke_generate` / `invoke_structured` must reject an unknown agent (or a tool-bearing generate target) before writing `rt.session_id`; otherwise the runtime points at a run that never happened.
- **Concurrent runs do not get per-run event attribution.** Two background `invoke_generate` calls share the bus session; once one finishes it restores the caller's session, so the other's events lose their tag. Use `on_tool_event` / `on_chunk` when attribution matters. Fiber-local tagging through `Invoke_context` is the long-term fix.

## Globs / built-in file tools

- **Never `Str.quote` a glob and then patch the wildcards.** `Str.quote` inserts a backslash before `*`, and replacing the `*` leaves the backslash behind, producing a regex that requires a literal backslash in the name. Translate character by character instead.
- **Glob semantics in PAR:** `*` → `[^/]*`, `?` → `[^/]`, `**` → `.*`, `**/` → `\\(.*/\\)?` (zero directories allowed). Match the whole string: `Str.string_match re s 0 && Str.match_end () = String.length s`.
- **`find` matches the path relative to its `path` argument; `grep` matches the filename.** `*.ml` is root-only for `find`; use `**/*.ml` for every depth.
- **`grep` display paths:** strip exactly `Filename.concat root ""` (which already includes the trailing separator). The old code added one more byte and dropped the first character of every path.

## Dependencies / release

- **CI installs latest dependencies; a long-lived local switch can lag.** Upgrade the switch to the CI-resolved versions and re-run the full suites; otherwise local green and CI green are proving different dependency sets.
- **Check dependency changelogs for PAR-specific call paths, not just version numbers.** The tls/x509/mirage-crypto batch was pure security value, sqlite3 5.4.2 fixed a GC-rooting bug in the exact SQLite usage PAR relies on, and cohttp 6.3.0 was mostly server-side and irrelevant while the unreleased `dev` fix targets PAR's streaming read.
- **`eio 1.6` exposes `Eio.Net.connect ?bind_to ?options` and `Eio_unix.File`; `Eio.Flow.shutdown` is unchanged.** These are the enablers for the v0.17 owned-socket transport (`PAR-9km`).
- **Pre-release PyPI verification:** `pip` may use a mirror that lags PyPI (this machine defaults to Aliyun). Install from `--index-url https://pypi.org/simple` in a fresh venv. Also, PyPI's `info.version` stays on the last stable when only a pre-release is uploaded; inspect `releases["<version>"]` instead.
- **Verify published assets, not workflow conclusions.** `gh release view TAG --json isPrerelease,assets` must show the tarball, `par.opam`, every wheel and checksums; then install the wheel from PyPI and print the version.

