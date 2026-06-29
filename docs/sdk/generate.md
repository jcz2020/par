<!-- language: en -->

**English** · [简体中文](../zh/sdk/generate.md)

# Generate API Reference

> Added in v0.6.x. Source-of-truth: the OCaml function `Runtime.invoke_generate` in `lib/core/runtime.ml`, `Generate.run` in `lib/core/generate.ml`, and the `generate_result` type in `lib/core/types.ml`.

This page is the API contract for PAR's pure long-output generation path. It locks the shape of `invoke_generate`, the `generate_result` return type, the auto-continuation behavior, and the events callers can observe. If you are writing a long-output agent (PRDs, HTML mockups, plans, documentation) and want to stop hand-rolling direct LLM calls, read the Usage Examples section. If you are wiring the FFI or porting an existing agent that currently bypasses `Runtime.invoke`, read the Auto-continuation behavior and Limitations sections first.

## Overview

Long-output generation is a different workload from ReAct reasoning. A PRD writer produces 3,000 to 6,000 tokens of Markdown in one go. An HTML mockup agent emits a single large artifact. None of that involves tool calls, and none of it benefits from an iteration budget. Treating `Max_tokens` truncation as a loop-consuming failure (the ReAct default) is wrong for this class of work. The truncation is a transport detail. The model finished what it could; the runtime's job is to deliver the complete output, not to penalize the model for hitting the limit.

Downstream integration feedback confirmed the gap: long-output agents in an integrator were bypassing `Runtime.invoke` and hand-calling `llm_chat_raw`, keeping PAR only for session and event management. Plan §1 of the long-output generation mode plan documents the survey of four mainstream coding agents (Claude Code, Codex CLI, OpenCode, a comparable coding agent): none of them count `Max_tokens` as an iteration-consuming event. PAR was the outlier. `Runtime.invoke_generate` closes that gap by exposing a first-class entrypoint for pure generation. It skips the ReAct loop entirely, auto-continues on `Max_tokens` truncation, and reuses the same session store, event bus, LLM-service abstraction, and skill overlay machinery that `invoke` uses.

The generate path is intentionally narrow. It does not run middleware at the ReAct boundaries, does not consult `max_iterations`, and does not consult `max_execution_time` per iteration (a single optional `total_timeout` replaces it). What it shares with `invoke` is everything that should be shared: provider abstraction, session persistence, event publishing, skill composition, and the streaming callback shape.

## When to use invoke_generate vs invoke

- Use `invoke_generate` when the task is producing a long text artifact and no tool calls are needed: PRDs, HTML mockups, plans, documentation, reports, code listings where the model writes the whole file in one shot. It auto-continues across `Max_tokens` truncation so the caller does not have to implement chunk-concatenation glue.
- Use `invoke` when the task needs tool calls, multi-step reasoning, or ReAct loop semantics: agents that search, compute, run bash, query a database, or hand off to other agents. `invoke` is also the right choice when middleware at LLM and tool boundaries matters, since `invoke_generate` skips that pipeline.

A rough rule: if the agent's `tools` list is empty and the output is long, reach for `invoke_generate`. If the agent has tools, reach for `invoke`. `invoke_generate` enforces the first half of that rule at registration time: an agent whose `tools` list is non-empty is rejected with `Invalid_input`.

## Type definitions

### generate_result

Returned by `Runtime.invoke_generate`. Distinct from `invoke_result` because the generate path does not run the ReAct loop, so the shape exposes continuation and token accounting instead of an iteration count.

```ocaml
type generate_result = {
  text          : string;              (* Full concatenated output across the
                                          initial response and all continuation
                                          chunks. Empty only on total failure. *)
  finish_reason : finish_reason;       (* Stop | Tool_calls | Max_tokens |
                                          Content_filter. Stop is the happy
                                          path. Max_tokens means the
                                          diminishing-returns guard halted
                                          continuation. Content_filter means
                                          the provider blocked the response. *)
  continuations : int;                 (* Number of Continue sub-loop chunks
                                          fired. Zero means the model emitted
                                          Stop on the first response. *)
  total_tokens  : int option;          (* Accumulated usage across continuations
                                          when the provider reports usage.
                                          None for providers that do not emit
                                          token counts (e.g. OpenAI streaming). *)
  session_id    : string;              (* Session the generation wrote to.
                                          Persist with the conversation if you
                                          want to resume later. *)
  elapsed       : float;               (* Wall-clock seconds from entry to
                                          return, including all continuations. *)
}
```

`finish_reason` reuses the existing ADT from `lib/core/types.ml`:

```ocaml
type finish_reason = Stop | Tool_calls | Max_tokens | Content_filter
```

## API signature

```ocaml
val Runtime.invoke_generate :
  runtime ->
  agent_id:string ->
  message:string ->
  ?max_output_tokens:int ->
  ?total_timeout:float ->
  ?on_tool_event:(Types.event -> unit) ->
  ?on_chunk:(Types.llm_response_chunk -> unit) ->
  unit ->
  (Types.generate_result, Types.error_category * Types.conversation) result
```

Parameters:

- `agent_id` resolves a registered agent. The agent MUST have `tools = []`. Tool-bearing agents are rejected with `Invalid_input`.
- `message` is the prompt or user message.
- `max_output_tokens` is an optional per-call cap on the initial response. Continuations accumulate beyond this until a Stop condition fires. When omitted, the agent's `model.max_tokens` (or the provider default) applies.
- `total_timeout` is an optional wall-clock cap on the entire generation, continuations included. When omitted, the generation runs unbounded (bounded only by the diminishing-returns guard and natural Stop).
- `on_tool_event` is an observation callback. It fires for `Llm_request_sent`, `Llm_response_received`, `Llm_response_truncated`, and `Generate_continuation`. No tool events fire because the generate path does not dispatch tools.
- `on_chunk` is an optional streaming callback. It fires for each `llm_response_chunk` the provider emits, mirroring the `?on_chunk` shape on `Runtime.invoke`. Use it for live UIs that want to render text as it lands.

The `Error` variant carries `(error_category, conversation)` so callers can persist the partial conversation even on failure, the same shape `Runtime.invoke` returns.

## Auto-continuation behavior

The Continue sub-loop is what makes `invoke_generate` suitable for long output. The runtime initiates a normal LLM call. If the provider returns `finish_reason = Max_tokens`, the runtime fires an `Llm_response_truncated` event for observability, then injects a continuation prompt asking the model to resume from where it stopped, and issues a follow-up LLM call. The new chunk's text is concatenated onto the accumulator. The loop continues until one of these conditions fires:

- The provider returns `finish_reason = Stop` (the model finished naturally).
- The provider returns `finish_reason = Content_filter` (the provider blocked the response).
- The diminishing-returns guard trips: a continuation chunk adds fewer than 500 characters, signaling the model is stuck restating itself rather than making progress.
- `?total_timeout` elapses. If at least one chunk has landed, the runtime returns the accumulated text as a partial result. If nothing has landed, it returns `Error (Timeout, conversation)`.

Each successful continuation emits a `Generate_continuation` event with the chunk index (0-based: the first continuation after the initial response is index 0) and the character count added. Callers can wire a progress UI off this event without inspecting the text.

This is the same `Continue` semantics the ReAct path uses (see `agent_config.on_max_tokens = Continue` in [Agent API](agent.md)), factored out into a dedicated loop. The difference is that on the ReAct path, `Continue` is per-agent opt-in and capped at `max_continuation_chunks` (default 3). On the generate path, continuation is the default and the cap is removed; the diminishing-returns guard is the budget. Plan §1 documents the four-agent survey that motivated this: none of Claude Code, Codex CLI, OpenCode, or a comparable coding agent counts `Max_tokens` as a loop-budget event, and PAR aligns with that invariant for the pure-generation case.

## Events emitted

The `?on_tool_event` callback can observe these variants:

- `Llm_request_sent of { task_id; model }` before every LLM round trip, including continuations.
- `Llm_response_received of { task_id; usage }` after every LLM round trip.
- `Llm_response_truncated of { task_id; model; finish_reason }` when the provider returns `Max_tokens`. `finish_reason` is always `Max_tokens` here.
- `Generate_continuation of { task_id; chunk_index; chars_added }` after each successful continuation chunk. `chunk_index` is 0-based for the continuation chunks; the initial response is not a continuation.

No `Tool_invoked`, `Tool_completed`, `Bash_invoked`, or handoff events fire on this path. The generate loop does not dispatch tools.

## Usage examples

### Example 1: Basic generation (OCaml)

Register a tool-less agent, then call `invoke_generate` to produce a long PRD. The runtime handles continuation transparently; the caller sees the full concatenated text.

```ocaml
open Par

let () = Eio_main.run (fun _env ->
  Eio.Switch.run (fun switch ->
    match Runtime.create ~config:<runtime_config> switch with
    | Error e -> prerr_endline (Types.string_of_error_category e)
    | Ok rt ->
      (* Tool-less agent: the only kind invoke_generate accepts. *)
      let agent = {
        Types.id = "prd-agent";
        system_prompt = "You write detailed product requirement documents.";
        system_prompt_template = None;
        model = { provider = `Openai; model_name = "gpt-4";
                  api_base = None; temperature = 0.4;
                  max_tokens = Some 4096; top_p = None; stop_sequences = None };
        tools = [];
        max_iterations = 1;        (* unused on the generate path *)
        middleware = [];
        retry_policy = None;
        context_strategy = None;
        resource_quota = None;
        max_execution_time = None; (* unused; total_timeout replaces it *)
        early_stopping_method = Types.Force;
        on_max_tokens = None;      (* None = Auto: tool-less resolves to Continue *)
        max_continuation_chunks = None; (* None = Auto: unbounded for tool-less *)
        tool_timeout = None;
      } in
      (match Runtime.register_agent rt agent with
       | Error e -> prerr_endline (Types.string_of_error_category e)
       | Ok () ->
         match Runtime.invoke_generate rt
           ~agent_id:"prd-agent"
           ~message:"Write a PRD for offline-first sync in a notes app."
           ()
         with
         | Error (e, _conv) ->
           prerr_endline (Types.string_of_error_category e)
         | Ok result ->
           Printf.printf "%s\n" result.Types.text;
           Printf.printf "finish_reason: %d continuations, %f s\n"
             result.Types.continuations result.Types.elapsed));
      ignore (Runtime.close rt))
)
```

The same call works without `?max_output_tokens` and `?total_timeout`; the defaults are the agent's model cap and unbounded, respectively.

### Example 2: Python usage

`Runtime.invoke_generate` is exposed on the Python `Runtime` class. The return value is a dict with the `generate_result` fields plus the `Ok` / `Error` discriminator shape the FFI uses for all `result` types.

```python
import json
from par_runtime import Runtime

config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "llm_providers": [["openai", {"tag": "openai",
                                   "contents": {"api_key": "sk-..."}}]],
    "default_quota": {"max_tokens": 4096, "max_iterations": 10,
                      "timeout_seconds": 120.0},
})

with Runtime(config) as rt:
    rt.register_agent(json.dumps({
        "id": "prd-agent",
        "system_prompt": "You write detailed PRDs.",
        "model": {"provider": "openai", "model_name": "gpt-4",
                  "temperature": 0.4, "max_tokens": 4096},
        "tools": [],
        "max_iterations": 1,
        "early_stopping_method": "Force",
    }))
    result = rt.invoke_generate("prd-agent", "Write a PRD for feature X.")
    print(result["text"])
    print(f"finish_reason={result['finish_reason']}, "
          f"continuations={result['continuations']}, "
          f"elapsed={result['elapsed']:.2f}s")
```

The agent config has `tools = []` because `invoke_generate` rejects tool-bearing agents. The Python binding returns the same fields as the OCaml `generate_result` record.

### Example 3: With streaming callback

Pass `?on_chunk` to render text as it lands. The callback receives the same `llm_response_chunk` ADT that `Runtime.invoke` and `invoke_stream` emit. Concatenate `Text_delta` payloads to render incrementally.

```python
import json
from par_runtime import Runtime, TextDelta

def on_chunk_json(chunk_json: str) -> None:
    chunk = json.loads(chunk_json)
    if chunk.get("tag") == "Text_delta":
        print(chunk["contents"]["text"], end="", flush=True)

with Runtime(config) as rt:
    rt.register_agent(json.dumps({
        "id": "another downstream agent",
        "system_prompt": "You produce self-contained HTML mockups.",
        "model": {"provider": "anthropic",
                  "model_name": "claude-sonnet-4-20250514",
                  "temperature": 0.3, "max_tokens": 8192},
        "tools": [],
        "max_iterations": 1,
        "early_stopping_method": "Force",
    }))
    result = rt.invoke_generate(
        "another downstream agent",
        "Mock up a settings page with light and dark modes.",
        on_chunk=on_chunk_json,
        total_timeout=90.0,
    )
    print()  # newline after the streamed text
    print(f"[done: {result['continuations']} continuations, "
          f"{result['elapsed']:.2f}s]")
```

The `total_timeout` caps the whole generation, continuations included. If the model is still going at the deadline, the runtime returns whatever has accumulated.

## Limitations

- **Agent MUST have `tools = []`.** Tool-bearing agents are rejected with `Invalid_input` at the `invoke_generate` call site. This is enforced rather than silently ignored, because the generate path has no tool dispatch. If your agent needs tools, use `Runtime.invoke` with `on_max_tokens = Continue` instead.
- **No fallback chain.** The generate path uses the agent's primary provider only. The cross-provider `fallback_policy` configured on the runtime does not apply. Long generations that need provider diversity should run multiple `invoke_generate` calls and pick the best output upstream.
- **Wall-clock timeout returns partial on accumulated text.** When `?total_timeout` fires after at least one chunk has landed, the runtime returns `Ok` with `finish_reason` reflecting the last provider response and the accumulated text. When the timeout fires before any chunk lands (the initial LLM call hung), it returns `Error (Timeout, conversation)`.
- **Diminishing-returns guard is fixed at 500 characters.** A continuation chunk that adds fewer than 500 characters halts the loop. This catches models that get stuck restating themselves. It is not configurable in v0.6.x.
- **No middleware at LLM boundaries.** The `agent_config.middleware` pipeline does not fire on the generate path. Logging, retry, and rate-limit middleware that you rely on for `invoke` will not run here. Wire equivalent behavior at the call site if you need it.
- **`max_iterations` and `max_execution_time` are ignored.** They live on `agent_config` for ReAct compatibility. The generate path replaces them with `?total_timeout`. The continuation count has no fixed cap; the diminishing-returns guard is the only ceiling.

## See also

- [Agent API](agent.md) - `agent_config`, `Runtime.invoke`, the ReAct entrypoint and the `on_max_tokens` policy that mirrors generate's continuation logic
- [Streaming API](streaming.md) - `invoke_stream`, chunked delivery, and the `llm_response_chunk` ADT that `?on_chunk` exposes here
- [Overview](overview.md) - SDK architecture and module map
