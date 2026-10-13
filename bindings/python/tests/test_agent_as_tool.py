"""Tests for register_agent_as_tool FFI binding."""

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
        "eval_limits": {
            "max_depth": 10,
            "max_node_visits": 1000,
        },
        "parallel_tool_execution": False,
    })


def _agent_config(agent_id, system_prompt="You are a helpful assistant."):
    return json.dumps({
        "id": agent_id,
        "system_prompt": system_prompt,
        "model": {
            "provider": "Openai",
            "model_name": "mock",
            "temperature": 0.0,
        },
        "tools": [],
        "max_iterations": 10,
        "middleware": [],
        "early_stopping_method": "Force",
    })


class TestRegisterAgentAsTool(unittest.TestCase):
    def test_register_agent_as_tool_basic(self):
        rt = Runtime(_test_config())
        try:
            rt.register_agent(_agent_config("child"))
            rt.register_agent_as_tool("child")
        finally:
            rt.close()

    def test_register_agent_as_tool_custom_name(self):
        rt = Runtime(_test_config())
        try:
            rt.register_agent(_agent_config("child"))
            rt.register_agent_as_tool("child", tool_name="my_custom_tool")
        finally:
            rt.close()

    def test_register_agent_as_tool_with_options(self):
        rt = Runtime(_test_config())
        try:
            rt.register_agent(_agent_config("child"))
            rt.register_agent_as_tool(
                "child",
                tool_name="delegate",
                description="Delegate to child agent",
                max_depth=5,
                inherit_cancellation=False,
            )
        finally:
            rt.close()

    def test_register_agent_as_tool_unknown_agent(self):
        rt = Runtime(_test_config())
        try:
            with self.assertRaises(PARError):
                rt.register_agent_as_tool("nonexistent")
        finally:
            rt.close()

    def test_register_agent_as_tool_duplicate(self):
        rt = Runtime(_test_config())
        try:
            rt.register_agent(_agent_config("child"))
            rt.register_agent_as_tool("child")
            with self.assertRaises(PARError):
                rt.register_agent_as_tool("child")
        finally:
            rt.close()

    def test_register_agent_as_tool_different_agents(self):
        rt = Runtime(_test_config())
        try:
            rt.register_agent(_agent_config("agent_a"))
            rt.register_agent(_agent_config("agent_b"))
            rt.register_agent_as_tool("agent_a")
            rt.register_agent_as_tool("agent_b")
        finally:
            rt.close()


if __name__ == "__main__":
    unittest.main()
