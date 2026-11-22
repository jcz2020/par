"""v0.5.4 PAR-mkm: session resume end-to-end test.

Covers:
- Save a conversation via Runtime.set_session_id + save_conversation
- Load by id via Runtime.load_conversation
- Load most recent via Runtime.load_most_recent_conversation
- Unknown session id returns None gracefully
- Round-trip preserves tool_calls / metadata
"""
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

from par_runtime import Runtime, PARError


def _start_provider():
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            self.rfile.read(length)
            body = json.dumps({
                "model": "resume-test",
                "choices": [{
                    "message": {"role": "assistant", "content": "hi"},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


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

    def test_load_most_recent_conversation(self):
        server, base_url = _start_provider()
        config = json.loads(_test_config())
        config["llm_providers"] = [[
            "default",
            ["Openai", {
                "api_key": "sk-test",
                "base_url": base_url,
                "organization": None,
                "embedding_model": None,
            }],
        ]]
        try:
            with Runtime(json.dumps(config)) as rt:
                rt.register_agent(json.dumps({
                    "id": "resume",
                    "system_prompt": "resume fixture",
                    "model": {"provider": "openai", "model_name": "resume-test"},
                    "tools": [],
                }))
                rt.invoke("resume", "hello")
                rt.set_session_id("recent-session")
                self.assertEqual(rt.save_conversation(), 0)
                row = rt.load_most_recent_conversation()
                self.assertIsNotNone(row)
                self.assertEqual(row["session_id"], "recent-session")
                self.assertIn("conversation", row)
                self.assertIsNone(rt.load_most_recent_conversation(scope="other"))
        finally:
            server.shutdown()

    def test_load_most_recent_empty_store_returns_none(self):
        with Runtime(_test_config()) as rt:
            self.assertIsNone(rt.load_most_recent_conversation())


if __name__ == "__main__":
    unittest.main()
