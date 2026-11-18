"""AsyncRuntime (v0.18 W1-S3).

Pins the asyncio surface: lazy start, typed invoke through the polling
handle API, streaming through one background pump thread, and cancellation
that reaches the per-stream-handle flag instead of leaking the stream.
"""
import asyncio
import contextlib
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from par_runtime import (
    AgentConfig,
    AsyncRuntime,
    ModelConfig,
    Runtime,
    RuntimeConfig,
    TextDelta,
)

pytestmark = pytest.mark.asyncio

AGENT = AgentConfig(
    id="async",
    system_prompt="You are an async fixture.",
    model=ModelConfig(model_name="async-test", temperature=0.0),
)


def _config(base_url):
    return RuntimeConfig(
        llm_providers=[[
            "d",
            ["Openai", {
                "api_key": "sk-test",
                "base_url": base_url,
                "organization": None,
                "embedding_model": None,
            }],
        ]],
    )


def _start_provider(text="async hello", chunks=("as", "ync"), delay=0.02):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            if payload.get("stream"):
                parts = [
                    'data: {"choices":[{"delta":{"content":"%s"}}]}\n\n' % chunk
                    for chunk in chunks
                ]
                parts.append("data: [DONE]\n\n")
                body = "".join(parts).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                for part in parts:
                    self.wfile.write(part.encode())
                    self.wfile.flush()
                    time.sleep(delay)
                return
            body = json.dumps({
                "model": "async-test",
                "choices": [{
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


async def test_construction_is_lazy_and_close_idempotent():
    runtime = AsyncRuntime(RuntimeConfig())
    assert runtime._sync is None
    await runtime.close()
    await runtime.close()


async def test_async_invoke_returns_a_typed_result():
    server, base_url = _start_provider(chunks=("async hello",))
    try:
        async with AsyncRuntime(_config(base_url)) as rt:
            await rt.register_agent(AGENT)
            result = await rt.invoke("async", "hello")
            assert result.text == "async hello"
            assert result.finish_reason == "stop"
    finally:
        server.shutdown()


async def test_async_stream_yields_text_deltas():
    server, base_url = _start_provider(chunks=("as", "ync"))
    try:
        async with AsyncRuntime(_config(base_url)) as rt:
            await rt.register_agent(AGENT)
            text = ""
            async for event in rt.stream("async", "hello"):
                if isinstance(event, TextDelta):
                    text += event.text
            assert text == "async"
    finally:
        server.shutdown()


@pytest.mark.skipif(
    not os.environ.get("PAR_RUN_FLAKY_TESTS"),
    reason="v0.7.10: per-handle stream cancel is timing-sensitive (native C race)",
)
async def test_cancelling_an_async_stream_stops_promptly():
    server, base_url = _start_provider(
        chunks=tuple(chr(65 + i) for i in range(50)), delay=0.1
    )
    try:
        async with AsyncRuntime(_config(base_url)) as rt:
            await rt.register_agent(AGENT)

            async def consume():
                async for _event in rt.stream("async", "hello"):
                    pass

            task = asyncio.create_task(consume())
            await asyncio.sleep(0.3)
            started = time.monotonic()
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
            assert time.monotonic() - started < 1.0

            # The runtime is still usable: the cancelled stream released its
            # handle instead of poisoning the next call.
            result = await asyncio.wait_for(
                rt.invoke("async", "after cancel"), timeout=10
            )
            assert result.finish_reason in ("stop", "max_tokens", "tool_calls")
    finally:
        server.shutdown()



async def test_cancelling_async_invoke_calls_invoke_cancel(monkeypatch):
    """The task cancellation reaches the C handle without a network round trip."""
    runtime = AsyncRuntime(RuntimeConfig())
    await runtime._ensure()
    try:
        cancelled = []
        monkeypatch.setattr(Runtime, "invoke_start", lambda *a, **k: "7")
        monkeypatch.setattr(
            Runtime, "invoke_poll", lambda *a, **k: {"status": "pending"}
        )
        monkeypatch.setattr(
            Runtime, "invoke_cancel", lambda self, handle: cancelled.append(handle)
        )

        task = asyncio.create_task(runtime.invoke("async", "hello"))
        await asyncio.sleep(0.05)
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        assert cancelled == ["7"]
    finally:
        await runtime.close()


class _FakeReader:
    def __init__(self, texts):
        self._events = [TextDelta(text=t) for t in texts]
        self.closed = False

    @property
    def is_done(self):
        return not self._events

    def poll_chunk(self, timeout_ms=0):
        return self._events.pop(0) if self._events else None

    def close(self):
        self.closed = True


async def test_async_stream_drives_the_reader_without_a_worker_thread(monkeypatch):
    runtime = AsyncRuntime(RuntimeConfig())
    await runtime._ensure()
    reader = _FakeReader(["a", "b", "c"])
    monkeypatch.setattr(Runtime, "invoke_stream", lambda *a, **k: reader)
    try:
        seen = []
        async for event in runtime.stream("async", "hello"):
            seen.append(event.text)
        assert seen == ["a", "b", "c"]
        assert reader.closed
    finally:
        await runtime.close()
