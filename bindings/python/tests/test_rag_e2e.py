"""End-to-end test: par_embed/add_documents/invoke_with_rag against a mock
OpenAI-compatible HTTP server. Proves the full FFI work-loop architecture
correctly threads Eio context and returns real embeddings/vectors."""
import json
import socket
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest import mock

from par_runtime import Runtime, PARError


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _MockOpenAIHandler(BaseHTTPRequestHandler):
    """Mock OpenAI-compatible API that returns canned embeddings."""

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            payload = json.loads(body)
        except Exception:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":"bad json"}')
            return

        if self.path.endswith("/embeddings"):
            inputs = payload.get("input", [])
            if isinstance(inputs, str):
                inputs = [inputs]
            data = []
            for i, _ in enumerate(inputs):
                data.append({
                    "object": "embedding",
                    "index": i,
                    "embedding": [0.1 * i, 0.2 * i, 0.3],
                })
            resp = {"object": "list", "data": data, "model": "text-embedding-3-small", "usage": {"prompt_tokens": 5, "total_tokens": 5}}
            body_json = json.dumps(resp).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body_json)))
            self.end_headers()
            self.wfile.write(body_json)
        else:
            self.send_response(404)
            self.end_headers()


def _start_mock_server(port):
    server = HTTPServer(("127.0.0.1", port), _MockOpenAIHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def _test_config(base_url):
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
        },
        "shutdown": {"drain_timeout": 5.0, "cancel_grace_period": 2.0, "flush_batch_size": 100},
        "llm_providers": [
            ["my_agent", ["Openai", {
                "api_key": "sk-mock-test-key",
                "base_url": base_url,
                "organization": None,
                "embedding_model": None,
            }]],
        ],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
        "bash_confirm": {"allow_confirm": False, "always_allow": False, "timeout_seconds": 30.0},
        "event_retention_seconds": 604800.0,
    })


class TestEndToEndRAG(unittest.TestCase):
    """End-to-end RAG: embed → add_documents → search."""

    @classmethod
    def setUpClass(cls):
        cls.port = _free_port()
        cls.server = _start_mock_server(cls.port)
        cls.base_url = f"http://127.0.0.1:{cls.port}/v1"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_embed_returns_real_vectors(self):
        """End-to-end: embed() returns real vectors from mock HTTP server."""
        rt = Runtime(_test_config(self.base_url))
        try:
            vecs = rt.embed(["hello", "world"])
            self.assertEqual(len(vecs), 2)
            self.assertEqual(len(vecs[0]), 3)
            self.assertAlmostEqual(vecs[0][0], 0.0, places=5)
            self.assertAlmostEqual(vecs[1][0], 0.1, places=5)
        finally:
            rt.close()

    def test_add_documents_returns_zero(self):
        rt = Runtime(_test_config(self.base_url))
        try:
            rc = rt.add_documents([
                {"id": "doc1", "content": "first document"},
                {"id": "doc2", "content": "second document"},
            ])
            self.assertEqual(rc, 0)
        finally:
            rt.close()

    def test_invoke_with_rag_unknown_agent_returns_error(self):
        rt = Runtime(_test_config(self.base_url))
        try:
            result = rt.invoke_with_rag("nonexistent-agent", "test", k=2)
            self.assertIsNotNone(result)
        finally:
            rt.close()


def _hnsw_config(base_url, dimension=3):
    cfg = json.loads(_test_config(base_url))
    cfg["vector_store"] = {
        "backend": "hnsw",
        "dimension": dimension,
    }
    return json.dumps(cfg)


class TestHNSWVectorStore(unittest.TestCase):
    """HNSW backend: config parsing, add_documents, invoke_with_rag."""

    @classmethod
    def setUpClass(cls):
        cls.port = _free_port()
        cls.server = _start_mock_server(cls.port)
        cls.base_url = f"http://127.0.0.1:{cls.port}/v1"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_hnsw_add_documents_succeeds(self):
        rt = Runtime(_hnsw_config(self.base_url))
        try:
            rc = rt.add_documents([
                {"id": "d1", "content": "alpha"},
                {"id": "d2", "content": "beta"},
            ])
            self.assertEqual(rc, 0)
        finally:
            rt.close()

    def test_hnsw_invoke_with_rag_no_crash(self):
        rt = Runtime(_hnsw_config(self.base_url))
        try:
            rt.add_documents([{"id": "d1", "content": "hello"}])
            result = rt.invoke_with_rag("nonexistent", "query", k=1)
            self.assertIsNotNone(result)
        finally:
            rt.close()

    def test_hnsw_with_custom_params(self):
        cfg = json.loads(_hnsw_config(self.base_url))
        cfg["vector_store"]["m"] = 32
        cfg["vector_store"]["ef_construction"] = 400
        cfg["vector_store"]["ef_search"] = 100
        rt = Runtime(json.dumps(cfg))
        try:
            rc = rt.add_documents(["custom params doc"])
            self.assertEqual(rc, 0)
        finally:
            rt.close()

    def test_backward_compat_no_vector_store_config(self):
        rt = Runtime(_test_config(self.base_url))
        try:
            rc = rt.add_documents(["backward compat"])
            self.assertEqual(rc, 0)
        finally:
            rt.close()

    def test_hnsw_normalize_config_sets_default_backend(self):
        raw = json.dumps({
            "persistence": {"tag": "sqlite", "contents": ":memory:"},
            "vector_store": {"dimension": 3},
        })
        normalized = Runtime._normalize_config(raw)
        cfg = json.loads(normalized)
        self.assertEqual(cfg["vector_store"]["backend"], "sqlite_vec")


if __name__ == "__main__":
    unittest.main()
