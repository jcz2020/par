# Continue — Next Session

## Current state (2026-11-10)

- `v0.15.0-beta.20261104` is released and pushed.
- `v0.16` work is on `main`, unreleased: vision tool results, DB leases,
  approval/crash recovery merge; the HTTP cancellation spike is done and the
  transport rewrite is explicitly deferred to v0.17.
- OCaml: 1752 tests, 0 failures. Python: full suite green excluding the known
  order-sensitive `test_http_timeout.py` segfault (passes alone).
- Local switch upgraded on 2026-11-11: sqlite3 5.4.2 (GC-rooting fix), tls /
  tls-eio 2.1.5, x509 1.2.0, mirage-crypto* 2.4.1 (security/stability fixes),
  then eio 1.6, cohttp / cohttp-eio 6.3.0 and dune 3.24.2. OCaml stays at
  5.4.1. Re-verified after both batches: 1752 OCaml tests / 0 failures,
  209 Python passed / 20 skipped.

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

## Next directions

1. **`PAR-9km` implementation (v0.17)** — `lib/providers/http_transport.ml` on
   `Eio.Net` + `tls-eio`, `Connection: close` only; migrate provider non-stream
   → provider stream → MCP transport → fetch_url, keeping a cohttp-eio fallback
   until the last step.
2. **Release v0.16** — needs explicit user authorization for the version bump.
   Next release is MINOR: schema 2, new variant, new persistence fields, new
   optional `recover_invoke` parameters.
3. **`PAR-tgy`** — the `?sandbox` mechanism (design is in
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
- Do NOT touch `spikes/sqlite_vec_win_spike/` (untracked, experimental).
- Do NOT read the `test_http_timeout.py` full-suite segfault as a regression:
  the file passes alone; it is the documented OCaml-domain/Python-thread issue.
