import json
import socket
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from par_runtime import Runtime, PARError
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


class _HangingHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        time.sleep(300)
    def log_message(self, *a): pass


class _SlowStreamHandler(BaseHTTPRequestHandler):
    """Send SSE chunks 0.5s apart for 3s total — should NOT trigger idle timeout."""
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        parts = []
        for i in range(6):
            parts.append('data: {"choices":[{"delta":{"content":"%s"}}]}\n\n' % chr(65 + i))
        parts.append('data: [DONE]\n\n')
        full = ''.join(parts).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(full)))
        self.end_headers()
        for part in parts:
            self.wfile.write(part.encode())
            self.wfile.flush()
            time.sleep(0.5)
    def log_message(self, *a): pass


def _config(base_url):
    return json.dumps({
        "persistence": ["Sqlite", ":memory:"],
        "event_bus": {"buffer_capacity": 10, "delivery": {"max_delivery_attempts": 1, "initial_retry_delay": 0.1, "retry_backoff": ["Fixed", 0.5], "delivery_timeout": 5.0}, "dlq_enabled": False, "critical_event_types": []},
        "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2},
        "shutdown": {"drain_timeout": 3.0, "cancel_grace_period": 1.0, "flush_batch_size": 100},
        "llm_providers": [["d", ["Openai", {"api_key": "sk-x", "base_url": base_url, "organization": None, "embedding_model": None}]]],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
        "bash_confirm": {"allow_confirm": False, "always_allow": False, "timeout_seconds": 30.0},
        "event_retention_seconds": 604800.0,
    })


class TestHTTPTimeout(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _lib.par_set_request_timeout(1.0)
        cls.port = _free_port()
        cls.server = HTTPServer(("127.0.0.1", cls.port), _HangingHandler)
        cls.server.timeout = 300
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        _lib.par_set_request_timeout(60.0)

    def test_embed_returns_timeout_error(self):
        rt = Runtime(_config(f"http://127.0.0.1:{self.port}/v1"))
        try:
            with self.assertRaises(PARError) as ctx:
                rt.embed(["hello"])
            self.assertIn("timeout", str(ctx.exception).lower())
        finally:
            rt.close()

    def test_invoke_returns_timeout_error(self):
        rt = Runtime(_config(f"http://127.0.0.1:{self.port}/v1"))
        try:
            rt.register_agent(json.dumps({
                "id": "a", "system_prompt": "test",
                "model": {"provider": "openai", "model_name": "gpt-4"},
                "max_iterations": 1, "tools": []
            }))
            with self.assertRaises(Exception) as ctx:
                rt.invoke("a", "hello " * 200)
            self.assertIn("timeout", str(ctx.exception).lower())
        finally:
            rt.close()

    def test_stream_returns_timeout_error(self):
        rt = Runtime(_config(f"http://127.0.0.1:{self.port}/v1"))
        try:
            rt.register_agent(json.dumps({
                "id": "a", "system_prompt": "test",
                "model": {"provider": "openai", "model_name": "gpt-4"},
                "max_iterations": 1, "tools": []
            }))
            with self.assertRaises(Exception) as ctx:
                list(rt.invoke_stream("a", "hello " * 200))
            self.assertIn("timeout", str(ctx.exception).lower())
        finally:
            rt.close()


class TestStreamIdleTimeout(unittest.TestCase):
    """Verify streaming uses idle timeout (between chunks), not total timeout.
    With 2s timeout: a stream sending chunks 0.5s apart for 3s total must
    survive (idle resets on each chunk), proving it's not a hard total cap."""

    def test_slow_stream_does_not_timeout(self):
        _lib.par_set_request_timeout(2.0)
        server, port = _start_server(_SlowStreamHandler)
        try:
            rt = Runtime(_config(f"http://127.0.0.1:{port}/v1"))
            try:
                rt.register_agent(json.dumps({
                    "id": "a", "system_prompt": "test",
                    "model": {"provider": "openai", "model_name": "gpt-4"},
                    "max_iterations": 1, "tools": []
                }))
                events = list(rt.invoke_stream("a", "hello"))
                self.assertGreater(len(events), 0)
            finally:
                rt.close()
        finally:
            _lib.par_set_request_timeout(60.0)
            server.shutdown()


class TestStreamArchitecture(unittest.TestCase):
    """v0.7.10 regression: verify the new per-handle iterator protocol."""

    @classmethod
    def setUpClass(cls):
        _lib.par_set_request_timeout(1.0)
        cls.port = _free_port()
        cls.server = HTTPServer(("127.0.0.1", cls.port), _HangingHandler)
        cls.server.timeout = 300
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        _lib.par_set_request_timeout(60.0)

    def test_sequential_streams_no_slot_leak(self):
        """a842a7e leaked domain slots; verify 2 sequential streams work."""
        rt = Runtime(_config(f"http://127.0.0.1:{self.port}/v1"))
        try:
            rt.register_agent(json.dumps({
                "id": "a", "system_prompt": "test",
                "model": {"provider": "openai", "model_name": "gpt-4"},
                "max_iterations": 1, "tools": []
            }))
            for i in range(2):
                with self.assertRaises(Exception) as ctx:
                    list(rt.invoke_stream("a", "hello " * 200))
                self.assertIn("timeout", str(ctx.exception).lower(),
                              f"iteration {i}")
        finally:
            rt.close()

    def test_stream_reader_is_iterator(self):
        """invoke_stream returns an iterator with .cancel()."""
        rt = Runtime(_config(f"http://127.0.0.1:{self.port}/v1"))
        try:
            rt.register_agent(json.dumps({
                "id": "a", "system_prompt": "test",
                "model": {"provider": "openai", "model_name": "gpt-4"},
                "max_iterations": 1, "tools": []
            }))
            reader = rt.invoke_stream("a", "hello " * 200)
            self.assertIs(iter(reader), reader)
            self.assertTrue(hasattr(reader, 'cancel'))
            reader.cancel()
            list(reader)
        finally:
            rt.close()
