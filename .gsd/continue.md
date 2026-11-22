# Continue — Next Session

## Current state (2026-11-22)

- `v0.18.0-beta.20261122` is released: tag `a1a66c4`, GitHub pre-release with
  the source tarball + `par.opam` and both wheels, opam publish succeeded,
  PyPI has `0.18.0b20261122` (verified in a fresh venv: version, AsyncRuntime
  and MCPSampling import). GitHub #44 closed.
- Main is at `d2704d2` with post-release CI fixes (`pytest-asyncio`, the test
  wiring false positive from `bench_tracing`, rc=5 for all-skipped files, and
  the gated native stream-cancel race). Main CI is green. The release tag's CI
  was red because those CI-only fixes landed after the tag; release assets and
  publishes were unaffected.
- v0.18 scope is complete: W1 typed Python API/AsyncRuntime/mypy +
  `list_models`/`load_most_recent_conversation`; W2 tracing/W3C/OTel;
  W3 MCP sampling with events and per-invoke budget; W4 owned-socket HTTP for
  provider/MCP/webhooks/web builtins (cohttp-eio removed); PAR-is4 TLS fails
  closed; GitHub #44 tool-result cap and grep bounds.
- OCaml: 1843 tests, 0 failures. Python: 252 passed / 22 skipped (per-file).
  `mypy --strict` clean; docs-check and mkdocs --strict green;
  release-local-test passed debian:12 / ubuntu:22.04 / ubuntu:24.04.
- bd: `PAR-ga4q` epic and W1/W2/W3/W4 issues closed. Remaining P3:
  `PAR-e68` (blocking_approval), `PAR-0ls` (memory FFI), `PAR-tgy` (sandbox).

## What shipped after v0.15

1. `PAR-pcb` — newer-schema checkpoint rows are preserved at startup instead of
   deleted; recovery reports the schema version even when the payload cannot be
   decoded.
2. `PAR-ikt` — Python `invoke(durable=True, save=..., update_current=...)` and
   `recover_invoke(..., save=..., update_current=...)` forward the flags.
3. `PAR-37b` — checkpoint schema 2 records workspace roots + policy, the system
   prompt appendix and the skill snapshot; recovery replays them and fails
   closed on a missing workspace root.
4. `PAR-0o5` — `invoke_generate` honors `update_current:false` and reports the
   session it actually used.
5. `PAR-48p` — the invoke event-bus restore captures the prior session before
   context creation mints one.
6. **v0.16 vision closure** — `handler_result.Success_content`; a tool can hand
   the model text and images; Anthropic's `tool_result` uses the array form;
   the Python envelope (`tool_content`) shares one wire shape.
7. **`PAR-53d` DB lease** — `invoke_leases` with a CAS claim; a live holder
   keeps the run, a dead process releases it (pid probe first, expiry as the
   fallback).
8. **`PAR-1g9` approval/recovery merge** — a suspended run keeps its checkpoint
   with `pending_approval`; recovery refuses it while the decision is open and
   points at `resume_approval`; applying the decision clears it.
9. **`PAR-9km` spike** — `Eio.Flow.shutdown` on an owned socket interrupts a
   blocked read in 0.20s. See `docs/plans/v0.16-http-cancellation-spike.md`.
10. `PAR-188` — `invoke_generate` and `invoke_structured` restore the event-bus
    session through the shared `with_bus_session`; one regression test per
    entry point (`test_invoke_session_restore.ml`).
11. **`PAR-cxp` TLS identity** — `Tls_client` is the single TLS entry point for
    providers, MCP HTTP and built-in HTTP tools. IP literals now use
    `Tls_eio.client_of_flow ~ip` (tls-eio >= 2.1.5); a host that is neither a
    domain nor an IP fails closed instead of connecting without identity
    validation. `ipaddr` is a direct dependency now.
12. **`PAR-p2x` (GitHub #32) find/grep** — globs are translated char-by-char
    (`*` within a component, `**` across, `**/` matches zero directories,
    `?`); `find` matches the path relative to `path`; `grep` treats an omitted
    or empty glob as `*`; grep's `path:line:text` output no longer drops the
    first character of the relative path.
13. **`PAR-f5h` bus-session review follow-ups** — `with_bus_session` now takes
    a `prepare` callback so capture and minting cannot be ordered wrongly;
    generate/structured validate the agent before minting a session;
    error/exception paths covered by tests; concurrent-run event attribution
    limitation documented in `docs/sdk/generate.md` (EN+ZH).
14. **`PAR-mye` (GitHub #32 follow-up, v0.16.1)** — `grep` searches the whole
    line with `Str.search_forward` instead of anchoring at offset 0; a glob
    with `/` matches the path relative to `path` (`sub/*.ml`, `**/*.ml`), while
    a glob without `/` keeps filtering by file name at any depth. Three exact
    result-set tests; the mid-line and `sub/*.ml` cases were mutation-checked.
15. **Chinese DECISIONS sync** — `docs/zh/DECISIONS.md` gained #17 (TLS single
    entry point) and #18 (bus-session prepare contract); the translation sync
    check is back to 100%.
16. **`PAR-57u` (GitHub #33) hook coverage** — `Workflow_engine.exec_context`
    carries `tool_call_hooks`; workflow `Agent_call` / `Tool_call`,
    `invoke_parallel`, `invoke_structured`, nested agent tools (including under
    a workflow or parallel run) and the `resume_approval` re-dispatch now run
    the runtime chain. Eight cases in `test_hook_coverage.ml`, one in
    `test_engine_hitl.ml`, all mutation-checked.
17. **GitHub #35 MCP/skill reload** — `Runtime.reload_mcp_servers` reconciles
    the managed set by name (transactional additions, unchanged instances
    kept, descriptors returned); `Runtime.replace_skill` /
    `unregister_skill` apply a rewritten skill definition. Python parity for
    all three. Eight `test_mcp_reload.ml` cases, plus registry/runtime skill
    tests and seven Python cases. Shipped in **v0.17.0-beta.20261117**.
18. **v0.16.3 HTTP transport hotfix (GitHub #36/#37)** — the raw-socket
    `Http_timeout` path sent malformed requests (headers after the terminating
    CRLF, no `Content-Length`, body dropped), rejected TLS and never parsed
    SSE. MCP HTTP and `fetch_url` / `read_webpage` / `web_search` are back on
    cohttp-eio; `test_http_transport_e2e.ml` covers MCP JSON, MCP SSE and
    fetch_url headers/body. Shipped in **v0.16.3-beta.20261115**;
    `Http_timeout` remains only as v0.17+ scaffolding for `PAR-9km`.
19. **GitHub #38/#39 MCP conformance (v0.17.1-beta.20261117)** — every
    JSON-RPC writer now emits `"jsonrpc":"2.0"` and every parser rejects a
    missing/other version, fixing HTTP MCP against strict servers (stdio had
    hidden it). `Runtime.mcp_tool_bindings` exposes descriptor+handler pairs so
    a host can merge a reloaded tool into an already-registered agent;
    `update_agent_tools` now has what `reload_mcp_servers` docs always assumed.
    Seven wire-format cases, a strict-400 HTTP fixture and one reload-merge
    test. Shipped as a PATCH (finishing the v0.17.0 reload surface) in
    **v0.17.1-beta.20261117**.
20. **GitHub #40/#41 + Python config integers (v0.17.2-beta.20261118)** —
    integer `timeout` is accepted at both bash handler sites (JSON has one
    number type), and the three substitution blacklist rules apply only when
    argv invokes a shell with `-c`, so literal `$(...)`/backticks under direct
    exec pass. The same `to_float_option` misuse in the C bridge was fixed with
    one helper across seven float config fields; `temperature=1` now registers.
    Nine new OCaml cases and five Python cases. Shipped in
    **v0.17.2-beta.20261118**.
21. **GitHub #42 model discovery (v0.17.3-beta.20261118)** —
    `Openai_provider.list_models` (GET `/models`, also Ollama/Custom) and
    `Anthropic_provider.list_models` (GET `/v1/models?limit=1000`) plus
    `to_llm_service` constructors that include `list_models_fn`; the C bridge
    uses them. `Http_client` now honors the request verb instead of hardcoding
    POST. Eight new provider/runtime cases. Shipped in
    **v0.17.3-beta.20261118** after the macOS arm64 runner queue cleared (the
    publish workflow was re-run; Release acceptance then passed).

## 2026-11-22: GitHub #44 triage

- **Fixed (316e70f)**: bounded tool results. `max_tool_result_chars` (default
  100_000) caps the text a tool adds to the conversation; builtin `grep` skips
  binary-looking files, truncates lines >2,000 chars and stops after 1,000
  matches. bd `PAR-t60u` closed.
- **Cancellation fixed for providers (4f1d5c9)**: owned Eio.Net + tls-eio
  socket; cancellation hooks call `Eio.Flow.shutdown` and wake the blocked
  read. `test_http_cancel.ml` covers non-stream, stream, full `Runtime.invoke` and a
  stalled TLS handshake against a silent server (<2s). The streaming idle
  timeout reports Timeout rather than the socket-shutdown artefact. MCP HTTP and web builtins still use
  cohttp-eio (`PAR-p7lj`).

## Next directions

1. **v0.18.0 release prep** — W1/W2/W3/W4 are on main; PAR-9km and PAR-p7lj
   are closed. Before tagging: benchmark the Noop tracer (`PAR-8a41`), run the
   full gates (`make test-count`, Python matrix, `mkdocs build --strict`), then
   ask the user for the version bump (beta-first). Decide whether `PAR-is4`
   ships as a v0.17.4 patch or with v0.18.
2. **`PAR-is4` (P1) — fixed 2026-11-19.** The three TLS configs
   (provider/MCP/builtin) now share `Par.Tls_client.config`; a failed
   `Ca_certs.authenticator ()` raises instead of falling back to `no_auth`.
   `test_tls_client.ml` pins both branches. Not released yet at the time of
   this note; the roadmap suggested a patch release.
3. **`PAR-tgy`** — the `?sandbox` mechanism (design is in
   `docs/explanation/sandbox-model.md`).
4. Remaining P2 feature backlog (`bd ready`) is `out-of-par` per DECISIONS #6
   except the Python FFI gaps (`PAR-h4m`, `PAR-0ls`).
5. Watch cohttp 6.4 — its unreleased `dev` fixes cohttp-eio body chunks that are
   replayed from offset 0 when a chunk needs three or more partial
   `single_read`s. A local spike (100 KB header, 64 KB chunk, 4096-byte reader)
   read every byte correctly on 6.3.0: cohttp never delivered a chunk larger
   than twice the reader's request in the normal `Buf_read` path. No workaround
   is needed; upgrade when 6.4 ships.
6. OCaml 5.5.2 stays a separate trial-switch project; the pinned
   `ppx_deriving_jsonschema 0.0.1` is the compatibility risk.
   `Eio.Net.connect ?options` (new in 1.6) is available for `PAR-9km`,
   which remains the only v0.18 parallel item.

## Do not

- Do NOT bump the version (including refreshing the beta date) without explicit
  user instruction.
- Do NOT add a TLS call site that bypasses `Par.Tls_client`. The CA trust store
  is loaded once there and fails closed; a local `Ca_certs` copy would
  reintroduce the `PAR-is4` fail-open class.
- Do NOT touch `spikes/sqlite_vec_win_spike/` (untracked, experimental).
- Do NOT read the `test_http_timeout.py` full-suite segfault as a regression:
  the file passes alone; it is the documented OCaml-domain/Python-thread issue.
