<!-- language: en -->

# Tutorial 2: Stream Tokens into a TTY UI

> Follows the Diataxis tutorial form: learning by doing.
> Pair with the [Streaming API reference](../sdk/streaming.md) for the full event
> contract, threading model, and backpressure notes.

Token streaming cuts perceived latency from "wait eight seconds, then dump five
hundred words" to "first token in two hundred milliseconds, then a steady drip."
This tutorial shows you how to consume PAR's `invoke_stream` generator, tell the
event types apart, paint them onto a terminal with color, and handle a user
hitting Ctrl-C without leaking the underlying stream.

You will build the rendering layer a chat-style REPL needs: a loop that reads
events, reconstructs the assistant's message, distinguishes tool calls from
text, and shuts down cleanly on interruption. Every code block runs without an
LLM API key. The blocks that teach event handling and rendering need no provider
at all. The final block, which lights up a live stream, checks for a key and
skips cleanly when one is absent.

## What you will build

A small Python program that:

1. Iterates the stream generator PAR returns from `invoke_stream`.
2. Tells `TextDelta`, `ToolCallStart`, `ToolCallDelta`, `UsageUpdate`, and `Done`
   apart and handles each.
3. Renders assistant text, tool calls, and usage in distinct ANSI colors.
4. Traps `KeyboardInterrupt` so Ctrl-C exits the loop without a traceback.
5. Plugs in a live provider when a key is available.

The event vocabulary is fixed by the OCaml type `Types.llm_response_chunk`, and
the Python binding mirrors it as a frozen-dataclass union. Learn the five types
once and every streaming consumer you write afterwards falls out the same way.

## Prerequisites

The Python binding, importable.

```bash
pip install par-runtime
python -c "from par_runtime import Runtime, TextDelta, Done; print('ok')"
```

If that prints `ok`, keep reading. No API key is required for the first four
steps. Step 5 reads `OPENAI_API_KEY` and skips when it is missing.

## Step 1: Meet the five event types

Every value `invoke_stream` yields is one of five frozen dataclasses. Their
names mirror the OCaml constructors exactly, so JSON round-trips stay
predictable.

```python
from par_runtime import (
    TextDelta,
    ToolCallStart,
    ToolCallDelta,
    UsageUpdate,
    Done,
)

# A fragment of assistant text. Concatenate `text` across deltas to
# rebuild the full message.
assert TextDelta(text="hel").text == "hel"

# The model is beginning a tool call. The id ties together the deltas
# that carry the arguments.
assert ToolCallStart(tool_call_id="tc1", name="get_weather").name == "get_weather"

# A fragment of the tool call's JSON arguments. Buffer by tool_call_id,
# then parse the concatenation when the stream ends.
assert ToolCallDelta(tool_call_id="tc1", args_json='{"city":').args_json == '{"city":'

# Optional token usage. OpenAI does not emit it mid-stream; Anthropic and
# Mock do. Code that shows usage must tolerate its absence.
assert UsageUpdate(prompt_tokens=5, completion_tokens=10, total_tokens=15).total_tokens == 15

# Always the last event. finish_reason is one of stop, tool_calls,
# length, content_filter, max_iterations.
assert Done(finish_reason="stop").finish_reason == "stop"

print("all five event types understood")
```

Two invariants worth internalizing now. First, `TextDelta` events arrive in
order, so concatenating `text` rebuilds the assistant message exactly. Second, a
`Done` event is always last. If the stream ends without one, the generator
raises instead, which is how a network failure or a cancellation surfaces.

## Step 2: Decode a stream by hand

Before you consume a live stream, learn to decode chunks the way the binding
does. The `_decode_event` helper turns the JSON shape the OCaml side emits into
the dataclasses above. Driving it directly is how PAR's own test suite checks
every constructor without standing up a provider.

The OCaml encoder emits polymorphic variants as `[Constructor, {fields}]`. The
decoder accepts both that shape and the newer `{"tag": ...}` form, so the code
below is forward-compatible.

```python
from par_runtime import TextDelta, ToolCallStart, ToolCallDelta, UsageUpdate, Done
from par_runtime.runtime import _decode_event

# The shape the FFI delivers: [Constructor, {fields}].
delta = _decode_event(["Text_delta", {"text": "hello"}])
assert isinstance(delta, TextDelta) and delta.text == "hello"

start = _decode_event(["Tool_call_start", {"tool_call_id": "tc1", "name": "get_weather"}])
assert isinstance(start, ToolCallStart) and start.name == "get_weather"

frag = _decode_event(["Tool_call_delta", {"tool_call_id": "tc1", "args_json": '{"city":"Tokyo"}'}])
assert isinstance(frag, ToolCallDelta) and frag.args_json == '{"city":"Tokyo"}'

usage = _decode_event(["Usage_update", {
    "prompt_tokens": 5, "completion_tokens": 10, "total_tokens": 15}])
assert isinstance(usage, UsageUpdate)
assert (usage.prompt_tokens, usage.completion_tokens, usage.total_tokens) == (5, 10, 15)

# finish_reason arrives as a one-element polymorphic variant list and is
# normalized to a lowercase string.
done = _decode_event(["Done", {"finish_reason": ["Tool_calls"]}])
assert isinstance(done, Done) and done.finish_reason == "tool_calls"

print("decoded all five variants")
```

This is the whole event-handling core. Every streaming consumer you write is a
loop over these decoded events plus a buffer or two.

## Step 3: Reconstruct a tool call from fragments

A tool call arrives as one `ToolCallStart` followed by zero or more
`ToolCallDelta` events, all sharing a `tool_call_id`. The argument JSON arrives
in pieces. Buffer the fragments per id and parse the concatenation at the end.

This pattern is pure Python, no provider needed, and it generalizes to parallel
tool calls: each call has its own id, so a dict keyed by id keeps them separate.

```python
import json
from collections import defaultdict

# A canned sequence of events exactly as a provider would emit them. Each
# tuple is (kind, call_id, name_or_text, args_or_reason). The positions are
# chosen so one unpack matches the branch logic below.
events = [
    ("ToolCallStart", "tc1", "get_weather", None),
    ("ToolCallDelta", "tc1", None, '{"city":'),
    ("ToolCallDelta", "tc1", None, '"Tokyo","units":"c"}'),
    ("TextDelta", None, "Looking up the weather in Tokyo.", None),
    ("Done", None, None, "tool_calls"),
]

tool_names = {}
tool_args = defaultdict(list)
text_parts = []
finish = None

for kind, call_id, name_or_text, args_or_reason in events:
    if kind == "ToolCallStart":
        tool_names[call_id] = name_or_text
    elif kind == "ToolCallDelta":
        tool_args[call_id].append(args_or_reason)
    elif kind == "TextDelta":
        text_parts.append(name_or_text)
    elif kind == "Done":
        finish = args_or_reason

print("assistant:", "".join(text_parts))
for call_id, fragments in tool_args.items():
    args = json.loads("".join(fragments))
    print("tool call: %s(%s)" % (tool_names[call_id], args))
print("finish_reason:", finish)
```

The output shows the assistant text, the reconstructed tool call, and the finish
reason. In a live stream you would hand the parsed arguments to your tool
registry and dispatch. The buffering logic does not change.

## Step 4: Render with ANSI color

A terminal chat UI distinguishes speakers at a glance with color. The assistant
gets one color, the user another, tool output a third. The block below is a
self-contained renderer you can drop into a REPL loop. It runs against canned
events so you can see the coloring without a provider.

If your terminal strips ANSI, the text still reads fine. The color codes are
additive, not structural.

```python
ASSISTANT = "\033[36m"  # cyan
TOOL = "\033[33m"       # yellow
USAGE = "\033[2m"       # dim
RESET = "\033[0m"

events = [
    ("TextDelta", "PAR is an OCaml agent runtime."),
    ("TextDelta", " It uses Eio for structured concurrency."),
    ("Usage", "prompt=12 completion=9 total=21"),
    ("Done", "stop"),
]

print(ASSISTANT + "assistant: " + RESET, end="", flush=True)
for kind, payload in events:
    if kind == "TextDelta":
        print(ASSISTANT + payload + RESET, end="", flush=True)
    elif kind == "Usage":
        print("\n" + USAGE + "[usage] " + payload + RESET, end="", flush=True)
    elif kind == "Done":
        print("\n" + USAGE + "[done] finish=" + payload + RESET)
print("rendered")
```

The `flush=True` matters. Without it Python buffers stdout and the streaming UX
disappears, which defeats the entire point. Pipe the script through `cat` and
you would see a single dump at the end; keep the flushes and each token appears
as the producer emits it.

## Step 5: Handle Ctrl-C without a traceback

A user who hits Ctrl-C expects a clean exit, not a stack trace. Trap
`KeyboardInterrupt` around the loop, print a newline, and let the generator's
`finally` clause tear down the background thread. The shape below is the control
flow you want in any streaming REPL.

This block drives a fake iterator so it runs without a provider. Swap the fake
for `rt.invoke_stream(...)` in Step 6 and the control flow carries over
unchanged.

```python
class _FakeStream:
    """Mimics invoke_stream's iterator protocol for the interrupt demo."""

    def __init__(self, tokens, interrupt_at=None):
        # interrupt_at: index at which to raise KeyboardInterrupt, or None.
        self._tokens = list(tokens)
        self._interrupt_at = interrupt_at
        self._i = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self._interrupt_at is not None and self._i == self._interrupt_at:
            raise KeyboardInterrupt
        if not self._tokens:
            raise StopIteration
        self._i += 1
        return ("TextDelta", self._tokens.pop(0))


def consume(stream):
    collected = []
    try:
        for kind, payload in stream:
            if kind == "TextDelta":
                collected.append(payload)
    except KeyboardInterrupt:
        # A real Ctrl-C lands here. In a live stream the generator's
        # finally clause (run when the for loop exits) joins the
        # background thread. Print a clean newline and stop; do not
        # re-raise, so the caller sees a clean exit, not a traceback.
        print("[cancelled by user]")
        return collected
    return collected


# A normal run collects every token.
print("normal run:", "".join(consume(_FakeStream(["Hello", ", ", "world"]))))

# An interrupted run: the stream raises KeyboardInterrupt at index 1,
# so consume() traps it and returns the partial buffer cleanly.
print("interrupted:", "".join(consume(_FakeStream(["first", "second", "third"], interrupt_at=1))))
print("interrupt trap works")
```

The takeaways: keep the `try/except KeyboardInterrupt` tight around the loop, do
the cleanup in the generator's `finally`, and never let an exception escape
without closing the iterator. PAR's `invoke_stream` docstring spells out the
v0.5.3 limitation that breaking early leaves the background daemon thread
holding the runtime lock until the LLM stream completes naturally. The
`par_cancel_stream` FFI (shipped in v0.5.4-beta) interrupts in-flight streams
within a chunk interval (~50–300 ms typical); call `reader.cancel()` (or let the
reader fall out of scope) to signal cancellation and release the runtime lock,
rather than relying on a hard break.

## Step 6: Plug in a live stream

Everything above was preparation. This block lights up a real stream. It reads
`OPENAI_API_KEY`, and when present it registers an agent, opens the generator,
and prints each token as it lands. When the key is absent it prints a clear skip
message and exits 0, so the snippet runs cleanly anywhere.

```python
import json
import os
import sys
from par_runtime import Runtime, TextDelta, Done, PARError

api_key = os.environ.get("OPENAI_API_KEY")
if not api_key:
    print("skipped: set OPENAI_API_KEY to run the live stream")
    sys.exit(0)

config = json.dumps({
    "persistence": ["Sqlite", ":memory:"],
    "event_bus": {
        "buffer_capacity": 10,
        "delivery": {
            "max_delivery_attempts": 3,
            "initial_retry_delay": 0.1,
            "retry_backoff": ["Fixed", 0.5],
            "delivery_timeout": 5.0,
        },
        "dlq_enabled": False,
        "critical_event_types": [],
    },
    "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2},
    "shutdown": {"drain_timeout": 3.0, "cancel_grace_period": 1.0, "flush_batch_size": 100},
    "llm_providers": [
        ["default", ["Openai", {
            "api_key": api_key,
            "base_url": None,
            "organization": None,
            "embedding_model": None,
        }]]
    ],
    "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
    "parallel_tool_execution": True,
})

agent = json.dumps({
    "id": "stream_agent",
    "system_prompt": "You are a concise assistant.",
    "model": {"provider": "openai", "model_name": "gpt-4o-mini"},
    "max_iterations": 1,
    "tools": [],
})

with Runtime(config) as rt:
    rt.register_agent(agent)
    try:
        for event in rt.invoke_stream("stream_agent", "Explain structured concurrency in one sentence."):
            if isinstance(event, TextDelta):
                print(event.text, end="", flush=True)
            elif isinstance(event, Done):
                print()  # newline after the final token
    except PARError as exc:
        print("\n[stream failed: %s]" % exc, file=sys.stderr)
    except KeyboardInterrupt:
        print("\n[cancelled by user]", file=sys.stderr)
```

Set the key and run it. The first token arrives within milliseconds of the model
producing it. That is the v0.5.3 incremental delivery model in action: the OCaml
SSE parser fires a callback per chunk, the callback pushes onto a queue, and the
Python iterator drains the queue concurrently. Perceived latency drops from a
blank stare to a steady drip.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Tokens appear all at once, not progressively | Python is buffering stdout. | Add `flush=True` to every `print` inside the loop, as in Step 4. |
| `PARInvokeError` from `next()` | The provider rejected the request, or the agent id is unknown. | Wrap iteration in `try/except PARError`. The error message carries the provider's detail. |
| Stream hangs after an early `break` | v0.5.3 known limitation: the background daemon thread holds the runtime lock until the LLM stream finishes. | Let the stream complete, or run with a provider-level timeout. The `par_cancel_stream` FFI lands in v0.5.4+ to interrupt within a chunk interval. |
| `UsageUpdate` never arrives | You are streaming from OpenAI, which does not emit token counts mid-stream. | Fall back to non-streaming `invoke` for exact usage, or compute usage from the token count you observe. |
| Daemon thread warnings on exit | The runtime's background thread had not finished when the interpreter exited. | Use the `with Runtime(...) as rt:` block so `rt.close()` runs before the process ends. |

## What's next

You can now consume a stream, render it, and shut it down cleanly. Two threads
to pull next.

- Combine streaming with retrieval in [Tutorial 1: RAG Q&A Bot](01-rag-qa-bot.md).
  The grounded-answer call there has a streaming sibling planned for a future
  release; the event vocabulary you just learned carries over unchanged.
- Read the [Streaming API reference](../sdk/streaming.md) for the threading
  model, the three design alternatives PAR considered before settling on the
  generator shape, and the backpressure strategy.

When skills land as a CLI feature, a later tutorial will show a skill that
wraps a streaming tool. It ships after the skill CLI work completes, so the
index above does not link to it yet.
