"""Tests for Runtime.invoke_structured Python binding."""

import json
import os
import sys
import unittest

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


if __name__ == "__main__":
    unittest.main()
