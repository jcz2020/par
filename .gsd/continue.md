# Continue — Next Session

## Current state (2026-11-10)

- `v0.15.0-beta.20261104` is released and pushed.
- `v0.16` work is on `main`, unreleased: vision tool results, DB leases,
  approval/crash recovery merge; the HTTP cancellation spike is done and the
  transport rewrite is explicitly deferred to v0.17.
- OCaml: 1750 tests, 0 failures. Python: full suite green excluding the known
  order-sensitive `test_http_timeout.py` segfault (passes alone).

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

## Next directions

1. **`PAR-9km` implementation (v0.17)** — `lib/providers/http_transport.ml` on
   `Eio.Net` + `tls-eio`, `Connection: close` only; migrate provider non-stream
   → provider stream → MCP transport → fetch_url, keeping a cohttp-eio fallback
   until the last step.
2. **`PAR-188`** — apply the same bus-session restore to `invoke_generate` and
   `invoke_structured`.
3. **Release v0.16** — needs explicit user authorization for the version bump.
   Next release is MINOR: schema 2, new variant, new persistence fields, new
   optional `recover_invoke` parameters.
4. **`PAR-tgy`** — the `?sandbox` mechanism (design is in
   `docs/explanation/sandbox-model.md`).
5. Remaining P2 feature backlog (`bd ready`) is `out-of-par` per DECISIONS #6
   except MCP sampling routing (`PAR-wn7`) and the Python FFI gaps
   (`PAR-h4m`, `PAR-0ls`).

## Do not

- Do NOT bump the version (including refreshing the beta date) without explicit
  user instruction.
- Do NOT touch `spikes/sqlite_vec_win_spike/` (untracked, experimental).
- Do NOT read the `test_http_timeout.py` full-suite segfault as a regression:
  the file passes alone; it is the documented OCaml-domain/Python-thread issue.
