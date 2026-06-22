"""Tests for Runtime.embed() Python FFI bridge."""
import json
import unittest
from par_runtime import Runtime
from par_runtime._errors import PARError


def _test_config(llm_providers=None):
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
        "llm_providers": llm_providers if llm_providers is not None else [],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
        "bash_confirm": {"allow_confirm": False, "always_allow": False, "timeout_seconds": 30.0},
        "event_retention_seconds": 604800.0,
    })


def _openai_provider_config(api_key="sk-test-dummy-key"):
    return ["my_agent", ["Openai", {
        "api_key": api_key,
        "base_url": None,
        "organization": None,
        "embedding_model": None,
    }]]


def _ollama_provider_config(base_url="http://localhost:11434"):
    return ["my_agent", ["Ollama", {"base_url": base_url}]]


class TestEmbed(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime(_test_config())

    def tearDown(self):
        self.rt.close()

    def test_embed_without_provider_raises(self):
        with self.assertRaises(PARError) as ctx:
            self.rt.embed(["hello"])
        self.assertIn("embed failed", str(ctx.exception))

    def test_embed_batch_without_provider_raises(self):
        with self.assertRaises(PARError):
            self.rt.embed(["hello", "world", "test"])

    def test_embed_empty_list_without_provider_raises(self):
        with self.assertRaises(PARError):
            self.rt.embed([])

    def test_embed_on_closed_runtime_raises(self):
        self.rt.close()
        with self.assertRaises((PARError, RuntimeError, AttributeError)):
            self.rt.embed(["hello"])
        self.rt = Runtime(_test_config())

    def test_add_documents_without_provider_raises(self):
        with self.assertRaises(PARError):
            self.rt.add_documents(["hello world"])

    def test_invoke_with_rag_unknown_agent_returns_error(self):
        result = self.rt.invoke_with_rag("nonexistent", "test", k=2)
        self.assertIsNotNone(result)


class TestEmbedWithProvider(unittest.TestCase):
    """Verify that when llm_providers is configured in the runtime config,
    the embedding service is actually wired (not "not initialized")."""

    def test_embed_with_openai_provider_does_not_say_not_initialized(self):
        rt = Runtime(_test_config([_openai_provider_config()]))
        try:
            with self.assertRaises(PARError) as ctx:
                rt.embed(["hello"])
            err = str(ctx.exception)
            self.assertNotIn("not initialized", err,
                "Embedding service should be wired — got 'not initialized': " + err)
            # With a dummy key against api.openai.com, we expect a network
            # or auth error, NOT a "not initialized" error.
            self.assertTrue(
                any(needle in err.lower() for needle in
                    ["401", "403", "invalid_api_key", "invalid api key", "network", "connection",
                     "timeout", "unauthorized", "auth", "permission_denied", "permission denied"]),
                f"Expected real API/network error, got: {err!r}"
            )
        finally:
            rt.close()

    def test_embed_batch_with_openai_provider_does_not_say_not_initialized(self):
        rt = Runtime(_test_config([_openai_provider_config()]))
        try:
            with self.assertRaises(PARError) as ctx:
                rt.embed(["hello", "world", "test"])
            err = str(ctx.exception)
            self.assertNotIn("not initialized", err,
                "Batch embed should be wired — got 'not initialized': " + err)
        finally:
            rt.close()

    def test_add_documents_with_openai_provider_does_not_say_not_initialized(self):
        rt = Runtime(_test_config([_openai_provider_config()]))
        try:
            with self.assertRaises(PARError) as ctx:
                rt.add_documents([{"id": "d1", "content": "hello world"}])
            err = str(ctx.exception)
            self.assertNotIn("not initialized", err,
                "add_documents should be wired — got 'not initialized': " + err)
        finally:
            rt.close()

    def test_ollama_provider_is_accepted_as_embedding_backend(self):
        rt = Runtime(_test_config([_ollama_provider_config()]))
        try:
            with self.assertRaises(PARError) as ctx:
                rt.embed(["hello"])
            err = str(ctx.exception)
            self.assertNotIn("not initialized", err,
                "Ollama provider should be wired — got 'not initialized': " + err)
        finally:
            rt.close()
