# Continue — Next Session

## Current state (2026-11-04)

- `v0.15.0-beta.20261104` is released and pushed (tag `v0.15.0-beta.20261104`).
- Unreleased on `main`: the five v0.15 review follow-ups are closed.
- OCaml: 1741 tests, 0 failures. Python: full-suite run is order-sensitive
  (`test_http_timeout.py` segfaults in a combined run — the known domain
  registration issue); every file passes when run on its own.
- Invoke checkpoints are now `schema_version = 2`.

## What shipped after the release

1. `PAR-pcb` — newer-schema checkpoint rows are preserved at startup instead of
   deleted; `recover_invoke` reports the schema version even when the payload
   cannot be decoded.
2. `PAR-ikt` — Python `invoke(durable=True, save=..., update_current=...)` and
   `recover_invoke(..., save=..., update_current=...)` forward the flags through
   `par_invoke_durable_ext` / `par_recover_invoke_ext`; docs state the remaining
   OCaml-only parameters.
3. `PAR-37b` — checkpoint schema 2 records workspace roots + policy, the system
   prompt appendix and the skill snapshot. Recovery replays them; a missing
   workspace root fails closed. Decision #12 in `docs/DECISIONS.md`.
4. `PAR-0o5` — `invoke_generate` honors `update_current:false` and reports the
   session it actually used.
5. `PAR-48p` — the invoke event-bus restore captures the prior session before
   context creation mints one, and restores the empty state when there was none.

## Next directions

1. **`PAR-188`** — apply the same bus-session restore to `invoke_generate` and
   `invoke_structured` (same class as `PAR-48p`, deliberately not bundled).
2. **`PAR-tgy`** — the `?sandbox` mechanism itself (bwrap/landlock/seatbelt/job
   object). The design and the five honest limits are in
   `docs/explanation/sandbox-model.md`; the remaining work is the platform
   implementation, not another design pass.
3. P2 feature backlog (`bd ready`): URL fetch/JS rendering, web-search
   aggregation, workflow-management tools, prompt optimization, code
   interpreter, memory strategies, MCP sampling routing.

## Do not

- Do NOT bump the version (including refreshing the beta date) without explicit
  user instruction. The next release is MINOR: schema 2, new C entry points and
  new optional `recover_invoke` parameters.
- Do NOT touch `spikes/sqlite_vec_win_spike/` (untracked, experimental).
- Do NOT read the `test_http_timeout.py` full-suite segfault as a regression:
  the file passes alone, and the failure is the documented OCaml-domain /
  Python-thread issue.
