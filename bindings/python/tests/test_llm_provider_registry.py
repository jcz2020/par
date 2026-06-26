"""v0.5.4 PAR-tiu: LLM provider registry + FFI Anthropic gap fix test.

Verifies:
- list_llm_providers returns registered providers
- set_default_llm_provider switches default
- Unknown provider ids raise PARError
- Anthropic provider construction works through FFI (closes the hidden
  bug where Python users configuring Anthropic got None handles)
"""
import json
import os
import unittest

from par_runtime import Runtime, PARError


def _test_config(providers):
    """Build a valid config with the given llm_providers list."""
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
        "llm_providers": providers,
        "eval_limits": {
            "max_depth": 10,
            "max_node_visits": 1000,
        },
        "parallel_tool_execution": True,
    })


class TestLLMProviderRegistry(unittest.TestCase):
    def test_list_returns_registered_providers(self):
        config = _test_config([
            ["openai-primary", ["Openai", {
                "api_key": "sk-test", "base_url": None,
                "organization": None, "embedding_model": None,
            }]],
        ])
        with Runtime(config) as rt:
            providers = rt.list_llm_providers()
            # FFI currently registers only the first provider under "default"
            # (per Oracle review finding — multi-provider wire-up is
            # post-v0.5.4 work). Verify the surface works.
            self.assertIn("default", providers)

    def test_set_default_to_registered_succeeds(self):
        config = _test_config([
            ["openai-primary", ["Openai", {
                "api_key": "sk-test", "base_url": None,
                "organization": None, "embedding_model": None,
            }]],
        ])
        with Runtime(config) as rt:
            # Switch to the registered "default" provider — should succeed.
            rt.set_default_llm_provider("default")
            # Still in list after switch.
            self.assertIn("default", rt.list_llm_providers())

    def test_set_default_unknown_id_raises(self):
        config = _test_config([
            ["openai-primary", ["Openai", {
                "api_key": "sk-test", "base_url": None,
                "organization": None, "embedding_model": None,
            }]],
        ])
        with Runtime(config) as rt:
            with self.assertRaises(PARError) as ctx:
                rt.set_default_llm_provider("does-not-exist")
            self.assertIn("does-not-exist", str(ctx.exception))

    def test_anthropic_provider_constructs_via_ffi(self):
        """Closes the hidden bug where Anthropic via FFI returned None.

        With this fix, par_init with an Anthropic provider should construct
        a non-None llm_service for that provider (visible via list_llm_providers).
        """
        config = _test_config([
            ["anthropic-primary", ["Anthropic", {
                "api_key": "sk-test", "base_url": None,
            }]],
        ])
        with Runtime(config) as rt:
            # If FFI returned None for Anthropic, the init would fail or
            # the provider list would be empty. We just check that init
            # succeeded and a provider is registered.
            providers = rt.list_llm_providers()
            self.assertTrue(len(providers) > 0,
                            "Anthropic provider should be registered after init")


if __name__ == "__main__":
    unittest.main()
