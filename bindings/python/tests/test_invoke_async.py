"""Wave 3: Python invoke async trio tests (invoke_start / invoke_poll / invoke_cancel).

Tests the lifecycle shape of the async invoke API. Since no LLM provider
is configured, invoke_start enqueues work that fails immediately — poll
returns an error/done status quickly. This verifies the handle registry,
poll/cancel mechanics, and JSON envelope parsing without needing real LLM keys.

LIMITATION: Cannot test a hanging invoke (mid-ReAct-loop cancel) without a
mock LLM provider that blocks. The OCaml test suite covers the on_chunk
cancel mechanism. These tests verify the Python-side lifecycle shape.
"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from par_runtime import Runtime, PARError, PARInvokeError
from par_runtime._ffi import _lib


def _test_config():
    return json.dumps({
        "persistence": ["Sqlite", ":memory:"],
        "llm_providers": [],
    })


def _config_with_mock(base_url):
    return json.dumps({
        "persistence": ["Sqlite", ":memory:"],
        "llm_providers": [
            ["d", ["Openai", {
                "api_key": "sk-test",
                "base_url": base_url,
                "organization": None,
                "embedding_model": None,
            }]]
        ],
    })


class TestInvokeStart(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime(_test_config())
        self.rt.register_agent(json.dumps({
            "id": "test-agent",
            "system_prompt": "test assistant",
            "model": {"provider": "openai", "model_name": "gpt-4"},
            "max_iterations": 1,
            "tools": [],
        }))

    def tearDown(self):
        self.rt.close()

    def test_invoke_start_returns_string_handle(self):
        handle_id = self.rt.invoke_start("test-agent", "hello")
        self.assertIsInstance(handle_id, str)
        self.assertTrue(len(handle_id) > 0)
        int(handle_id)

    def test_invoke_start_with_save_kwarg(self):
        handle_id = self.rt.invoke_start("test-agent", "hello", save=True)
        self.assertIsInstance(handle_id, str)

    def test_invoke_start_with_update_current_kwarg(self):
        handle_id = self.rt.invoke_start("test-agent", "hello", update_current=False)
        self.assertIsInstance(handle_id, str)

    def test_invoke_start_on_closed_runtime_raises(self):
        rt = Runtime(_test_config())
        rt.close()
        with self.assertRaises(PARError):
            rt.invoke_start("test-agent", "hello")

    def test_invoke_start_invalid_agent_returns_handle(self):
        handle_id = self.rt.invoke_start("nonexistent-agent", "hello")
        self.assertIsInstance(handle_id, str)


class TestInvokePoll(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime(_test_config())
        self.rt.register_agent(json.dumps({
            "id": "test-agent",
            "system_prompt": "test assistant",
            "model": {"provider": "openai", "model_name": "gpt-4"},
            "max_iterations": 1,
            "tools": [],
        }))

    def tearDown(self):
        self.rt.close()

    def test_invoke_poll_returns_dict(self):
        handle_id = self.rt.invoke_start("test-agent", "hello")
        result = self.rt.invoke_poll(handle_id, timeout_ms=5000)
        self.assertIsInstance(result, dict)
        self.assertIn("status", result)

    def test_invoke_poll_terminal_status(self):
        handle_id = self.rt.invoke_start("test-agent", "hello")
        for _ in range(50):
            result = self.rt.invoke_poll(handle_id, timeout_ms=1000)
            status = result.get("status")
            if status != "pending":
                break
        self.assertIn(result["status"], ("ok", "error", "cancelled"))

    def test_invoke_poll_nonblocking_returns_pending_or_terminal(self):
        handle_id = self.rt.invoke_start("test-agent", "hello")
        result = self.rt.invoke_poll(handle_id, timeout_ms=0)
        self.assertIn(result["status"], ("pending", "ok", "error", "cancelled"))

    def test_invoke_poll_invalid_handle_returns_error(self):
        result = self.rt.invoke_poll("999999", timeout_ms=0)
        self.assertEqual(result["status"], "error")
        self.assertIn("not found", result.get("error", ""))

    def test_invoke_poll_on_closed_runtime_raises(self):
        handle_id = self.rt.invoke_start("test-agent", "hello")
        self.rt.close()
        with self.assertRaises(PARError):
            self.rt.invoke_poll(handle_id)


class TestInvokeCancel(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime(_test_config())
        self.rt.register_agent(json.dumps({
            "id": "test-agent",
            "system_prompt": "test assistant",
            "model": {"provider": "openai", "model_name": "gpt-4"},
            "max_iterations": 1,
            "tools": [],
        }))

    def tearDown(self):
        self.rt.close()

    def test_invoke_cancel_does_not_raise(self):
        handle_id = self.rt.invoke_start("test-agent", "hello")
        self.rt.invoke_cancel(handle_id)

    def test_invoke_cancel_invalid_handle_no_crash(self):
        self.rt.invoke_cancel("999999")
        self.rt.invoke_cancel("-1")

    def test_invoke_cancel_on_closed_runtime_raises(self):
        handle_id = self.rt.invoke_start("test-agent", "hello")
        self.rt.close()
        with self.assertRaises(PARError):
            self.rt.invoke_cancel(handle_id)


class TestInvokeTrioLifecycle(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime(_test_config())
        self.rt.register_agent(json.dumps({
            "id": "test-agent",
            "system_prompt": "test assistant",
            "model": {"provider": "openai", "model_name": "gpt-4"},
            "max_iterations": 1,
            "tools": [],
        }))

    def tearDown(self):
        self.rt.close()

    def test_full_lifecycle_start_poll_done(self):
        handle_id = self.rt.invoke_start("test-agent", "hello")
        for _ in range(50):
            result = self.rt.invoke_poll(handle_id, timeout_ms=1000)
            if result["status"] != "pending":
                break
        self.assertIn(result["status"], ("ok", "error", "cancelled"))

    def test_multiple_sequential_invokes(self):
        h1 = self.rt.invoke_start("test-agent", "first")
        h2 = self.rt.invoke_start("test-agent", "second")
        self.assertNotEqual(h1, h2)
        for _ in range(50):
            r1 = self.rt.invoke_poll(h1, timeout_ms=1000)
            if r1["status"] != "pending":
                break
        for _ in range(50):
            r2 = self.rt.invoke_poll(h2, timeout_ms=1000)
            if r2["status"] != "pending":
                break
        self.assertIn(r1["status"], ("ok", "error", "cancelled"))
        self.assertIn(r2["status"], ("ok", "error", "cancelled"))

    def test_cancel_then_poll_may_yield_cancelled(self):
        handle_id = self.rt.invoke_start("test-agent", "hello")
        self.rt.invoke_cancel(handle_id)
        for _ in range(50):
            result = self.rt.invoke_poll(handle_id, timeout_ms=1000)
            if result["status"] != "pending":
                break
        self.assertIn(result["status"], ("ok", "error", "cancelled"))


if __name__ == "__main__":
    unittest.main()
