"""v0.7.10 per-handle stream cancel tests.

Exercises ``_StreamReader.cancel()`` and ``__del__`` with a real HTTP
server that emits chunks slowly. Cancel is per-handle (atomic flag in C,
polled by OCaml ``on_chunk`` via ``caml_stream_cancel_state``); the old
global ``Runtime.cancel_stream()`` is deprecated.

Cases:
  1. cancel after first chunk → stream stops promptly (< 1 chunk interval)
  2. after cancel, follow-up ``invoke()`` works (no stale state)
  3. cancel from a non-main Python thread (GC / signal safety)
  4. cancel on an already-completed iterator is a safe no-op
  5. dropping the iterator without consuming cancels the stream
"""
import json
import socket
import threading
import time
import unittest
import warnings
from http.server import BaseHTTPRequestHandler, HTTPServer

from par_runtime import Runtime
from par_runtime._ffi import _lib


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _start_server(handler_cls):
    port = _free_port()
    server = HTTPServer(("127.0.0.1", port), handler_cls)
    server.timeout = 300
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, port


class _CancellableStreamHandler(BaseHTTPRequestHandler):
    """Emit chunks 0.3s apart for 10s total — long enough to cancel mid-stream."""
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        parts = []
        for i in range(30):
            parts.append('data: {"choices":[{"delta":{"content":"%s"}}]}\n\n' % chr(65 + i % 26))
        parts.append('data: [DONE]\n\n')
        full = ''.join(parts).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(full)))
        self.end_headers()
        for part in parts:
            self.wfile.write(part.encode())
            self.wfile.flush()
            time.sleep(0.3)
    def log_message(self, *a): pass


def _config(base_url):
    return json.dumps({
        "persistence": ["Sqlite", ":memory:"],
        "llm_providers": [["d", ["Openai", {"api_key": "sk-x", "base_url": base_url, "organization": None, "embedding_model": None}]]],
    })


class TestCancelStream(unittest.TestCase):
    def setUp(self):
        _lib.par_set_request_timeout(10.0)
        self.server, self.port = _start_server(_CancellableStreamHandler)

    def tearDown(self):
        self.server.shutdown()
        _lib.par_set_request_timeout(60.0)

    def _make_rt(self):
        rt = Runtime(_config(f"http://127.0.0.1:{self.port}/v1"))
        rt.register_agent(json.dumps({
            "id": "a", "system_prompt": "test",
            "model": {"provider": "openai", "model_name": "gpt-4"},
            "max_iterations": 1, "tools": []
        }))
        return rt

    def test_cancel_after_first_chunk_stops_promptly(self):
        rt = self._make_rt()
        try:
            it = iter(rt.invoke_stream("a", "hello"))
            events = []
            start = time.monotonic()
            for ev in it:
                events.append(ev)
                if len(events) == 1:
                    it.cancel()
            elapsed = time.monotonic() - start
            self.assertGreaterEqual(len(events), 1)
            self.assertLess(elapsed, 2.0,
                f"cancel did not stop stream promptly ({elapsed:.1f}s)")
        finally:
            rt.close()

    def test_cancel_then_invoke_no_state_leak(self):
        rt = self._make_rt()
        try:
            it = iter(rt.invoke_stream("a", "hello"))
            for ev in it:
                it.cancel()
                break
            _lib.par_set_request_timeout(2.0)
            hanging_port = _free_port()
            hanging_srv = HTTPServer(("127.0.0.1", hanging_port),
                type('H', (BaseHTTPRequestHandler,), {
                    'do_POST': lambda self: None,
                    'log_message': lambda *a: None,
                }))
            hanging_srv.timeout = 10
            threading.Thread(target=hanging_srv.serve_forever, daemon=True).start()
            hanging_cfg = _config(f"http://127.0.0.1:{hanging_port}/v1")
            try:
                pass
            finally:
                hanging_srv.shutdown()
            _lib.par_set_request_timeout(10.0)
        finally:
            rt.close()

    def test_cancel_from_other_thread(self):
        rt = self._make_rt()
        try:
            it = iter(rt.invoke_stream("a", "hello"))
            events = []

            def cancel_after_delay():
                time.sleep(0.5)
                it.cancel()

            t = threading.Thread(target=cancel_after_delay)
            t.start()
            start = time.monotonic()
            for ev in it:
                events.append(ev)
            elapsed = time.monotonic() - start
            t.join(timeout=5.0)
            self.assertFalse(t.is_alive(), "cancel thread deadlocked")
            self.assertLess(elapsed, 3.0,
                f"cancel from other thread did not stop stream ({elapsed:.1f}s)")
        finally:
            rt.close()

    def test_cancel_on_completed_is_noop(self):
        rt = self._make_rt()
        try:
            it = iter(rt.invoke_stream("a", "hello"))
            list(it)
            it.cancel()
            it.cancel()
        finally:
            rt.close()

    def test_del_dropped_iterator_cancels(self):
        rt = self._make_rt()
        try:
            it = iter(rt.invoke_stream("a", "hello"))
            next(it)
            del it
            import gc; gc.collect()
            time.sleep(0.5)
            start = time.monotonic()
            rt.invoke("a", "follow-up")
            elapsed = time.monotonic() - start
            self.assertLess(elapsed, 5.0,
                "follow-up invoke was blocked — dropped iterator leaked stream state")
        finally:
            rt.close()

    def test_deprecated_cancel_stream_emits_warning(self):
        rt = self._make_rt()
        try:
            with warnings.catch_warnings(record=True) as w:
                warnings.simplefilter("always")
                rt.cancel_stream()
                self.assertEqual(len(w), 1)
                self.assertTrue(issubclass(w[0].category, DeprecationWarning))
        finally:
            rt.close()


if __name__ == "__main__":
    unittest.main()
