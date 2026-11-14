# Continue — Next Session

## Current state (2026-11-14)

- `v0.16.1-beta.20261114` is released and pushed: GitHub pre-release with the
  source tarball + `par.opam`, both wheels, and checksums; the two wheels are
  on PyPI as `0.16.1b20261114`. Tag `v0.16.1-beta.20261114` points at
  `dff10e6`. Release, opam publish, PyPI publish, CI, CodeQL, Docs and Release
  acceptance all passed; a fresh venv install from PyPI reports
  `0.16.1-beta.20261114`. The stable line remains `v0.10.0`.
- Main now also carries the GitHub #33 fix: tool-call hooks now gate workflow
  `Agent_call` / `Tool_call`, `invoke_parallel`, `invoke_structured`, nested
  agent tools and the `resume_approval` re-dispatch. It is committed on main
  and awaiting the next patch release; nothing on main is designed for a minor
  bump.
- `v0.16.0-beta.20261114` (tag `9f2e786`) was the previous beta; `v0.16.1` is a
  same-day patch for the GitHub #32 follow-up.
- Main now carries the v0.16 work plus the post-review TLS / find-grep /
  bus-session fixes and the Chinese DECISIONS #17/#18 sync; nothing is waiting
  on the remote.
- OCaml: 1767 tests, 0 failures. Python: 209 passed / 20 skipped.
- Local switch upgraded on 2026-11-11: sqlite3 5.4.2 (GC-rooting fix), tls /
  tls-eio 2.1.5, x509 1.2.0, mirage-crypto* 2.4.1 (security/stability fixes),
  then eio 1.6, cohttp / cohttp-eio 6.3.0 and dune 3.24.2. OCaml stays at
  5.4.1. Re-verified after both batches: 1752 OCaml tests / 0 failures, then
  1764 after the review fixes, then 1767 after the grep follow-up; 209 Python
  passed / 20 skipped throughout.
- Lessons recorded on 2026-11-14: `.gsd/KNOWLEDGE.md` (TLS/HTTP, event bus,
  glob, dependency and PyPI traps), `docs/STRATEGY.md` §11.5, and
  `docs/rules/release.md` post-publish verification. Decisions #17 (TLS entry
  point) and #18 (bus-session contract) added to `docs/DECISIONS.md`.

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
    `invoke_parallel`, `invoke_structured`, nested agent tools and the
    `resume_approval` re-dispatch now run the runtime chain. Five cases in
    `test_hook_coverage.ml`, one in `test_engine_hitl.ml`, all mutation-checked.

## Next directions

1. **`PAR-57u` (P1, security, next patch)** — the GitHub #33 hook-coverage fix
   is on main and should ship before anything else: an approval gate that is
   skipped on workflow / parallel / structured / agent-tool / resume paths is a
   security hole in a published version.
2. **`PAR-is4` (P1, next patch)** — `Ca_certs.authenticator ()` failure still
   falls back to `no_auth` in provider/MCP/builtin TLS configs. Change it to
   fail closed, then verify the three wrappers still construct `Tls.Config`.
3. **`PAR-9km` implementation (v0.17)** — `lib/providers/http_transport.ml` on
   `Eio.Net` + `tls-eio`, `Connection: close` only; migrate provider non-stream
   → provider stream → MCP transport → fetch_url, keeping a cohttp-eio fallback
   until the last step.
4. **`PAR-tgy`** — the `?sandbox` mechanism (design is in
   `docs/explanation/sandbox-model.md`).
4. Remaining P2 feature backlog (`bd ready`) is `out-of-par` per DECISIONS #6
   except MCP sampling routing (`PAR-wn7`) and the Python FFI gaps
   (`PAR-h4m`, `PAR-0ls`).
5. Watch cohttp 6.4 — its unreleased `dev` fixes cohttp-eio body chunks that are
   replayed from offset 0 when a chunk needs three or more partial
   `single_read`s. A local spike (100 KB header, 64 KB chunk, 4096-byte reader)
   read every byte correctly on 6.3.0: cohttp never delivered a chunk larger
   than twice the reader's request in the normal `Buf_read` path. No workaround
   is needed; upgrade when 6.4 ships.
6. OCaml 5.5.2 stays a separate trial-switch project; the pinned
   `ppx_deriving_jsonschema 0.0.1` is the compatibility risk.
   `Eio.Net.connect ?options` (new in 1.6) is available for `PAR-9km`.

## Do not

- Do NOT bump the version (including refreshing the beta date) without explicit
  user instruction.
- Do NOT add a TLS call site that bypasses `Par.Tls_client`, and do not copy the
  existing `Ca_certs` failure fallback: it is fail-open (`PAR-is4`).
- Do NOT touch `spikes/sqlite_vec_win_spike/` (untracked, experimental).
- Do NOT read the `test_http_timeout.py` full-suite segfault as a regression:
  the file passes alone; it is the documented OCaml-domain/Python-thread issue.
