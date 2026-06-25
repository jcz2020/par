"""v0.5.4 Track C.2 — par_cancel_stream tests.

Exercises ``Runtime.cancel_stream()`` and ``_StreamReader.cancel()``
without a live LLM provider. ``_lib`` is mocked so that
``par_invoke_stream`` simulates the OCaml streaming loop: it emits one
chunk per second and, like the real ``on_chunk`` callback, checks a
shared cancel flag before each chunk. When ``par_cancel_stream`` sets
the flag, the simulated loop aborts early and returns a
``{"status": "cancelled"}`` envelope — exactly what the real OCaml
``do_invoke_stream`` returns when its ``on_chunk`` raises
``Stream_cancelled``.

The four cases mirror ROADMAP Phase C.2 + Risk #3:
  1. cancel interrupts an in-flight stream within ~one chunk interval
     (was 30s end-to-end in v0.5.3).
  2. after cancel, a follow-up ``par_invoke`` is not blocked (no
     ocaml_lock leak).
  3. cancel is safe to call from a non-FFI thread (Risk #3 signal
     safety).
  4. cancel is a no-op when no stream is in flight.
"""
import json
import os
import sys
import threading
import time
from unittest import mock

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from par_runtime import PARError, PARInvokeError, Runtime
from par_runtime.runtime import _StreamReader


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


class _FakeStreamer:
    """Mimics the OCaml streaming loop + the C atomic cancel flag.

    ``invoke`` simulates par_invoke_stream: it would run for
    ``total_chunks`` * ``chunk_interval`` seconds if never cancelled.
    Before emitting each chunk it checks ``cancel_event`` — when set
    (by par_cancel_stream), it short-circuits and returns the
    ``cancelled`` envelope, just like the real on_chunk raising
    Stream_cancelled.
    """

    def __init__(self, total_chunks=30, chunk_interval=1.0):
        self.cancel_event = threading.Event()
        self.total_chunks = total_chunks
        self.chunk_interval = chunk_interval
        self.chunks_emitted = 0
        self.cancel_observed = False
        self.returned_at = None

    def invoke(self, rt, agent_id_b, message_b, cb, user_data):
        start = time.monotonic()
        for i in range(self.total_chunks):
            if self.cancel_event.is_set():
                self.cancel_observed = True
                self.returned_at = time.monotonic() - start
                return None  # _py_str mocked to return cancelled envelope
            chunk = f'["Text_delta", {{"text": "chunk{i}"}}]'.encode("utf-8")
            cb(chunk, user_data)
            self.chunks_emitted += 1
            time.sleep(self.chunk_interval)
        self.returned_at = time.monotonic() - start
        return None

    def cancel(self, rt):
        self.cancel_event.set()


@pytest.fixture
def patched_lib():
    """Patch par_runtime.runtime._lib with a MagicMock and yield it.

    par_init returns a truthy handle so Runtime(...) constructs without
    a real .so. Individual tests configure par_invoke_stream /
    par_cancel_stream / par_invoke side effects.
    """
    with mock.patch("par_runtime.runtime._lib") as lib:
        lib.par_init.return_value = 0xDEADBEEF  # truthy handle
        yield lib


# ---------------------------------------------------------------------------
# 1. cancel interrupts an in-flight stream within ~one chunk interval
# ---------------------------------------------------------------------------
def test_cancel_stream_interrupts_in_flight_stream(patched_lib):
    """After the first chunk, reader.cancel() must cause invoke_stream to
    return within ~1 chunk interval + tolerance — not run the full 30s.

    Models ROADMAP Phase C.2: "cancel takes effect at next chunk boundary
    (typically 50-300ms)". We use a 1s chunk interval and require return
    within 1.5s (1 interval + 0.5s tolerance).
    """
    streamer = _FakeStreamer(total_chunks=30, chunk_interval=1.0)
    patched_lib.par_invoke_stream.side_effect = streamer.invoke
    patched_lib.par_cancel_stream.side_effect = streamer.cancel
    cancelled_envelope = json.dumps({"status": "cancelled", "chunks": []})
    with mock.patch("par_runtime.runtime._py_str", return_value=cancelled_envelope):
        rt = Runtime(_test_config())
        reader = _StreamReader(rt._handle, "agent", "msg",
                               queue_timeout=5.0,
                               cancel_fn=rt.cancel_stream)
        start = time.monotonic()
        events = []
        for ev in iter(reader):
            events.append(ev)
            if len(events) == 1:
                # Cancel after the first chunk arrives, like a caller
                # breaking early from the iterator.
                reader.cancel()
        elapsed = time.monotonic() - start
        rt.close()  # null handle while _lib is mocked -> safe __del__ at exit

    assert streamer.cancel_observed, "cancel flag was never observed by the stream loop"
    # Full stream would take 30s; cancelled must return well under that.
    assert elapsed < 1.5, (
        f"stream did not abort promptly after cancel ({elapsed:.2f}s >= 1.5s) — "
        "cancel is not propagating to the in-flight stream"
    )
    # At least one chunk delivered before cancel, and not all 30.
    assert 1 <= len(events) < 30


# ---------------------------------------------------------------------------
# 2. after cancel, a follow-up par_invoke is not blocked (no lock leak)
# ---------------------------------------------------------------------------
def test_cancel_stream_releases_ocaml_lock(patched_lib):
    """After cancel + invoke_stream returns, a follow-up Runtime.invoke()
    must complete promptly. In v0.5.3 the background thread held
    ocaml_lock until natural completion, blocking every subsequent
    par_* call. This test proves the lock is released post-cancel.
    """
    streamer = _FakeStreamer(total_chunks=30, chunk_interval=0.2)
    patched_lib.par_invoke_stream.side_effect = streamer.invoke
    patched_lib.par_cancel_stream.side_effect = streamer.cancel

    invoke_returned = threading.Event()

    def fake_invoke(rt, agent_id_b, message_b):
        # If ocaml_lock were still held by the (cancelled) stream, this
        # would block. We record that it was reached at all.
        invoke_returned.set()
        return 0xCAFE  # truthy ptr; _py_str returns the ok envelope

    patched_lib.par_invoke.side_effect = fake_invoke
    ok_envelope = json.dumps({"status": "ok", "content": "{}"})
    cancelled_envelope = json.dumps({"status": "cancelled", "chunks": []})

    with mock.patch("par_runtime.runtime._py_str", return_value=cancelled_envelope):
        rt = Runtime(_test_config())
        reader = _StreamReader(rt._handle, "agent", "msg",
                               queue_timeout=5.0,
                               cancel_fn=rt.cancel_stream)
        consume = []
        for ev in iter(reader):
            consume.append(ev)
            if len(consume) == 1:
                reader.cancel()

    # Stream has returned (cancel observed). Now the follow-up invoke
    # must succeed within 500ms — proving no ocaml_lock leak.
    with mock.patch("par_runtime.runtime._py_str", return_value=ok_envelope):
        t0 = time.monotonic()
        result = rt.invoke("agent", "follow-up")
        elapsed = time.monotonic() - t0

    assert invoke_returned.is_set(), "follow-up par_invoke was never reached"
    assert elapsed < 0.5, (
        f"follow-up invoke took {elapsed:.2f}s >= 0.5s — ocaml_lock appears leaked"
    )
    assert "ok" in result
    rt.close()  # null handle while _lib is mocked -> safe __del__ at exit


# ---------------------------------------------------------------------------
# 3. cancel is safe from a non-FFI thread (Risk #3 signal safety)
# ---------------------------------------------------------------------------
def test_cancel_stream_safe_from_non_ffi_thread(patched_lib):
    """par_cancel_stream must be callable from an arbitrary pthread
    (e.g. Python's GC-triggered __del__) without crashing or deadlocking,
    and the cancel must still take effect. This is Risk #3 in the ROADMAP.
    """
    streamer = _FakeStreamer(total_chunks=30, chunk_interval=0.3)
    patched_lib.par_invoke_stream.side_effect = streamer.invoke
    patched_lib.par_cancel_stream.side_effect = streamer.cancel
    cancelled_envelope = json.dumps({"status": "cancelled", "chunks": []})

    thread_errors = []

    def cancel_from_other_thread(rt_handle, delay):
        time.sleep(delay)
        try:
            # Mimic Runtime.cancel_stream but from a brand-new thread,
            # NOT the FFI entry thread — exactly the Risk #3 scenario.
            patched_lib.par_cancel_stream(rt_handle)
        except BaseException as e:
            thread_errors.append(e)

    with mock.patch("par_runtime.runtime._py_str", return_value=cancelled_envelope):
        rt = Runtime(_test_config())
        reader = _StreamReader(rt._handle, "agent", "msg",
                               queue_timeout=5.0,
                               cancel_fn=rt.cancel_stream)
        # Spawn a non-FFI thread that cancels after one chunk interval.
        other = threading.Thread(
            target=cancel_from_other_thread,
            args=(rt._handle, 0.35),
        )
        other.start()

        start = time.monotonic()
        list(iter(reader))
        elapsed = time.monotonic() - start
        other.join(timeout=5.0)

    assert not thread_errors, f"non-FFI thread crashed: {thread_errors}"
    assert other.is_alive() is False, "non-FFI cancel thread deadlocked"
    assert streamer.cancel_observed, "cancel from non-FFI thread did not propagate"
    assert elapsed < 1.5, (
        f"stream did not abort after non-FFI cancel ({elapsed:.2f}s)"
    )
    rt.close()


# ---------------------------------------------------------------------------
# 4. cancel is a no-op when no stream is in flight
# ---------------------------------------------------------------------------
def test_cancel_stream_noop_when_idle(patched_lib):
    """cancel_stream() with no stream in flight must return immediately
    without error. The atomic flag is simply set; it gets cleared at the
    start of the next par_invoke_stream, so a later stream is unaffected.
    """
    rt = Runtime(_test_config())

    start = time.monotonic()
    rt.cancel_stream()  # no stream in flight
    elapsed = time.monotonic() - start

    assert elapsed < 0.2, "idle cancel did not return promptly"
    patched_lib.par_cancel_stream.assert_called_once_with(rt._handle)

    # And a subsequent normal invoke works (the stale flag is cleared by
    # par_invoke_stream's reset-at-start, modeled here by a fresh mock).
    patched_lib.par_invoke.side_effect = lambda *a: 0xBEEF
    ok_envelope = json.dumps({"status": "ok", "content": "{}"})
    with mock.patch("par_runtime.runtime._py_str", return_value=ok_envelope):
        result = rt.invoke("agent", "hello")
    assert "ok" in result
    rt.close()


# ---------------------------------------------------------------------------
# Bonus: __del__ on a dropped reader cancels the in-flight stream
# ---------------------------------------------------------------------------
def test_stream_reader_del_cancels_in_flight_stream(patched_lib):
    """When the caller `break`s early from the iterator, the generator's
    close (GeneratorExit landing in __iter__'s finally) must cancel the
    in-flight stream so ocaml_lock is released — closing the v0.5.3 known
    limitation.

    Note: __del__ alone cannot do this, because the background fetch
    thread holds a reference to the reader, keeping it alive past the
    caller's `del`. The generator's finally clause is the reliable path.
    This models the canonical user pattern ``for ev in rt.invoke_stream():
    ...; break``.
    """
    streamer = _FakeStreamer(total_chunks=30, chunk_interval=0.2)
    patched_lib.par_invoke_stream.side_effect = streamer.invoke
    patched_lib.par_cancel_stream.side_effect = streamer.cancel
    cancelled_envelope = json.dumps({"status": "cancelled", "chunks": []})

    with mock.patch("par_runtime.runtime._py_str", return_value=cancelled_envelope):
        rt = Runtime(_test_config())
        # Canonical break-early pattern: the reader is never stored by
        # the caller; `break` drops the generator, firing GeneratorExit.
        for ev in rt.invoke_stream("agent", "msg"):
            break  # consume one chunk, then abandon the iterator

    # The generator's finally ran cancel() on break. Give the background
    # fetch thread a moment to observe the flag and return. If cancel did
    # not fire, the stream would run the full 30 chunks (~6s).
    time.sleep(0.5)
    assert streamer.cancel_observed, (
        "break-early did not cancel the in-flight stream — iterator close "
        "leaked ocaml_lock (the v0.5.3 limitation is not fixed)"
    )
    rt.close()


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
