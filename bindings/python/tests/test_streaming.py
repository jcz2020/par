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


def _stub_invoke_stream(chunks):
    def fake(rt_handle, agent_id_b, message_b, cb, user_data):
        chunk_items = [{"chunk": json.loads(c) if isinstance(c, str) else c} for c in chunks]
        return json.dumps({"status": "ok", "chunks": chunk_items})
    return fake


def _mock_par_invoke_stream(resp_json):
    from contextlib import contextmanager
    @contextmanager
    def ctx():
        with mock.patch("par_runtime.runtime._lib") as lib, \
             mock.patch("par_runtime.runtime._py_str", return_value=resp_json):
            lib.par_invoke_stream.return_value = 1
            yield lib
    return ctx()


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
    rt = Runtime(_test_config())
    try:
        resp = json.dumps({"status": "ok", "chunks": [
            {"chunk": ["Text_delta", {"text": "x"}]},
            {"chunk": ["Done", {"finish_reason": ["Stop"]}]},
        ]})
        with _mock_par_invoke_stream(resp):
            it = rt.invoke_stream("any-agent", "hi")
            assert hasattr(it, "__next__")
            events = list(it)
        assert len(events) == 2
        assert isinstance(events[0], TextDelta)
        assert isinstance(events[1], Done)
    finally:
        rt.close()


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
    resp = json.dumps({"status": "ok", "chunks": [
        {"chunk": json.loads(c)} for c in chunks
    ]})
    with _mock_par_invoke_stream(resp):
        reader = _StreamReader(rt_handle=object(), agent_id="a", message="m")
        events = list(iter(reader))
    assert len(events) == 3
    assert isinstance(events[0], TextDelta) and events[0].text == "hello "
    assert isinstance(events[1], TextDelta) and events[1].text == "world"
    assert isinstance(events[2], Done) and events[2].finish_reason == "stop"


def test_stream_reader_completes_on_done():
    resp = json.dumps({"status": "ok", "chunks": [
        {"chunk": ["Done", {"finish_reason": ["Stop"]}]}
    ]})
    with _mock_par_invoke_stream(resp):
        reader = _StreamReader(object(), "a", "m")
        it = iter(reader)
        first = next(it)
        assert isinstance(first, Done)
        with pytest.raises(StopIteration):
            next(it)


def test_stream_reader_surfaces_callback_exception_as_invoke_error():
    with _mock_par_invoke_stream("not valid json {{{"):
        reader = _StreamReader(object(), "a", "m")
        with pytest.raises(json.JSONDecodeError):
            list(iter(reader))


def test_stream_reader_handles_large_chunk_list():
    n = 128
    chunk_items = [{"chunk": ["Text_delta", {"text": str(i)}]} for i in range(n)]
    chunk_items.append({"chunk": ["Done", {"finish_reason": ["Stop"]}]})
    resp = json.dumps({"status": "ok", "chunks": chunk_items})
    with _mock_par_invoke_stream(resp):
        reader = _StreamReader(object(), "a", "m")
        events = list(iter(reader))
    assert len(events) == n + 1
    assert all(isinstance(e, TextDelta) for e in events[:n])
    assert isinstance(events[-1], Done)


def test_stream_reader_ffi_error_propagates():
    def ffi_boom(*a, **kw):
        raise OSError("ffi blew up")
    with mock.patch("par_runtime.runtime._lib") as fake_lib:
        fake_lib.par_invoke_stream.side_effect = ffi_boom
        reader = _StreamReader(object(), "a", "m")
        with pytest.raises(OSError):
            list(iter(reader))


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
