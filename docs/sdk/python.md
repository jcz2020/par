<!-- language: en -->

**English** · [简体中文](https://github.com/jcz2020/par/blob/main/zh/sdk/python.md)

# Python API

> Added in v0.18.0-beta. Typed models and `AsyncRuntime` are additive: the
> legacy JSON-string API keeps working until v1.0.

`par_runtime` is the Python surface of PAR. It ships typed request/response
models, a synchronous `Runtime`, and an asyncio `AsyncRuntime`, all backed by
the same C bridge and the same OCaml runtime.

```bash
pip install par-runtime
```

## Quickstart

```python
from par_runtime import AgentConfig, ModelConfig, Runtime, RuntimeConfig

agent = AgentConfig(
    id="assistant",
    system_prompt="You are helpful.",
    model=ModelConfig(
        provider="openai",
        model_name="gpt-4o",
        temperature=0.2,
    ),
)

with Runtime(RuntimeConfig()) as rt:
    rt.register_agent(agent)
    result = rt.invoke_result("assistant", "hello")
    print(result.text, result.usage.total_tokens)
```

`RuntimeConfig()` defaults to in-memory SQLite. Point it at a file to persist
conversations across processes:

```python
config = RuntimeConfig(persistence=Sqlite("par.db"))
```

An LLM provider is still configured with the same JSON shape the runtime
already accepted; typed models cover the request path, not provider secrets:

```python
config = RuntimeConfig(
    llm_providers=[[
        "default",
        ["Openai", {
            "api_key": "sk-...",
            "base_url": "https://api.openai.com/v1",
            "organization": None,
            "embedding_model": None,
        }],
    ]],
)
```

## Typed models

All models live in `par_runtime.models` and are re-exported from
`par_runtime`. Each one has `to_json()` (a JSON string) and `from_json()`
(accepting a string or dict), so a typed object can always be persisted or
sent over the wire in the legacy form.

| Model | Purpose | Notable defaults |
|---|---|---|
| `RuntimeConfig` | Runtime configuration | `persistence=Sqlite(":memory:")`, `parallel_tool_execution=True` |
| `Sqlite` | Persistence backend | `path=":memory:"` |
| `ModelConfig` | Model + sampling | `provider="openai"`, `temperature=0.7` |
| `ToolSpec` | Tool descriptor | `input_schema={"type": "object"}` |
| `AgentConfig` | Agent definition | `tools=[]`, `max_iterations=1_000_000` |
| `InvokeResult` | Decoded invoke envelope | `finish_reason="stop"` |
| `Usage` | Token accounting | all counters `0` |
| `ToolCall` | One model-requested tool call | — |
| `Error` | Error envelope | — |

Defaults are not decorative. They mirror the two decoders that consume the
payloads — `Runtime._normalize_config` and `lib/ffi/par_capi.ml` — and the test
suite asserts that `RuntimeConfig().to_json()` normalizes to exactly the same
OCaml configuration as a hand-written minimal JSON object.

The four config blocks without a typed surface yet (`event_bus`,
`default_quota`, `shutdown`, `eval_limits`) accept dict overrides merged over
their defaults:

```python
config = RuntimeConfig(default_quota={"max_concurrent_tasks": 2})
```

## `invoke_result()` and the deprecated `invoke()`

`Runtime.invoke_result()` returns an `InvokeResult`:

```python
result = rt.invoke_result("assistant", "hello")
result.text            # str | None
result.tool_calls      # list[ToolCall]
result.finish_reason   # "stop" | "tool_calls" | "max_tokens" | "content_filter"
result.usage           # Usage
result.model           # provider-reported model id
```

`Runtime.invoke()` still returns the raw JSON envelope (`{"status": "ok",
"content": {...}}`) and now emits a `DeprecationWarning`. It will be removed in
v1.0. New code should use `invoke_result()`.

## Async

`AsyncRuntime` wraps the same runtime handle. Startup is lazy; entering the
async context initializes the OCaml runtime on the event-loop thread, where the
C bridge expects it.

```python
import asyncio
from par_runtime import AsyncRuntime, TextDelta

async def main():
    async with AsyncRuntime(RuntimeConfig()) as rt:
        await rt.register_agent(agent)
        result = await rt.invoke("assistant", "hello")
        print(result.text)

        async for event in rt.stream("assistant", "hello"):
            if isinstance(event, TextDelta):
                print(event.text, end="")

asyncio.run(main())
```

- `await rt.invoke(...)` uses the handle API (`invoke_start` /
  `invoke_poll` / `invoke_cancel`). Cancelling the task sets the runtime's
  cancel flag; the run stops at its next cancellation point, and a background
  drain consumes the handle so a cancelled call does not leak its slot.
- `rt.stream(...)` yields the same `TextDelta` / `ToolCallDelta` / ... events
  as the synchronous `Runtime.invoke_stream`. Breaking out of `async for`
  cancels and frees the stream handle.
- The event loop is never blocked longer than one short C poll (10 ms). The
  runtime still runs its own Eio domain; Python only schedules the polls.
- `rt.sync` exposes the underlying `Runtime` for methods not wrapped yet.

## Migrating from JSON strings

The old form remains valid, so migration can be incremental:

```python
# Before
config = json.dumps({"persistence": {"tag": "sqlite", "contents": ":memory:"}})
with Runtime(config) as rt:
    rt.register_agent(json.dumps({
        "id": "assistant",
        "system_prompt": "You are helpful.",
        "model": {"provider": "openai", "model_name": "gpt-4o", "temperature": 0.2},
        "tools": [],
    }))
    raw = rt.invoke("assistant", "hello")

# After
with Runtime(RuntimeConfig()) as rt:
    rt.register_agent(AgentConfig(
        id="assistant",
        system_prompt="You are helpful.",
        model=ModelConfig(provider="openai", model_name="gpt-4o",
                          temperature=0.2),
    ))
    result = rt.invoke_result("assistant", "hello")
```

`Runtime(...)` and `register_agent(...)` accept a typed model, a dict, or a
JSON string, and the three forms produce the same runtime behavior.

## Type checking

The package ships `py.typed` and passes `mypy --strict par_runtime` in CI.
Users on Python 3.10+ get completion for every field above.

## See also

- [Agent API](agent.md) — the OCaml surface and wire-level behavior
- [Streaming API](streaming.md) — event types and cancellation semantics
- [Persistence API](persistence.md) — SQLite schema and scopes
