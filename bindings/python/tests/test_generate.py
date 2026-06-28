"""End-to-end test: Runtime.invoke_generate against a mock OpenAI-compatible
HTTP server. Covers the long-output generation mode (skip ReAct loop, auto-
continue on Max_tokens truncation) through the ctypes FFI."""
import json
import socket
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

from par_runtime import Runtime, PARInvokeError


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _make_chat_completion(content, finish_reason, model="mock"):
    return {
        "id": "chatcmpl-mock",
        "object": "chat.completion",
        "created": 1700000000,
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": finish_reason,
            }
        ],
        "usage": {
            "prompt_tokens": 5,
            "completion_tokens": max(len(content or "") // 4, 1),
            "total_tokens": 5 + max(len(content or "") // 4, 1),
        },
    }


class _MockOpenAIHandler(BaseHTTPRequestHandler):
    """Pops one canned chat.completion per /chat/completions POST.

    Falls back to an empty-Stop response if the queue is exhausted so the
    test fails loudly rather than hanging.
    """

    canned_responses: list = []
    request_log: list = []

    def log_message(self, fmt, *args):
        pass

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

        self.request_log.append({"path": self.path, "body": payload})

        if self.path.endswith("/chat/completions"):
            if _MockOpenAIHandler.canned_responses:
                resp = _MockOpenAIHandler.canned_responses.pop(0)
            else:
                resp = _make_chat_completion("", "stop")
            body_json = json.dumps(resp).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body_json)))
            self.end_headers()
            self.wfile.write(body_json)
        elif self.path.endswith("/embeddings"):
            inputs = payload.get("input", [])
            if isinstance(inputs, str):
                inputs = [inputs]
            data = [
                {"object": "embedding", "index": i, "embedding": [0.0] * 3}
                for i in range(len(inputs))
            ]
            resp = {
                "object": "list",
                "data": data,
                "model": "text-embedding-3-small",
                "usage": {"prompt_tokens": 5, "total_tokens": 5},
            }
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


def _reset_mock():
    _MockOpenAIHandler.canned_responses = []
    _MockOpenAIHandler.request_log = []


def _finish_reason(result):
    """OCaml polymorphic variants serialize as a JSON array via
    ppx_deriving_yojson. Extract the tag string so tests can compare
    against plain string values like 'Stop' or 'Max_tokens'."""
    fr = result.get("finish_reason")
    if isinstance(fr, list) and fr:
        return fr[0]
    return fr


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
        "shutdown": {
            "drain_timeout": 5.0,
            "cancel_grace_period": 2.0,
            "flush_batch_size": 100,
        },
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


def _agent_config(agent_id, base_url, tools=None):
    # agent_config.model is a model_config record (object form with
    # provider/model_name/temperature/etc). The api_key + base_url are
    # owned by the runtime_config.llm_providers entry, not by the agent.
    return json.dumps({
        "id": agent_id,
        "system_prompt": "You are a test agent.",
        "model": {
            "provider": "openai",
            "model_name": "mock-model",
            "temperature": 0.0,
        },
        "tools": tools if tools is not None else [],
    })


class TestInvokeGenerate(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.port = _free_port()
        cls.server = _start_mock_server(cls.port)
        cls.base_url = f"http://127.0.0.1:{cls.port}/v1"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        _reset_mock()

    def test_invoke_generate_basic(self):
        _MockOpenAIHandler.canned_responses = [
            _make_chat_completion("hello world", "stop"),
        ]
        rt = Runtime(_test_config(self.base_url))
        try:
            rt.register_agent(_agent_config("test_agent", self.base_url))
            result = rt.invoke_generate("test_agent", "hi")
            self.assertIsInstance(result, dict)
            self.assertEqual(result["text"], "hello world")
            # OCaml polymorphic variants serialize as JSON arrays via
            # ppx_deriving_yojson, so finish_reason comes back as ["Stop"].
            self.assertEqual(_finish_reason(result), "Stop")
            self.assertEqual(result.get("continuations", 0), 0)
            self.assertEqual(
                sum(
                    1 for r in _MockOpenAIHandler.request_log
                    if r["path"].endswith("/chat/completions")
                ),
                1,
            )
        finally:
            rt.close()

    def test_invoke_generate_auto_continue(self):
        # Content > 500 chars so the diminishing-returns guard does NOT
        # short-circuit and a real Continue chunk is requested.
        long_part = "part1 " + ("x" * 600)
        _MockOpenAIHandler.canned_responses = [
            _make_chat_completion(long_part, "length"),
            _make_chat_completion("part2", "stop"),
        ]
        rt = Runtime(_test_config(self.base_url))
        try:
            rt.register_agent(_agent_config("test_agent", self.base_url))
            result = rt.invoke_generate("test_agent", "hi")
            self.assertIsInstance(result, dict)
            # result.text is the CONCATENATED text across continuations
            # (matches Engine.run_agent's Continue branch behavior).
            self.assertIn("part1", result["text"])
            self.assertIn("part2", result["text"])
            self.assertGreaterEqual(result.get("continuations", 0), 1)
            self.assertEqual(_finish_reason(result), "Stop")
        finally:
            rt.close()

    def test_invoke_generate_unknown_agent(self):
        rt = Runtime(_test_config(self.base_url))
        try:
            with self.assertRaises(PARInvokeError):
                rt.invoke_generate("nonexistent", "hi")
        finally:
            rt.close()

    def test_invoke_generate_agent_with_tools_rejected(self):
        tool_descriptor = {
            "name": "echo",
            "description": "Echo the input",
            "parameters": {"type": "object", "properties": {}},
        }
        rt = Runtime(_test_config(self.base_url))
        try:
            rt.register_agent(
                _agent_config("tool_agent", self.base_url, tools=[tool_descriptor])
            )
            with self.assertRaises(PARInvokeError):
                rt.invoke_generate("tool_agent", "hi")
        finally:
            rt.close()

    def test_invoke_generate_finish_reason_max_tokens_no_continue(self):
        # First response: long Max_tokens (>500 chars) so the
        # diminishing-returns guard does not trigger, prompting a
        # Continue. Second response: short Max_tokens (<500 chars) so
        # the guard fires, terminating the sub-loop with finish_reason
        # = Max_tokens (not a follow-up Stop).
        long_part = "x" * 600
        _MockOpenAIHandler.canned_responses = [
            _make_chat_completion(long_part, "length"),
            _make_chat_completion("y" * 100, "length"),
        ]
        rt = Runtime(_test_config(self.base_url))
        try:
            rt.register_agent(_agent_config("test_agent", self.base_url))
            result = rt.invoke_generate("test_agent", "hi")
            self.assertIsInstance(result, dict)
            self.assertEqual(_finish_reason(result), "Max_tokens")
            self.assertGreaterEqual(result.get("continuations", 0), 1)
        finally:
            rt.close()

    def test_invoke_generate_empty_response_error(self):
        # content=None with finish_reason=length is the empty-initial-
        # response error path; Generate.run must surface it as PARInvokeError.
        _MockOpenAIHandler.canned_responses = [
            _make_chat_completion(None, "length"),
        ]
        rt = Runtime(_test_config(self.base_url))
        try:
            rt.register_agent(_agent_config("test_agent", self.base_url))
            with self.assertRaises(PARInvokeError):
                rt.invoke_generate("test_agent", "hi")
        finally:
            rt.close()


if __name__ == "__main__":
    unittest.main()
