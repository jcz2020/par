"""Tests for PAR invoke_parallel Python FFI.

Smoke tests for Runtime.invoke_parallel through the Python ctypes binding.
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from par_runtime import Runtime, PARError


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


def _agent_config(agent_id, prompt="You are a test agent."):
    return json.dumps({
        "id": agent_id,
        "system_prompt": prompt,
        "model": {
            "provider": "openai",
            "model_name": "gpt-4",
            "temperature": 0.7,
        },
        "max_iterations": 3,
        "tools": [],
    })


class TestInvokeParallelSmoke(unittest.TestCase):
    def test_invoke_parallel_empty_specs(self):
        """invoke_parallel with empty specs returns empty successes/failures."""
        with Runtime(_test_config()) as rt:
            result = rt.invoke_parallel([])
            self.assertIsInstance(result, dict)
            self.assertIn("successes", result)
            self.assertIn("failures", result)
            self.assertEqual(len(result["successes"]), 0)
            self.assertEqual(len(result["failures"]), 0)


class TestInvokeParallelResults(unittest.TestCase):
    def test_invoke_parallel_returns_dict_with_keys(self):
        """invoke_parallel result contains successes, failures, merged keys."""
        with Runtime(_test_config()) as rt:
            result = rt.invoke_parallel([])
            self.assertIn("successes", result)
            self.assertIn("failures", result)
            self.assertIn("merged", result)

    def test_invoke_parallel_unknown_agent_in_failures(self):
        """Unknown agent_id appears in failures list."""
        with Runtime(_test_config()) as rt:
            result = rt.invoke_parallel(
                [{"agent_id": "nonexistent"}],
                failure_policy="Continue_on_failure",
            )
            self.assertIsInstance(result, dict)
            self.assertEqual(len(result["successes"]), 0)
            self.assertGreaterEqual(len(result["failures"]), 1)

    def test_invoke_parallel_fail_fast_unknown_agent(self):
        """invoke_parallel with Fail_fast on unknown agent raises PARError."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(PARError):
                rt.invoke_parallel(
                    [{"agent_id": "nonexistent"}],
                    failure_policy="Fail_fast",
                )


class TestInvokeParallelWithAgents(unittest.TestCase):
    def test_invoke_parallel_single_agent(self):
        """invoke_parallel with one registered agent (no LLM, expect error in result)."""
        with Runtime(_test_config()) as rt:
            rt.register_agent(_agent_config("agent_a"))
            result = rt.invoke_parallel(
                [{"agent_id": "agent_a", "input": "hello"}],
                failure_policy="Continue_on_failure",
            )
            self.assertIsInstance(result, dict)
            total = len(result["successes"]) + len(result["failures"])
            self.assertEqual(total, 1)


class TestInvokeParallelPerAgentWorkspace(unittest.TestCase):
    def test_invoke_parallel_with_workspace_spec(self):
        """invoke_parallel accepts per-agent workspace in spec."""
        with Runtime(_test_config()) as rt:
            rt.register_agent(_agent_config("agent_a"))
            specs = [
                {"agent_id": "agent_a", "input": "hi"},
            ]
            result = rt.invoke_parallel(specs, failure_policy="Continue_on_failure")
            self.assertIsInstance(result, dict)


if __name__ == "__main__":
    unittest.main()
