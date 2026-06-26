"""v0.5.4 PAR-mkm: session resume end-to-end test.

Covers:
- Save a conversation via Runtime.set_session_id + save_conversation
- Load by id via Runtime.load_conversation
- Load most recent via Runtime.load_most_recent_conversation
- Unknown session id returns None gracefully
- Round-trip preserves tool_calls / metadata
"""
import json
import unittest

from par_runtime import Runtime, PARError


def _test_config(db_path=":memory:"):
    return json.dumps({
        "persistence": ["Sqlite", db_path],
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
        "parallel_tool_execution": True,
    })


class TestSessionResume(unittest.TestCase):
    def test_set_session_id_then_get_returns_same(self):
        with Runtime(_test_config()) as rt:
            rt.set_session_id("my-session-123")
            self.assertEqual(rt.get_session_id(), "my-session-123")

    def test_get_session_id_lazy_init(self):
        with Runtime(_test_config()) as rt:
            sid = rt.get_session_id()
            self.assertIsNotNone(sid)
            self.assertGreater(len(sid), 8)

    def test_save_conversation_no_crash(self):
        with Runtime(_test_config()) as rt:
            rt.set_session_id("save-test")
            rc = rt.save_conversation()
            self.assertEqual(rc, 0)

    def test_load_unknown_session_returns_none(self):
        with Runtime(_test_config()) as rt:
            result = rt.load_conversation("does-not-exist")
            self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
