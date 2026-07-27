"""Tests for PAR HITL approval Python FFI.

Smoke tests for register_approval_handler, resume_approval,
and basic HITL flow through the Python ctypes binding.
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from par_runtime import Runtime, PARError, PARInitError


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


def _agent_config():
    return json.dumps({
        "id": "test-agent",
        "system_prompt": "You are a test agent.",
        "model": {
            "provider": "openai",
            "model_name": "gpt-4",
            "temperature": 0.7,
        },
        "max_iterations": 3,
        "tools": [],
    })


class TestRegisterApprovalHandlerCallable(unittest.TestCase):
    def test_register_sync_handler_smoke(self):
        """register_approval_handler(callable) does not raise."""
        with Runtime(_test_config()) as rt:
            def my_handler(ctx):
                return {"tag": "Approved"}
            try:
                rt.register_approval_handler(my_handler)
            except Exception as e:
                self.fail(f"register_approval_handler(callable) raised: {e}")

    def test_register_handler_health_survives(self):
        """Runtime remains usable after registering approval handler."""
        with Runtime(_test_config()) as rt:
            def my_handler(ctx):
                return "approved"
            rt.register_approval_handler(my_handler)
            h = rt.health()
            self.assertIsInstance(h, dict)
            self.assertTrue(h.get("runtime_alive"))


class TestRegisterApprovalHandlerWebhook(unittest.TestCase):
    def test_register_webhook_handler_smoke(self):
        """register_approval_handler('https://...') does not raise."""
        with Runtime(_test_config()) as rt:
            try:
                rt.register_approval_handler(
                    "https://hook.example.com/approve",
                    secret="test-secret",
                    timeout=60.0,
                )
            except Exception as e:
                self.fail(f"register_approval_handler(url) raised: {e}")


class TestRegisterApprovalHandlerInvalid(unittest.TestCase):
    def test_register_handler_invalid_type_raises(self):
        """register_approval_handler(123) raises TypeError."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(TypeError):
                rt.register_approval_handler(123)

    def test_register_handler_none_raises(self):
        """register_approval_handler(None) raises TypeError."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(TypeError):
                rt.register_approval_handler(None)


class TestResumeApprovalSmoke(unittest.TestCase):
    def test_resume_approval_nonexistent_run_id_raises(self):
        """resume_approval with invalid run_id raises PARError."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(PARError):
                rt.resume_approval("nonexistent_run_id_12345", {"tag": "Approved"})

    def test_resume_approval_with_string_outcome(self):
        """resume_approval('run', 'approved') raises for bad run_id (not for format)."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(PARError):
                rt.resume_approval("fake_run", "approved")

    def test_resume_approval_with_dict_outcome(self):
        """resume_approval with dict outcome raises for bad run_id."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(PARError):
                rt.resume_approval("fake_run", {"tag": "Rejected", "reason": "nope"})


class TestOutcomeDictRoundTrip(unittest.TestCase):
    def test_approved_outcome_accepted(self):
        """resume_approval accepts 'Approved' string format."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(PARError) as ctx:
                rt.resume_approval("no_such_run", "approved")
            self.assertIn("resume_approval", str(ctx.exception))

    def test_rejected_outcome_accepted(self):
        """resume_approval accepts Rejected dict format."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(PARError):
                rt.resume_approval(
                    "no_such_run",
                    {"tag": "Rejected", "reason": "security review failed"},
                )

    def test_modified_outcome_accepted(self):
        """resume_approval accepts Modified dict format."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(PARError):
                rt.resume_approval(
                    "no_such_run",
                    {"tag": "Modified", "new_input": {"target": "staging"}},
                )

    def test_escalated_outcome_accepted(self):
        """resume_approval accepts Escalated dict format."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(PARError):
                rt.resume_approval(
                    "no_such_run",
                    {"tag": "Escalated", "target": "senior"},
                )

    def test_invalid_outcome_string_raises(self):
        """resume_approval with unknown string raises ValueError."""
        with Runtime(_test_config()) as rt:
            with self.assertRaises(ValueError):
                rt.resume_approval("no_such_run", "banana")


class TestApprovalHandlerAfterAgentRegistration(unittest.TestCase):
    def test_handler_registered_before_agent(self):
        """Global handler can be registered before agent registration."""
        with Runtime(_test_config()) as rt:
            def handler(ctx):
                return {"tag": "Approved"}
            rt.register_approval_handler(handler)
            rt.register_agent(_agent_config())
            h = rt.health()
            self.assertTrue(h.get("runtime_alive"))

    def test_handler_registered_after_agent(self):
        """Global handler can be registered after agent registration."""
        with Runtime(_test_config()) as rt:
            rt.register_agent(_agent_config())
            def handler(ctx):
                return {"tag": "Approved"}
            rt.register_approval_handler(handler)
            h = rt.health()
            self.assertTrue(h.get("runtime_alive"))


if __name__ == "__main__":
    unittest.main()
