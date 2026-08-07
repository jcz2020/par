"""Shared fixtures for HTTP timeout / streaming test files.

These test classes were originally in test_http_timeout.py but were split
into separate files (test_http_timeout.py, test_stream_idle_timeout.py,
test_stream_architecture.py) because running multiple classes in the same
pytest process hangs: after a streaming timeout, the OCaml runtime's HTTP
fiber cannot be cancelled (Eio/cohttp limitation), and the stuck fiber
interferes with subsequent Runtime instances in the same process. CI's
per-file pytest invocation naturally isolates each file into its own
process, avoiding the issue.
"""

import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


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
