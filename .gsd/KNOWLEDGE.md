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
