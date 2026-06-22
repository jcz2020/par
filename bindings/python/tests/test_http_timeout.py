import json
import os
import socket
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from par_runtime import Runtime, PARError


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _HangingHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        import time; time.sleep(300)
    def log_message(self, *a): pass


def _config(base_url):
    return json.dumps({
        "persistence": ["Sqlite", ":memory:"],
        "event_bus": {"buffer_capacity": 10, "delivery": {"max_delivery_attempts": 3, "initial_retry_delay": 0.1, "retry_backoff": ["Fixed", 0.5], "delivery_timeout": 5.0}, "dlq_enabled": False, "critical_event_types": []},
        "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2},
        "shutdown": {"drain_timeout": 5.0, "cancel_grace_period": 2.0, "flush_batch_size": 100},
        "llm_providers": [["d", ["Openai", {"api_key": "sk-x", "base_url": base_url, "organization": None, "embedding_model": None}]]],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
        "bash_confirm": {"allow_confirm": False, "always_allow": False, "timeout_seconds": 30.0},
        "event_retention_seconds": 604800.0,
    })


@unittest.skipUnless(os.environ.get("PAR_RUN_SLOW_TESTS"), "slow test (60s timeout)")
class TestHTTPTimeout(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port = _free_port()
        cls.server = HTTPServer(("127.0.0.1", cls.port), _HangingHandler)
        cls.server.timeout = 300
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_embed_timeout_returns_error_not_hang(self):
        rt = Runtime(_config(f"http://127.0.0.1:{self.port}/v1"))
        try:
            with self.assertRaises(Exception):
                rt.embed(["hello"])
        finally:
            rt.close()
