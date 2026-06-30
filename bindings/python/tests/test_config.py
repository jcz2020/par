"""Tests for PAR Python binding — agent_config fields added in v0.7.0 (PAR-p70)."""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from par_runtime import Runtime, PARError


def _runtime_config():
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


def _minimal_agent(agent_id="test-agent"):
    return {
        "id": agent_id,
        "system_prompt": "You are a test agent.",
        "model": {"model_name": "gpt-4o", "provider": "openai"},
        "tools": [],
    }


class TestCompressionThresholdField(unittest.TestCase):
    def test_threshold_float_succeeds(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_compression_threshold"] = 0.8
            rt.register_agent(json.dumps(cfg))

    def test_threshold_zero_succeeds(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_compression_threshold"] = 0.0
            rt.register_agent(json.dumps(cfg))

    def test_threshold_one_succeeds(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_compression_threshold"] = 1.0
            rt.register_agent(json.dumps(cfg))


class TestCooldownField(unittest.TestCase):
    def test_cooldown_int_succeeds(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["compression_cooldown_messages"] = 6
            rt.register_agent(json.dumps(cfg))

    def test_cooldown_zero_succeeds(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["compression_cooldown_messages"] = 0
            rt.register_agent(json.dumps(cfg))


class TestWindowOverrideField(unittest.TestCase):
    def test_override_int_succeeds(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_window_override"] = 50000
            rt.register_agent(json.dumps(cfg))


class TestContextStrategyField(unittest.TestCase):
    def test_summarize_variant(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_strategy"] = {"tag": "Summarize", "max_tokens": 8000}
            rt.register_agent(json.dumps(cfg))

    def test_sliding_window_variant(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_strategy"] = {
                "tag": "Sliding_window",
                "max_messages": 50,
                "max_tokens": 100000,
            }
            rt.register_agent(json.dumps(cfg))

    def test_truncate_oldest_variant(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_strategy"] = {
                "tag": "Truncate_oldest",
                "keep_system": True,
                "min_messages": 4,
            }
            rt.register_agent(json.dumps(cfg))

    def test_unknown_tag_raises(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_strategy"] = {"tag": "Nonexistent_strategy"}
            with self.assertRaises(PARError):
                rt.register_agent(json.dumps(cfg))


class TestAllFieldsCombined(unittest.TestCase):
    def test_all_new_fields_together(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_compression_threshold"] = 0.75
            cfg["compression_cooldown_messages"] = 10
            cfg["context_window_override"] = 128000
            cfg["context_strategy"] = {"tag": "Summarize", "max_tokens": 8000}
            rt.register_agent(json.dumps(cfg))


class TestBackwardCompat(unittest.TestCase):
    def test_no_new_fields_still_works(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            rt.register_agent(json.dumps(cfg))

    def test_null_threshold_works(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_compression_threshold"] = None
            rt.register_agent(json.dumps(cfg))

    def test_null_strategy_works(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["context_strategy"] = None
            rt.register_agent(json.dumps(cfg))


if __name__ == "__main__":
    unittest.main()
