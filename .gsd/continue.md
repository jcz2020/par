# Continue — Next Session

## Current state

- v0.7.4 stable released and pushed (tag `v0.7.4`)
- 1387 tests passing, build clean, origin/main up to date
- All docs synced (README EN+ZH, STRATEGY.md changelog, agent.md structured output section EN+ZH)

## What was done this session

1. Fixed 38 audit issues from `docs/audit/v0.7.x-findings.md` (v0.7.3)
2. Fixed json_extract think-tag + fence ordering bug (v0.7.4)
3. Implemented `Engine.run_agent_structured` — two-phase ReAct loop + structured output
4. Updated all documentation (README, STRATEGY.md §8 changelog, SDK docs EN+ZH)

## Next directions (user to choose)

1. **Wire up `complete_structured_fn` for real providers** — OpenAI (`openai_provider.ml:449`) and Anthropic (`anthropic_provider.ml:342`) both have `complete_structured` implemented, but `par_capi.ml` L180/195/210/225 sets `complete_structured_fn = None` for all real providers. Wiring them to `Some` enables native structured output (OpenAI `response_format: json_schema`, Anthropic `output_config`) instead of the text-injection fallback.

2. **Windows native build** — `par_ffi.c:121` `caml_startup(caml_argv)` triggers MinGW pointer-type incompatibility. Windows CI removed from matrix. CHANGES.md v0.7.2 promised fix "in v0.7.3" — slipped. Needs MinGW-specific cast or `#ifdef _WIN32` guard.

3. **Python binding CI** — Python tests (`bindings/python/tests/`) not in CI matrix. Need GitHub Actions workflow to run `pytest` against the built `.so`.

4. **External vector stores** — Qdrant/Milvus adapter for `Vector_store` interface. Currently only sqlite-vec (vec0) supported.

5. **`.docx` support** — No maintained OCaml library exists for Word files. Options: shell out to `pandoc`, or use a Python sidecar via the existing FFI.

6. **Multimodal image tools** — Image input/output tools. `content_block` type already has `Image_block` variant but no tools consume it.

## Key files

- `docs/STRATEGY.md` §8 — changelog (all decisions with §11 R1-R5 analysis)
- `docs/audit/v0.7.x-findings.md` — marked "all resolved v0.7.3"
- `lib/core/engine.ml` — `run_agent_structured` at end of file (L1083+)
- `lib/core/engine.mli` — `run_agent_structured` signature at L119
- `lib/core/runtime.ml` — `invoke_structured` routing at L970 (tools → two-phase, no tools → lightweight)

## Open threads (noticed but not acted on)

- **Python binding 集成测试未做** — `run_agent_structured` 改变了 `invoke_structured` 的内部路由（有工具时走两阶段），但 Python 侧（`bindings/python/par-runtime/runtime.py:799` `invoke_structured`）没有新增集成测试验证两阶段路径。C ABI 层 `par_invoke_structured` 返回值签名不变，现有测试应该能过，但没有覆盖"agent 有工具 + invoke_structured"这个新组合。下次应加一个 Python 端测试：注册带工具的 agent → 调 `invoke_structured` → 验证工具被执行 + 返回结构化 JSON。

## Do not

- Do NOT bump version without explicit user instruction (project rule)
- Do NOT touch `spikes/sqlite_vec_win_spike/` (untracked, experimental)
- Do NOT remove the `per_call_registry_isolation spawn cwd` test failure — it's a known CI environment issue (cwd resolution differences), pre-existing
