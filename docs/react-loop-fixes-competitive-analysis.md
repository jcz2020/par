# ReAct Loop Retry/Timeout: Competitive Analysis + Optimized Fix Plan

> **TL;DR（中文摘要）**: 调研了 LangChain、OpenAI Agents SDK、CrewAI、AutoGen 四个竞品在 ReAct 循环重试/超时方面的设计。核心发现：(1) 所有竞品都让重试消耗迭代预算，PAR 是唯一例外；(2) LangChain 有壁钟超时兜底，PAR 没有；(3) 没有竞品用 Timeout middleware 无限重试。基于竞品调研，将原方案从 6 个修复优化为 7 个（新增优雅降级和结构化错误分类），并调整了优先级。

> **Date**: 2026-06-23
> **Status**: Research complete, awaiting implementation approval
> **Scope**: v0.5.2 engine hardening (Fix 1–4, 6) + v0.6 architecture (Fix 5, 7)
> **Predecessor plan**: Initial 6-fix proposal presented in-conversation before competitive research

---

## 1. Bugs Being Addressed

All confirmed by direct source code reading (line numbers verified):

| # | Location | Bug | Impact |
|---|---|---|---|
| 1 | `engine.ml:428` | Retries don't consume `iterations` — `loop ~agent ~global_max conv iterations` passes unchanged | max_iter=1 can make 4+ LLM calls via Retry middleware |
| 2 | `timeout.ml:8-16` | Timeout middleware `on_error` returns `retryable=true` with no counter | Potential infinite retry loop on persistent timeout |
| 3 | `engine.ml:156` | `stream_config.total_timeout = None` | No wall-clock cap on streaming; 56.8s invokes observed |
| 4 | `retry.ml:84-86` | `on_before_llm` resets `attempt := 0` every iteration | N iterations × 3 retries = up to 3N+1 LLM calls |
| 5 | `json_extract.ml` (entire file) | No `<think>`/`<reasoning>` tag stripping | Reasoning models (DeepSeek-R1, QwQ) trigger spurious repair loops |

---

## 2. Competitive Landscape

### 2.1 Framework Comparison

Sources verified via GitHub source code (links in §2.2).

| Dimension | LangChain | OpenAI Agents SDK | CrewAI | AutoGen (v0.4) | **PAR (current)** |
|---|---|---|---|---|---|
| **Default iteration cap** | `max_iterations=15` | `max_turns=10` (DEFAULT_MAX_TURNS) | `max_iter=25` | `max_tool_iterations=1` (tool loop), test implies internal `max_iterations=10` | `max_iterations=10` |
| **Wall-clock timeout** | `max_execution_time: float \| None` checked in `_should_continue()` | None built-in | None built-in | None at agent level | **None** |
| **Retry consumes iteration?** | Yes — `handle_parsing_errors=True` sends error back as observation, counts as a step | N/A — `ModelBehaviorError` raised immediately, no retry at agent level | Yes — `handle_output_parser_exception` feeds back, `iterations` increments | Tool loop respects `max_tool_iterations`; parse errors surface as termination | **No** — retries are free |
| **Retry budget scope** | Per-invocation total (tenacity at HTTP layer, not agent loop) | Per-invocation total (HTTP layer) | Per-invocation total | Per-invocation | **Per-iteration** (resets each loop) |
| **Parse error handling** | `handle_parsing_errors` param: `False` (raise) / `True` (feedback + retry) / `str` / `Callable` | `ModelBehaviorError` exception — no silent retry | `handle_output_parser_exception()` — feedback message, iteration consumed | Errors terminate the run | Separate `run_structured` loop (3 repair attempts, independent counter) |
| **At-limit behavior** | `early_stopping_method`: `"force"` (stop) or `"generate"` (one final LLM call for best-effort answer) | `MaxTurnsExceeded` exception raised | `handle_max_iterations_exceeded()` — forces final answer generation | Run terminates with partial result | Returns `Error (Internal "Max iterations exceeded")` |
| **Timeout middleware pattern** | None — timeouts at HTTP/config level only | `ToolTimeoutError` per-tool, no agent-level retry-on-timeout | None | None | **Yes** — unconditional `retryable=true`, no counter |
| **Error classification** | `OutputParserException` vs others | `ModelBehaviorError` vs `UserError` vs `AgentsException` | `handle_output_parser_exception` / `handle_context_length` / `handle_unknown_error` — three distinct paths | No fine-grained classification | Single `retryable: bool` flag |

### 2.2 Source References

| Claim | Source |
|---|---|
| LangChain `max_iterations=15` | [langchain_classic/agents/agent.py L1018-1023](https://github.com/langchain-ai/langchain/blob/master/libs/langchain/langchain_classic/agents/agent.py#L1018) |
| LangChain `max_execution_time` | Same file, L1024-1026 |
| LangChain `_should_continue(iterations, time_elapsed)` | Same file, L1231-1235 |
| LangChain `handle_parsing_errors` | Same file, L1037-1044 |
| LangChain `early_stopping_method` | Same file, L1027-1036 |
| OpenAI SDK `DEFAULT_MAX_TURNS` | [src/agents/run.py L29](https://github.com/openai/openai-agents-python/blob/main/src/agents/run.py#L29) |
| OpenAI SDK `MaxTurnsExceeded` | [src/agents/exceptions.py](https://github.com/openai/openai-agents-python/blob/main/src/agents/exceptions.py) |
| OpenAI SDK `ModelBehaviorError` | Same file |
| CrewAI `max_iter=25` | [lib/crewai/src/crewai/experimental/agent_executor.py L182](https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/experimental/agent_executor.py#L182) |
| CrewAI `has_reached_max_iterations` | [lib/crewai/src/crewai/utilities/agent_utils.py](https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/utilities/agent_utils.py) |
| CrewAI `handle_max_iterations_exceeded` | Same file |
| CrewAI `handle_output_parser_exception` | [lib/crewai/src/crewai/agents/crew_agent_executor.py L430](https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/agents/crew_agent_executor.py#L430) |
| AutoGen `max_tool_iterations=1` | [python/packages/autogen-agentchat/src/autogen_agentchat/agents/_assistant_agent.py L85](https://github.com/microsoft/autogen/blob/main/python/packages/autogen-agentchat/src/autogen_agentchat/agents/_assistant_agent.py#L85) |
| AutoGen tool loop `max_iterations=10` (test) | [test_assistant_agent.py L631](https://github.com/microsoft/autogen/blob/main/python/packages/autogen-agentchat/tests/test_assistant_agent.py#L631) |

### 2.3 Frameworks Not Included (and why)

| Framework | Reason for exclusion |
|---|---|
| LlamaIndex Agents | Less direct comparability — query-focused, not general ReAct loop |
| ReAct paper (Yao et al. 2022) | Theoretical foundation, no implementation-level retry/timeout design |
| Semantic Kernel | Enterprise-focused, different architecture (planner-based, not ReAct) |
| HuggingFace smolagents | Lightweight wrapper around transformers; uses HF Inference API retry, no agent-loop-level retry design to compare |
| PydanticAI | Type-safe agent framework; relies on HTTP-layer retry (httpx), no agent-loop retry/timeout design at framework level |

---

## 3. Core Findings from Competitive Research

### Finding 1: Retries MUST consume iterations — industry consensus

LangChain and CrewAI both count parse error retries as iterations. OpenAI SDK is stricter — model behavior errors raise immediately with no retry. AutoGen terminates the run on error.

**PAR is the only framework where retries are "free" (don't consume iteration budget).** This is the root cause of Bugs #1 and #4.

### Finding 2: Dual limits (iterations + wall clock) is standard

LangChain's `_should_continue(iterations, time_elapsed)` checks BOTH limits every loop iteration. Even if retry logic is buggy, the wall-clock timeout catches it.

**PAR has zero wall-clock protection at the engine level.** This is why 56.8s invokes happen.

### Finding 3: Graceful degradation is better than hard error

LangChain's `early_stopping_method="generate"` and CrewAI's `handle_max_iterations_exceeded()` both make a final LLM call to produce a "best effort" answer when the limit is hit. PAR returns a bare error.

### Finding 4: Timeout middleware that retries is a PAR-specific anti-pattern

No competitor has a "timeout middleware" that returns `retryable=true`. Timeouts are terminal everywhere else. PAR's `timeout.ml:8-16` is causally responsible for Bug #2: it unconditionally marks `Timeout` errors as retryable, creating a potential infinite loop when combined with the Retry middleware. The argument for removing it rests on this causal chain, not merely on competitive absence.

### Finding 5: Structured error classification > single retryable flag

CrewAI's three-way split (`handle_output_parser_exception` / `handle_context_length` / `handle_unknown_error`) provides finer control than PAR's single `retryable: bool`. OpenAI SDK's exception hierarchy (`ModelBehaviorError` vs `UserError`) achieves similar granularity.

### Finding 6: Where PAR already leads

For balanced analysis, PAR has design advantages in areas competitors lack:

| PAR strength | Competitor gap |
|---|---|
| Compile-time type safety (OCaml ADTs for tool calls, error categories) | LangChain/CrewAI use runtime dicts; OpenAI SDK uses Python type hints (runtime-checkable only) |
| Structured concurrency (Eio — no orphan fibers, no callback hell) | All Python competitors use asyncio callbacks or threading |
| Type-safe bash tool (`Bash_safe_command` ADT — shell injection unrepresentable) | All competitors use raw string exec |
| Middleware pipeline as first-class architecture | LangChain has callbacks (observability only); others have no middleware |

---

## 4. Optimized Fix Plan

### Relationship to prior plan

The initial in-conversation proposal had 6 fixes without competitive grounding. This plan (v2) incorporates competitive insights, adds source citations, and adjusts priorities. Changes from v1:

| Fix | v1 approach | v2 change | Rationale |
|---|---|---|---|
| Fix 1 (timeout) | Separate `max_retries_per_iter` parameter | Replaced with wall-clock `max_execution_time` | LangChain precedent; simpler; catches ALL timeout paths |
| Fix 2 (retry iterations) | Same: `iterations + 1` | Unchanged | Confirmed by all competitors |
| Fix 3 (timeout mw) | Delete `on_error` | Same, now with causal argument | Bug #2 causal chain identified |
| Fix 4 (retry reset) | Delete `on_before_llm` reset | Same | All competitors use per-invocation budget |
| Fix 5 (degradation) | Not in v1 | NEW: early_stopping_method | LangChain + CrewAI precedent |
| Fix 6 (<think>) | Same | Note: internal improvement, not competitive-driven | |
| Fix 7 (classification) | Not in v1 | NEW: structured error handlers | CrewAI precedent |

### Fix Details

#### Fix 1: Wall-clock execution timeout [P0, Quick (~30 min)]

**Inspiration**: LangChain `max_execution_time` ([source](https://github.com/langchain-ai/langchain/blob/master/libs/langchain/langchain_classic/agents/agent.py#L1024))

**Before**: No wall-clock limit. 56.8s invokes with max_iter=1.
**After**: `agent_config.max_execution_time : float option` (default None = unlimited). Loop checks elapsed time at top of each iteration.
**Reason**: Even if retry logic has bugs, wall-clock timeout is a reliable safety net.
**Impact**: `lib/core/engine.ml` (loop function), `lib/core/types.ml` (agent_config), FFI parsing in `lib/ffi/par_capi.ml`.
**Rollback**: Set field to None.

```ocaml
(* engine.ml — add to loop entry *)
let start_time = Unix.gettimeofday () in
let rec loop ~agent ~global_max conv iterations =
  let elapsed = Unix.gettimeofday () -. start_time in
  let max_time = Option.value agent.max_execution_time ~default:infinity in
  if iterations >= global_max then
    Result.Error (Internal "Max iterations exceeded", conv)
  else if elapsed > max_time then
    Result.Error (Timeout, conv)
  else begin ... end
```

#### Fix 2: Retries consume iterations [P0, Trivial (~5 min)]

**Inspiration**: LangChain `handle_parsing_errors=True` (parse error consumes iteration); CrewAI `handle_output_parser_exception` (same); OpenAI SDK (errors raise immediately, no free retry).

**Before**: `engine.ml:428` — `loop ~agent ~global_max conv iterations` (iterations unchanged on retry).
**After**: `loop ~agent ~global_max conv (iterations + 1)`.
**Reason**: Industry consensus. max_iter=N means at most N LLM calls total including retries.
**Impact**: One line change in `lib/core/engine.ml:428`.
**Rollback**: Revert to `iterations`.

#### Fix 3: Delete Timeout middleware `on_error` [P0, Trivial (~5 min)]

**Causal argument** (not just competitive absence): `timeout.ml:8-16` returns `Error {retryable=true}` for every `Timeout` error with no counter. The Retry middleware's `retry_on` list already includes `Timeout`. When both middleware are present, Timeout mw marks it retryable → Retry mw retries → Timeout mw marks it retryable again → infinite loop. This is the direct cause of Bug #2.

**Before**: `timeout.ml` has `on_error = Some (...)` that unconditionally marks Timeout as retryable.
**After**: `on_error = None`. Retry middleware handles timeout retries (it already has `Timeout` in `retry_on` with `max_attempts=3`).
**Reason**: Eliminates the infinite-retry causal chain. Aligns with all competitors (none retry-on-timeout at middleware level).
**Impact**: `lib/middleware/timeout.ml` — set `on_error = None`.
**Rollback**: Restore the `on_error` function.

#### Fix 4: Retry middleware doesn't reset per iteration [P1, Trivial (~5 min)]

**Inspiration**: All competitors treat retry budget as per-invocation total, not per-iteration.

**Before**: `retry.ml:84-86` — `on_before_llm` sets `attempt := 0` every iteration.
**After**: Remove `on_before_llm` reset (set to `None`).
**Reason**: 3 retries should be the total for the entire invoke, not refreshed every iteration. With v1 behavior, N iterations = N×3 retries.
**Impact**: `lib/middleware/retry.ml:84-86` — delete the `on_before_llm` assignment.
**Rollback**: Restore the reset.

#### Fix 5: Graceful degradation at iteration limit [P2, Medium (~2-3 hours)]

**Inspiration**: LangChain `early_stopping_method="generate"` ([source](https://github.com/langchain-ai/langchain/blob/master/libs/langchain/langchain_classic/agents/agent.py#L1027)); CrewAI `handle_max_iterations_exceeded()` ([source](https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/utilities/agent_utils.py)).

**Before**: `engine.ml:401-402` returns `Error (Internal "Max iterations exceeded")`.
**After**: Optionally make one final LLM call with "Based on your work so far, provide your best answer" to generate a best-effort response. Configurable via `agent_config.early_stopping_method`.
**Reason**: Better UX — user gets a partial answer instead of a bare error.
**Impact**: `lib/core/engine.ml`, `lib/core/types.ml`.
**Rollback**: Set `early_stopping_method = \`Force`.

#### Fix 6: `<think>` tag stripping [P2, Quick (~20 min)]

**Note**: This is an internal robustness improvement, not driven by competitive research. No competitor specifically handles `<think>` tags — it's a gap in all frameworks for reasoning-model support.

**Before**: `json_extract.ml` has no `<think>`/`<reasoning>` stripping. `find_balanced_block` may grab JSON-like content inside reasoning blocks.
**After**: Add `strip_think_tags` function before `strip_markdown_fences` in the preprocessing chain.
**Reason**: Models like DeepSeek-R1, QwQ, MiniMax-M3 emit `<think>...</think>` before JSON output, causing parse failures and spurious repair loops.
**Impact**: `lib/core/json_extract.ml`.
**Rollback**: Remove the function call.

#### Fix 7: Structured error classification [P3, Large (~4-6 hours)]

**Inspiration**: CrewAI three-way error handling ([source](https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/agents/crew_agent_executor.py#L430)).

**Before**: Single `retryable: bool` in error handler.
**After**: Three error classes: parse_error (feedback + retry), context_length_exceeded (compress + retry), model_behavior_error (raise immediately).
**Reason**: Finer control prevents inappropriate retries and enables targeted recovery.
**Impact**: `lib/core/engine.ml`, `lib/core/types.ml`.
**Rollback**: Revert to single retryable flag.

### Effort Estimates

| Fix | Complexity | Estimated time | Dependencies |
|---|---|---|---|
| Fix 1 | Low | ~30 min | None |
| Fix 2 | Trivial | ~5 min | None |
| Fix 3 | Trivial | ~5 min | None (but test with Fix 4) |
| Fix 4 | Trivial | ~5 min | None |
| Fix 5 | Medium | ~2-3 hours | Fix 1, 2 (needs final loop behavior stable) |
| Fix 6 | Low | ~20 min | None |
| Fix 7 | Large | ~4-6 hours | Fix 1-4 (needs stable error flow first) |
| **Total v0.5.2** (1-4+6) | | **~1 hour** | |
| **Total v0.6** (5+7) | | **~6-9 hours** | |

---

## 5. v0.5.2 Scope Impact

Current v0.5.1-ROADMAP.md positions v0.5.2 as "ARM64 Linux wheel, dual-tier persistence improvements, external vector stores (Qdrant/Milvus)."

**Proposed addition**: Engine hardening (Fix 1-4+6) in v0.5.2.

**Justification**: These are correctness bugs, not features. They affect every invoke call. The fixes are low-risk (total ~1 hour implementation, mostly 1-line changes) and well-validated by competitive analysis. Shipping them in v0.5.2 alongside the planned infrastructure work is feasible.

**ROADMAP update required**: Add a "Phase D: Engine Hardening" section to v0.5.2 roadmap when it's created, referencing this document.

---

## 6. Test Plan

### Objective
Verify that retry/timeout behavior matches competitive norms after fixes.

### Test Cases

| # | Test | Input | Expected | Verification |
|---|---|---|---|---|
| 1 | Retry consumes iteration | max_iter=2, LLM always errors | Exactly 2 LLM calls, then error | Count LLM calls in test |
| 2 | Wall-clock timeout | max_execution_time=1.0, hanging server | Timeout error after ~1s | Wall clock measurement |
| 3 | No infinite timeout retry | Timeout mw + Retry mw, persistent timeout | Bounded by Retry max_attempts=3 | Count retries |
| 4 | Retry budget per-invocation | max_iter=5, LLM errors on iter 1 and 3 | Total retries ≤ 3 across all iterations | Count retries |
| 5 | `<think>` tag handling | JSON response wrapped in `<think>...</think>{...}` | Parsed correctly, no repair | Parse result check |

### Success Criteria
- All 5 test cases pass
- Existing 998 OCaml + 61 Python tests still pass (0 regressions). Note: README shows 57 Python tests but this is outdated — 4 new timeout/embed tests were added in v0.5.1-beta session, bringing total to 61.
