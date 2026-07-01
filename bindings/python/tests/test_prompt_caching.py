"""Prompt caching FFI tests — cache_strategy, system_prompt_zone, skill_prompt_zone.

OCaml entry points: par_capi.ml lines 532-549 (parse_cache_strategy),
624-642 (skill_prompt_zone 3-form parser), runtime.ml 119-124 (B.4 check).
"""

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


def _minimal_skill(skill_id="test-skill"):
    return {
        "schema_version": 1,
        "id": skill_id,
        "name": "Test Skill",
        "description": "A test skill",
        "tool_filter": {"tag": "All_tools"},
        "trigger": {"tag": "Auto"},
    }


class TestCacheStrategyValid(unittest.TestCase):

    def test_with_cache_of_five_min(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["cache_strategy"] = ["With_cache_of", "Five_min"]
            rt.register_agent(json.dumps(cfg))

    def test_with_cache_of_one_hour(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["cache_strategy"] = ["With_cache_of", "One_hour"]
            rt.register_agent(json.dumps(cfg))

    def test_no_caching_string(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["cache_strategy"] = "No_caching"
            rt.register_agent(json.dumps(cfg))

    def test_no_caching_lowercase(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["cache_strategy"] = "no_caching"
            rt.register_agent(json.dumps(cfg))

    def test_no_cache_strategy_field(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            rt.register_agent(json.dumps(cfg))


class TestCacheStrategyInvalid(unittest.TestCase):

    def test_bare_with_cache_of_fails(self):
        with self.assertRaises(PARError):
            with Runtime(_runtime_config()) as rt:
                cfg = _minimal_agent()
                cfg["cache_strategy"] = "with_cache_of"
                rt.register_agent(json.dumps(cfg))

    def test_unknown_tag_fails(self):
        with self.assertRaises(PARError):
            with Runtime(_runtime_config()) as rt:
                cfg = _minimal_agent()
                cfg["cache_strategy"] = ["Unknown_tag", "x"]
                rt.register_agent(json.dumps(cfg))


class TestSystemPromptZone(unittest.TestCase):

    def test_stable_zone_accepted(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["system_prompt_zone"] = "stable"
            rt.register_agent(json.dumps(cfg))

    def test_volatile_zone_accepted(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            cfg["system_prompt_zone"] = "volatile"
            cfg["cache_strategy"] = ["With_cache_of", "Five_min"]
            rt.register_agent(json.dumps(cfg))

    def test_no_zone_field(self):
        with Runtime(_runtime_config()) as rt:
            cfg = _minimal_agent()
            rt.register_agent(json.dumps(cfg))


class TestSkillPromptZone(unittest.TestCase):

    def test_volatile_override_in_skill(self):
        with Runtime(_runtime_config()) as rt:
            skill = _minimal_skill()
            skill["system_prompt_override"] = {"zone": "volatile", "text": "dynamic"}
            rt.register_skill(json.dumps(skill))

    def test_bare_string_override_in_skill(self):
        with Runtime(_runtime_config()) as rt:
            skill = _minimal_skill()
            skill["system_prompt_override"] = "bare system prompt text"
            rt.register_skill(json.dumps(skill))

    def test_stable_override_in_skill(self):
        with Runtime(_runtime_config()) as rt:
            skill = _minimal_skill()
            skill["system_prompt_override"] = {"zone": "stable", "text": "stable prompt"}
            rt.register_skill(json.dumps(skill))

    def test_both_override_in_skill(self):
        with Runtime(_runtime_config()) as rt:
            skill = _minimal_skill()
            skill["system_prompt_override"] = {
                "zone": "both",
                "stable": "stable prompt",
                "volatile": "volatile prompt",
            }
            rt.register_skill(json.dumps(skill))


if __name__ == "__main__":
    unittest.main()
