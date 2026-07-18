"""Tests for Runtime.invoke_structured Python binding."""

import json
import os
import socket
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from par_runtime import Runtime, PARError, PARInvokeError


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


def _make_tool_call_response(tool_name, arguments, model="mock"):
    """Create an OpenAI chat completion response with tool_calls."""
    return {
        "id": "chatcmpl-mock",
        "object": "chat.completion",
        "created": 1700000000,
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [
                        {
                            "id": "call_mock_1",
                            "type": "function",
                            "function": {
                                "name": tool_name,
                                "arguments": arguments,
                            },
                        }
                    ],
                },
                "finish_reason": "tool_calls",
            }
        ],
        "usage": {
            "prompt_tokens": 5,
            "completion_tokens": 10,
            "total_tokens": 15,
        },
    }


class _MockOpenAIHandler(BaseHTTPRequestHandler):
    """Pops one canned chat.completion per /chat/completions POST."""

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


def _test_config_with_provider(base_url):
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
            ["tool_agent", ["Openai", {
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


class TestInvokeStructured(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime(_test_config())

    def tearDown(self):
        self.rt.close()

    def test_invoke_structured_signature_exists(self):
        self.assertTrue(callable(getattr(self.rt, "invoke_structured", None)))

    def test_invoke_structured_unknown_agent(self):
        schema = {"type": "object", "properties": {"name": {"type": "string"}}}
        with self.assertRaises(PARInvokeError):
            self.rt.invoke_structured("nonexistent-agent", "hello", schema)


class TestInvokeStructuredWithTools(unittest.TestCase):
    """invoke_structured on an agent that has tools — exercises the two-phase
    path: Phase 1 (ReAct loop with tool execution) → Phase 2 (structured JSON)."""

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

    def test_invoke_structured_tool_then_structured_json(self):
        """Two-phase flow: LLM requests a tool call, tool executes, then LLM
        returns structured JSON matching the response schema."""
        # Phase 1 response 1: LLM asks to use the echo tool
        tool_response = _make_tool_call_response(
            "echo", '{"input": "hello"}',
        )
        # Phase 1 response 2: LLM returns normal text (ends ReAct loop)
        phase1_done = _make_chat_completion(
            "I echoed the input.", "stop",
        )
        # Phase 2 response: LLM returns structured JSON
        structured_response = _make_chat_completion(
            '{"echoed": "hello"}', "stop",
        )

        _MockOpenAIHandler.canned_responses = [tool_response, phase1_done, structured_response]

        rt = Runtime(_test_config_with_provider(self.base_url))
        try:
            # Track whether the tool handler was actually invoked
            tool_called = {"count": 0, "last_input": None}

            def echo_handler(input_json: str) -> str:
                tool_called["count"] += 1
                tool_called["last_input"] = input_json
                return input_json

            rt.register_tool_with_handler(
                "echo",
                "Echo the input back",
                json.dumps({
                    "type": "object",
                    "properties": {"input": {"type": "string"}},
                    "required": ["input"],
                }),
                echo_handler,
            )

            tool_descriptor = {
                "name": "echo",
                "description": "Echo the input back",
                "parameters": {
                    "type": "object",
                    "properties": {"input": {"type": "string"}},
                    "required": ["input"],
                },
            }
            rt.register_agent(
                _agent_config("tool_agent", self.base_url, tools=[tool_descriptor])
            )

            schema = {
                "type": "object",
                "properties": {"echoed": {"type": "string"}},
                "required": ["echoed"],
            }
            result = rt.invoke_structured("tool_agent", "echo hello", schema)

            # (a) The echo tool handler was actually called
            self.assertGreater(tool_called["count"], 0,
                               "Echo tool handler was never invoked")

            # (b) invoke_structured returned a result
            self.assertIsNotNone(result)
            self.assertIsInstance(result, dict)

            # (c) The returned JSON matches the schema (has "echoed" field)
            self.assertIn("echoed", result)
            self.assertEqual(result["echoed"], "hello")

            chat_requests = [
                r for r in _MockOpenAIHandler.request_log
                if r["path"].endswith("/chat/completions")
            ]
            self.assertGreaterEqual(len(chat_requests), 2,
                                    "Expected at least 2 LLM calls "
                                    "(tool call + structured output)")
        finally:
            rt.close()

    def test_invoke_structured_multiple_tool_rounds(self):
        """Two-phase flow where the ReAct loop executes two tool calls before
        the final structured output."""
        # Phase 1a: first tool call
        tool_resp_1 = _make_tool_call_response("echo", '{"input": "first"}')
        # Phase 1b: second tool call
        tool_resp_2 = _make_tool_call_response("echo", '{"input": "second"}')
        # Phase 1c: normal text response to end ReAct loop
        phase1_done = _make_chat_completion("Done echoing.", "stop")
        # Phase 2: structured JSON
        structured_resp = _make_chat_completion(
            '{"echoed": "first and second"}', "stop",
        )

        _MockOpenAIHandler.canned_responses = [tool_resp_1, tool_resp_2, phase1_done, structured_resp]

        rt = Runtime(_test_config_with_provider(self.base_url))
        try:
            tool_call_count = {"n": 0}

            def echo_handler(input_json: str) -> str:
                tool_call_count["n"] += 1
                data = json.loads(input_json)
                return json.dumps({"result": data.get("input", "")})

            rt.register_tool_with_handler(
                "echo",
                "Echo the input",
                json.dumps({"type": "object"}),
                echo_handler,
            )

            tool_descriptor = {
                "name": "echo",
                "description": "Echo the input",
                "parameters": {"type": "object"},
            }
            rt.register_agent(
                _agent_config("tool_agent", self.base_url, tools=[tool_descriptor])
            )

            schema = {
                "type": "object",
                "properties": {"echoed": {"type": "string"}},
                "required": ["echoed"],
            }
            result = rt.invoke_structured("tool_agent", "do it twice", schema)

            self.assertEqual(tool_call_count["n"], 2,
                             "Echo tool should have been called exactly twice")
            self.assertIsInstance(result, dict)
            self.assertIn("echoed", result)
        finally:
            rt.close()


if __name__ == "__main__":
    unittest.main()
