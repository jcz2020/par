<!-- language: en -->

# Streaming API Reference

> Added in v0.5.1. Source-of-truth: the OCaml type `Types.llm_response_chunk` in `lib/core/types.ml`. Phase C.1 design contract; Phases C.2 (FFI bridge) and C.3 (Python generator) implement this document.

This page is the API contract for streaming LLM output from PAR's Python binding. It locks the shape of `invoke_stream`, the `Event` tagged union, the backpressure strategy, and the threading model. If you are writing Python code that consumes tokens as they arrive, read the Usage Examples section. If you are implementing the FFI bridge, skip to the Implementation Notes at the end.

## Overview

Streaming lets a caller consume an LLM's output token by token instead of waiting for the full response. For interactive UIs this cuts perceived latency from "wait 8 seconds, then dump 500 words" to "first token in 200 ms, then a steady drip." For long-running tool-call flows it also means the caller can cancel early once it sees enough.

PAR adds streaming in v0.5.1 by exposing the existing `?on_chunk` parameter on `Runtime.invoke` through a new Python method, `invoke_stream`. The OCaml side has supported chunked output since v0.4.0 (see `lib/core/types.ml` line 509 for the `llm_response_chunk` ADT), but the FFI surface and Python wrapper have not yet shipped. This document defines what they should look like before any implementation code is written.

Provider support varies and is documented in the Provider Support section below. OpenAI, Anthropic, and Mock all stream text deltas and tool-call deltas; only Anthropic and Mock also emit usage updates.

## Three alternatives considered

Three shapes were on the table when designing the Python surface. They are documented here so the choice is auditable, and so future maintainers don't relitigate it without context.

### Option 1: Generator

The runtime exposes a method that returns a lazy iterator. Each `next()` call yields one `Event`. The caller drives consumption with a `for` loop.

```python
def invoke_stream(self, agent_id: str, message: str) -> Iterator[Event]: ...

for event in rt.invoke_stream("agent", "hello"):
    ...
```

**Pros**

- Matches the OpenAI Python SDK convention (`stream=True` returns an iterator of `ChatCompletionChunk`). Developers who have streamed from OpenAI before will write idiomatic PAR code on the first try.
- Composes with the rest of Python: `list(stream)`, `itertools.islice(stream, n)`, `asyncio.run_in_executor` wrappers, generator-based pipelines.
- Backpressure is free. The OCaml side only produces the next chunk when the generator resumes, so a slow consumer cannot flood the queue.
- Resource cleanup maps cleanly onto `generator.close()` and `with` blocks. A `finally` clause in the generator body can cancel the underlying OCaml fiber.
- Cancellation is just `break`. Python's iterator protocol already handles `GeneratorExit` propagation.

**Cons**

- The caller must consume the iterator. If they call `invoke_stream` and throw the result away, the OCaml side may keep running until its next chunk attempt blocks forever. Mitigation: a `finally` clause in the generator that cancels the fiber, plus a `__del__` warning.
- Error surface is split. Some failures raise from `next()` (chunk-level errors), others from the initial `invoke_stream` call (parameter validation). This is the same as OpenAI's SDK, but worth noting.
- Cross-thread handoff is required. The OCaml runtime invokes the C callback on its own fiber; the generator runs on the caller's thread. A queue must bridge them. This is unavoidable for any streaming shape that lets the caller consume on its own thread.
- Harder to layer additional callback-style hooks later (logging, metrics). Each layer has to be a generator wrapper rather than a function.

**When it's the right choice.** When the caller is Pythonic, wants natural `for` loops, and doesn't need to fan events out to multiple subscribers.

### Option 2: Callback

The runtime exposes `invoke` with an `on_event` keyword that fires for each chunk. The caller passes a callable.

```python
def invoke(self, agent_id: str, message: str,
           on_event: Callable[[Event], None]) -> None: ...

rt.invoke("agent", "hello", on_event=print)
```

**Pros**

- Matches the OCaml-side shape directly. `?on_chunk` at `Runtime.invoke` (`lib/core/runtime.ml` line 336) is already a callback parameter; the FFI can hand it straight through with no queue.
- Simpler FFI. No iterator state machine on the Python side, no sentinel, no `_DONE` protocol. One callback pointer, one C entrypoint.
- Easy to layer. A logger or metrics hook is just another callable composed via a small wrapper.
- Familiar to JavaScript and Java refugees who expect event-driven APIs.

**Cons**

- Un-Pythonic. Python developers reach for iterators first; callbacks feel like 2012-era `tornado.gen.engine`.
- Hard to cancel mid-stream. The callback cannot tell the runtime to stop without a side channel (an exception, a flag the runtime has to check). Exception-based cancellation is fragile because the callback might be running on the OCaml fiber's stack.
- No backpressure. If the callback is slow, the OCaml side blocks, but the caller has no way to apply backpressure upstream because they don't control the loop.
- Hard to collect results. The caller has to maintain their own buffer in a closure-captured list, which is ugly when the same callback is reused.
- Composition with `for` loops, list comprehensions, and `asyncio` requires the caller to wrap the callback in their own queue-and-generator adapter. They will end up rebuilding Option 1.

**When it's the right choice.** When the caller is a non-Pythonic environment that already speaks in callbacks (an Electron host, a Java bridge), or when FFI simplicity matters more than caller ergonomics.

### Option 3: Both

Expose both surfaces. The generator wraps the callback internally.

```python
def invoke(self, ..., on_event: Optional[Callable[[Event], None]] = None) -> None: ...
def invoke_stream(self, ...) -> Iterator[Event]: ...
```

**Pros**

- Familiar to anyone who has used the OpenAI SDK (`stream=True` on `chat.completions.create`) and to anyone who has used Anthropic's SDK (`client.messages.stream()` returns a context manager).
- No wrong door. Either style works; callers pick what fits.

**Cons**

- Two APIs to test, document, and keep in sync. The v0.5.1 surface is small; doubling it for stylistic preference is not justified yet.
- The callback variant has the cancellation and backpressure problems noted under Option 2. Shipping it endorses those problems.
- Versioning hazard. If the generator evolves (per-chunk metadata, async variant), the callback has to evolve in lockstep or grow a second parameter set.

**When it's the right choice.** When the project is large enough that two distinct caller populations exist (Python application developers plus a non-Python host bridge), and the maintainer budget covers both.

## Recommendation: generator (Option 1)

PAR's primary Python audience is backend engineers writing agent-powered services. They expect iterators, they reach for `for event in ...` by default, and they have already used the OpenAI SDK's `stream=True`. Option 1 matches that muscle memory.

Option 2 is rejected as the primary surface because its cancellation and backpressure problems are real and the FFI simplicity gain is a one-time cost. Option 3 is rejected for v0.5.1 because the maintainer budget does not cover two surfaces, and nothing prevents adding a callback-style wrapper in v0.6 if a real caller asks for it. A generator can be wrapped in a callback adapter in five lines; the reverse requires the full queue-plus-sentinel machinery this document specifies.

The rest of this document specifies Option 1 in full.

## Event type

`Event` is a frozen-dataclass union mirroring the OCaml `llm_response_chunk` ADT at `lib/core/types.ml` line 509. Each constructor maps to one Python class. Field names match the OCaml record labels exactly so JSON round-trips are predictable.

```python
from dataclasses import dataclass
from typing import Union

@dataclass(frozen=True)
class TextDelta:
    """A chunk of text from the LLM. Concatenate `text` across deltas."""
    text: str

@dataclass(frozen=True)
class ToolCallStart:
    """The LLM is beginning a tool call. Followed by zero or more ToolCallDelta."""
    tool_call_id: str
    name: str

@dataclass(frozen=True)
class ToolCallDelta:
    """A fragment of the tool call's JSON arguments. Concatenate `args_json`."""
    tool_call_id: str
    args_json: str

@dataclass(frozen=True)
class UsageUpdate:
    """Token usage so far. Emitted at most once per stream, near the end."""
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int

@dataclass(frozen=True)
class Done:
    """The stream is complete. `finish_reason` is one of: stop, tool_calls, length, content_filter, max_iterations."""
    finish_reason: str

Event = Union[TextDelta, ToolCallStart, ToolCallDelta, UsageUpdate, Done]
```

Invariants:

- `TextDelta` events arrive in order. Concatenate `text` to reconstruct the full assistant message.
- A `ToolCallStart` is followed by zero or more `ToolCallDelta` events with the same `tool_call_id`. Concatenate `args_json` and parse the result as JSON to recover the tool call arguments.
- `UsageUpdate` is optional. OpenAI does not emit it; Anthropic and Mock do. Callers that display token usage must tolerate its absence.
- `Done` is always the last event. The generator exits after yielding it. If the stream ends without `Done` (network error, cancellation), the generator raises `PARInvokeError` from `next()`.

## API signature

```python
from typing import Iterator

def invoke_stream(
    self,
    agent_id: str,
    message: str,
) -> Iterator[Event]: ...
```

Notes:

- The method name carries the streaming semantic. There is no `stream=True` flag on `invoke`; callers who want non-streaming behavior use `invoke`, callers who want streaming use `invoke_stream`. Two methods, two intents, no boolean trap.
- The return type is `Iterator[Event]`, not `List[Event]`. The iterator yields events as the LLM produces them.
- The first `next()` call starts a background daemon thread that runs `par_invoke_stream`. If the invoke fails, `PARInvokeError` is raised on iteration.
- v0.5.3: chunks arrive incrementally in real time — the first token reaches the caller within milliseconds of the LLM producing it, not after the full response completes. (v0.5.1–v0.5.2 used buffered delivery; v0.5.3 rewired the FFI to a background-thread + queue model.)
- Keyword-only extensions (cancellation tokens, conversation IDs, RAG options) will be added in later versions under their own keyword arguments. The v0.5.3 signature is intentionally minimal.

## Incremental chunk delivery (v0.5.3)

`par_invoke_stream` runs in a background daemon thread. The OCaml SSE parser fires a ctypes callback (`caml_dispatch_chunk_to_c`) for each chunk as the LLM produces it. The callback pushes the JSON-encoded chunk onto a `queue.Queue`. The Python iterator's `__next__` consumes the queue concurrently, so events are delivered in real time.

This means:
- The first token arrives within milliseconds of the LLM producing it, not after the full response completes. For a 30-second generation, perceived latency drops from "30 s black screen" to "first token < 1 s".
- The background thread holds the process-global C `ocaml_lock` for the duration of the stream. If the caller breaks early from the iterator, the thread continues until the LLM stream completes naturally, and subsequent `par_*` calls block during that window. See the `invoke_stream` docstring for the full caveat.
- The buffered JSON envelope (`"chunks": [...]` in the final response) is still returned for backward compatibility — callers reading `parsed["chunks"]` directly are unaffected.

## Provider support

| Provider | Text streaming | Tool call streaming | Usage update | Notes |
|----------|----------------|---------------------|--------------|-------|
| `` `Openai `` | Yes | Yes | No | OpenAI does not emit token counts during streaming; the `UsageUpdate` event will not appear. Callers that need usage must fall back to non-streaming `invoke`. |
| `` `Anthropic `` | Yes | Yes | Yes | Verify against `lib/llm/anthropic_provider.ml` when implementing C.2. Anthropic's stream messages include `message_delta` with `usage` blocks. |
| `` `Mock `` | Yes | Yes | Yes | The mock provider emits all five event types. Use it as the streaming test fixture. |
| `` `Ollama `` | Yes | Unknown | Unknown | Not validated for streaming in v0.5.1. Test before relying on it. |

If a provider does not support streaming natively, the runtime falls back to emitting a single `TextDelta` with the full response followed by `Done`. The caller should not assume chunks are small.

## Usage examples

Three runnable examples covering the patterns you will actually need: a basic token stream, a tool-call stream that reconstructs the call arguments, and an error-handling wrapper that catches provider failures without leaking partial output.

### Example 1: print tokens as they arrive

The most common shape. Iterate the generator, match on `TextDelta` to print each fragment as it lands, and stop when `Done` arrives. The `flush=True` matters for terminals and pipe-forwarded UIs; without it, Python buffers stdout and the streaming UX disappears.

```python
from par_runtime import Runtime, TextDelta, Done

with Runtime(config_json) as rt:
    for event in rt.invoke_stream("agent", "Tell me a joke"):
        if isinstance(event, TextDelta):
            print(event.text, end="", flush=True)
        elif isinstance(event, Done):
            print()  # newline after the final token
            # event.finish_reason is one of: stop, tool_calls, length,
            # content_filter, max_iterations
```

If you just need the full message and do not care about latency, `"".join(e.text for e in rt.invoke_stream(...) if isinstance(e, TextDelta))` reconstructs it. You lose the streaming benefit, but the API does not force you to consume incrementally.

### Example 2: stream a tool call and reconstruct its arguments

LLM providers send tool calls as a `ToolCallStart` (the call id and tool name) followed by zero or more `ToolCallDelta` fragments whose `args_json` strings concatenate to the full JSON arguments. Buffer the fragments by `tool_call_id`, then parse the concatenation when the stream ends.

```python
import json
from collections import defaultdict
from par_runtime import (
    Runtime, TextDelta, ToolCallStart, ToolCallDelta, Done,
)

with Runtime(config_json) as rt:
    text_parts = []
    tool_buffers = defaultdict(list)
    tool_names = {}

    for event in rt.invoke_stream("agent", "What's the weather in Tokyo?"):
        if isinstance(event, TextDelta):
            text_parts.append(event.text)
        elif isinstance(event, ToolCallStart):
            tool_names[event.tool_call_id] = event.name
        elif isinstance(event, ToolCallDelta):
            tool_buffers[event.tool_call_id].append(event.args_json)
        elif isinstance(event, Done):
            break

    for tool_call_id, fragments in tool_buffers.items():
        args = json.loads("".join(fragments))
        print(f"Tool call: {tool_names[tool_call_id]}({args})")
```

The same pattern works for parallel tool calls: each call has its own `tool_call_id`, so the buffer keyed by id keeps them separate without race conditions.

### Example 3: handle errors and cancel cleanly

Wrap the iterator in `try/except` to catch provider failures (network, auth, content filter) and fiber errors. Breaking out of the loop or letting the `with` block exit runs the generator's `finally` clause, which joins the OCaml fiber and releases the queue. Never let an exception escape without closing the iterator.

```python
from par_runtime import Runtime, TextDelta, PARError

try:
    with Runtime(config_json) as rt:
        try:
            for event in rt.invoke_stream("agent", "hello"):
                if isinstance(event, TextDelta):
                    print(event.text, end="", flush=True)
        except PARError as e:
            # Provider-side failure surfaced via the FFI: bad model name,
            # rate limit, content filter, etc. Partial output may already
            # have been printed; that is expected for streaming.
            print(f"\n[stream failed: {e}]")
        except KeyboardInterrupt:
            # Ctrl-C during iteration. GeneratorExit fires, the finally
            # block cancels the OCaml fiber, and the runtime shuts down.
            print("\n[cancelled by user]")
            raise
finally:
    # rt.close() runs automatically when the `with` block exits.
    pass
```

The `PARError` covers every error path that crosses the FFI boundary: malformed config, unknown agent id, provider HTTP errors, and any exception raised inside the chunk callback. The `KeyboardInterrupt` branch is worth keeping explicit so user-initiated cancellation logs cleanly rather than printing a traceback.

## Limitations

- **No async/await support.** The iterator is synchronous. An `async for` wrapper is a future candidate; it will likely be a thin `asyncio` adapter around the sync iterator rather than a separate code path.
- **No nested event hierarchy.** PAR does not emit LangChain-style `parent_run_id` or `run_id` metadata on streaming events. If you need to correlate streams with tool calls or sub-agent invocations, use the event bus (`par_event_subscribe`, wired up in C.2) for structured events.
- **No `invoke_with_rag_streaming`.** The RAG entrypoint (`Runtime.invoke_with_rag`) will get its own streaming variant in a future release.
- **Backpressure is blocking.** If the consumer is much slower than the producer, the OCaml fiber blocks on `queue.put`. This is an acceptable tradeoff versus unbounded memory growth, but it does mean a hung consumer ties up an OCaml fiber until the stream completes or is cancelled.
- **Single consumer only.** The iterator is not broadcast. If multiple subscribers need the same stream, fan out at the application level (wrap the iterator in your own pub-sub).
- **Early break blocks subsequent calls (v0.5.3 known limitation).** Breaking from the iterator before `Done` leaves the background daemon thread holding `ocaml_lock` until the LLM stream completes. See the `invoke_stream` docstring and CHANGES.md "Known Limitation" for details. A `par_cancel_stream` FFI is planned for v0.5.4.

## Implementation notes (for C.2 and C.3 maintainers)

This section is informational. It does not define the public API; it records the hooks the FFI bridge should use.

- **Reuse the existing `?on_chunk` parameter.** `Runtime.invoke` at `lib/core/runtime.ml` line 336 already accepts `?on_chunk : (Types.llm_response_chunk -> unit) option`. Wire the C callback through this parameter; do not add a new code path on the OCaml side.
- **Do not route chunks through the event bus.** The event bus (`Event_bus` module) has no streaming event constructor and should not gain one. Streaming chunks are a synchronous callback, not a publish-subscribe event. Mixing the two would couple stream consumers to event-bus retention policy.
- **Reference consumer implementation.** `bin/main.ml` line 386 defines `stream_print_chunk`, used at lines 501 and 578 to stream `par ask` output to the terminal. It is the canonical example of a chunk consumer and shows the expected `Text_delta` / `Tool_call_delta` handling.
- **New C entrypoint.** Add `par_invoke_stream(par_runtime_t* rt, const char* agent_id, const char* message, par_event_callback cb, void* user_data)` to `lib/ffi/par_ffi.h` and `lib/ffi/par_ffi.c`. Model the signature on `par_invoke` and the existing `par_event_callback` typedef at `lib/ffi/par_ffi.h` line 64. The `user_data` pointer is forwarded untouched to the callback so the Python binding can pass its queue reference.
- **Existing subscribe stub.** `par_event_subscribe` is declared at `lib/ffi/par_ffi.h` line 64 and stubbed at `lib/ffi/par_ffi.c` line 336 (returns `-1`). It is unrelated to streaming but uses the same callback shape. Wiring it up is optional for C.2 and may slip to a later phase; the streaming entrypoint does not depend on it.
- **Existing Python precedent.** `bindings/python/par_runtime/_ffi.py` line 62 defines `_PYTHON_TOOL_CALLBACK = CFUNCTYPE(c_char_p, c_int, c_char_p)`. Mirror this pattern for the streaming callback: define `_STREAM_CALLBACK = CFUNCTYPE(None, c_char_p, c_char_p)` (event_type, event_json), keep the closure on `self._cb_keepalive` for the runtime's lifetime, parse the JSON inside the callback, and push a constructed `Event` onto the queue.

## See also

- [Agent API](agent.md) - `Runtime.invoke`, `agent_config`, the non-streaming entrypoint that `invoke_stream` mirrors
- [Overview](overview.md) - SDK architecture and module map
- [Workflow API](workflow.md) - workflow orchestration; workflow steps do not yet support streaming
- [Tools API](tools.md) - the 20 built-in tools, including type-safe bash
