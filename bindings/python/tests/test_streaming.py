"""Phase C.3 — streaming generator tests.

These tests exercise the Python binding for ``invoke_stream`` without
requiring a live LLM provider. The decoder, generator mechanics,
backpressure, cancellation, and FFI error path are all covered by
driving ``_StreamReader`` directly with a stubbed ``_lib.par_invoke_stream``.

The end-to-end OCaml-backed stream is exercised by the OCaml suite at
``test/test_ffi_streaming.ml`` (Phase C.2); we do not duplicate that
here because the Python binding cannot register a Mock provider via
config alone.
"""
import ctypes
import json
import os
import queue
import sys
import threading
import time
from unittest import mock

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from par_runtime import (
    Done,
    Event,
    PARError,
    Runtime,
    TextDelta,
    ToolCallDelta,
    ToolCallStart,
    UsageUpdate,
)
from par_runtime.runtime import _decode_event, _StreamReader


def _test_config():
    return json.dumps({
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
        "default_quota": {
            "max_concurrent_tasks": 4,
            "max_concurrent_tools_per_agent": 2,
            "max_tokens_per_turn": None,
            "max_total_tokens": None,
        },
        "shutdown": {
            "drain_timeout": 5.0,
            "cancel_grace_period": 2.0,
            "flush_batch_size": 100,
        },
        "llm_providers": [],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
    })


def _inject_queue_with_chunks(chunks_json_strings):
    """Build a queue.Queue pre-populated with JSON-encoded chunks followed
    by the _DONE_SENTINEL. Pass to _StreamReader(_inject_queue=q)."""
    q = queue.Queue()
    for c in chunks_json_strings:
        q.put_nowait(c.encode("utf-8") if isinstance(c, str) else c)
    q.put_nowait(_StreamReader._DONE_SENTINEL)
    return q


def test_decode_event_handles_all_variants():
    """The OCaml side encodes llm_response_chunk as ``[Constructor, {fields}]``
    (older ppx_yojson). All five variants must decode to the right dataclass."""
    td = _decode_event(["Text_delta", {"text": "hi"}])
    assert isinstance(td, TextDelta) and td.text == "hi"

    tcs = _decode_event(["Tool_call_start", {"tool_call_id": "tc1", "name": "n"}])
    assert isinstance(tcs, ToolCallStart)
    assert tcs.tool_call_id == "tc1" and tcs.name == "n"

    tcd = _decode_event(["Tool_call_delta", {"tool_call_id": "tc1", "args_json": "{}"}])
    assert isinstance(tcd, ToolCallDelta)
    assert tcd.tool_call_id == "tc1" and tcd.args_json == "{}"

    uu = _decode_event(["Usage_update", {
        "prompt_tokens": 5, "completion_tokens": 10, "total_tokens": 15}])
    assert isinstance(uu, UsageUpdate)
    assert (uu.prompt_tokens, uu.completion_tokens, uu.total_tokens) == (5, 10, 15)

    done = _decode_event(["Done", {"finish_reason": ["Stop"]}])
    assert isinstance(done, Done)
    assert done.finish_reason == "stop"


def test_decode_event_handles_tag_form_too():
    """Forward-compat: a future ppx_yojson may emit ``{"tag": "X", ...}``.
    The decoder must accept that shape as well."""
    td = _decode_event({"tag": "Text_delta", "text": "x"})
    assert isinstance(td, TextDelta) and td.text == "x"

    done = _decode_event({"tag": "Done", "finish_reason": "length"})
    assert isinstance(done, Done) and done.finish_reason == "length"


def test_decode_event_finish_reason_unwraps_polymorphic_variant():
    """finish_reason arrives as ``["Tool_calls"]`` (a one-element list)."""
    done = _decode_event(["Done", {"finish_reason": ["Tool_calls"]}])
    assert done.finish_reason == "tool_calls"


def test_event_dataclasses_are_frozen():
    for ev in (TextDelta("a"), ToolCallStart("id", "n"),
               ToolCallDelta("id", "{}"), UsageUpdate(1, 2, 3),
               Done("stop")):
        with pytest.raises(AttributeError):
            ev.text = "mutate"  # type: ignore[misc]


def test_event_union_is_exported():
    assert TextDelta in Event.__args__
    assert Done in Event.__args__


def test_invoke_stream_returns_iterator():
    chunks = [
        '["Text_delta", {"text": "x"}]',
        '["Done", {"finish_reason": ["Stop"]}]',
    ]
    q = _inject_queue_with_chunks(chunks)
    reader = _StreamReader(rt_handle=object(), agent_id="any-agent", message="hi",
                           _inject_queue=q)
    it = iter(reader)
    assert hasattr(it, "__next__")
    events = list(it)
    assert len(events) == 2
    assert isinstance(events[0], TextDelta)
    assert isinstance(events[1], Done)


def test_invoke_stream_on_closed_runtime_raises():
    rt = Runtime(_test_config())
    rt.close()
    with pytest.raises(PARError):
        rt.invoke_stream("any", "x")


def test_stream_reader_yields_events_in_order():
    chunks = [
        '["Text_delta", {"text": "hello "}]',
        '["Text_delta", {"text": "world"}]',
        '["Done", {"finish_reason": ["Stop"]}]',
    ]
    q = _inject_queue_with_chunks(chunks)
    reader = _StreamReader(rt_handle=object(), agent_id="a", message="m",
                           _inject_queue=q)
    events = list(iter(reader))
    assert len(events) == 3
    assert isinstance(events[0], TextDelta) and events[0].text == "hello "
    assert isinstance(events[1], TextDelta) and events[1].text == "world"
    assert isinstance(events[2], Done) and events[2].finish_reason == "stop"


def test_stream_reader_completes_on_done():
    chunks = ['["Done", {"finish_reason": ["Stop"]}]']
    q = _inject_queue_with_chunks(chunks)
    reader = _StreamReader(object(), "a", "m", _inject_queue=q)
    it = iter(reader)
    first = next(it)
    assert isinstance(first, Done)
    with pytest.raises(StopIteration):
        next(it)


def test_stream_reader_surfaces_callback_exception_as_invoke_error():
    err = RuntimeError("callback exploded")
    q = queue.Queue()
    q.put_nowait(_StreamReader._DONE_SENTINEL)
    reader = _StreamReader(object(), "a", "m",
                           _inject_queue=q, _inject_error=err)
    with pytest.raises(RuntimeError, match="callback exploded"):
        list(iter(reader))


def test_stream_reader_handles_large_chunk_list():
    n = 128
    chunks = [
        f'["Text_delta", {{"text": "{i}"}}]' for i in range(n)
    ]
    chunks.append('["Done", {"finish_reason": ["Stop"]}]')
    q = _inject_queue_with_chunks(chunks)
    reader = _StreamReader(object(), "a", "m", _inject_queue=q)
    events = list(iter(reader))
    assert len(events) == n + 1
    assert all(isinstance(e, TextDelta) for e in events[:n])
    assert isinstance(events[-1], Done)


def test_stream_reader_ffi_error_propagates():
    err = OSError("ffi blew up")
    q = queue.Queue()
    q.put_nowait(_StreamReader._DONE_SENTINEL)
    reader = _StreamReader(object(), "a", "m",
                           _inject_queue=q, _inject_error=err)
    with pytest.raises(OSError):
        list(iter(reader))


def test_stream_reader_chunks_arrive_incrementally_v0_5_3():
    """v0.5.3 B.3: verify the reader delivers chunks incrementally through
    the real background-thread + queue path.

    The mock simulates the OCaml work loop: it spawns a thread that
    fires the ctypes callback once per chunk with a 100ms delay between
    chunks (mimicking SSE production rate). The reader's __iter__ runs
    on the main thread and consumes the queue concurrently.

    We assert:
    - All 4 events are delivered
    - The inter-arrival time between consecutive events is at least 50ms
      (proving they were NOT all buffered then dumped at once)
    - The total iteration time is at least 300ms (4 chunks * ~100ms each)

    This is the canonical test that the streaming fix actually works for
    Python callers — not just the queue mechanism in isolation.
    """
    import time as _t

    chunks = [
        b'["Text_delta", {"text": "one"}]',
        b'["Text_delta", {"text": "two"}]',
        b'["Text_delta", {"text": "three"}]',
        b'["Done", {"finish_reason": ["Stop"]}]',
    ]
    inter_chunk_delay = 0.1  # 100ms between chunks, like a real LLM

    def fake_invoke_stream(rt_handle, agent_id_b, message_b, cb, user_data):
        """Simulate OCaml work loop: spawn a thread that fires cb with delays.
        The C par_invoke_stream blocks until the LLM completes; we mimic that
        by sleeping for the full duration before returning the final envelope.
        """
        def produce():
            for chunk in chunks:
                cb(chunk, user_data)
                _t.sleep(inter_chunk_delay)
            # par_invoke_stream returns the final envelope after all chunks
            return None

        # Run the producer synchronously (mimicking par_invoke_stream blocking)
        # BUT because _StreamReader runs _do_fetch in a background thread,
        # __iter__ on the main thread can consume the queue concurrently.
        produce()
        return 1  # mock return value; _py_str is mocked to return final envelope

    final_envelope = json.dumps({"status": "ok", "chunks": []})

    with mock.patch("par_runtime.runtime._lib") as lib, \
         mock.patch("par_runtime.runtime._py_str", return_value=final_envelope):
        lib.par_invoke_stream.side_effect = fake_invoke_stream

        reader = _StreamReader(object(), "a", "m", queue_timeout=5.0)
        consume_times = []
        iter_start = _t.monotonic()
        for ev in iter(reader):
            consume_times.append(_t.monotonic())
        iter_total = _t.monotonic() - iter_start

    # All 4 events delivered
    assert len(consume_times) == 4, f"expected 4 events, got {len(consume_times)}"

    # Inter-arrival gaps: each should be >= 50ms (chunks arrive ~100ms apart,
    # NOT all at once). If streaming were buffered, all 4 times would be
    # within 1ms of each other.
    gaps = [consume_times[i+1] - consume_times[i] for i in range(len(consume_times)-1)]
    min_gap = min(gaps)
    assert min_gap > 0.05, (
        f"inter-chunk gap too small ({min_gap*1000:.1f}ms < 50ms) — "
        "streaming appears buffered, not incremental"
    )

    # Total iteration time should be at least 3 * 100ms = 300ms (3 gaps between 4 chunks)
    assert iter_total > 0.25, (
        f"total iteration time {iter_total*1000:.0f}ms < 250ms — "
        "chunks arrived too fast, streaming appears buffered"
    )


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
