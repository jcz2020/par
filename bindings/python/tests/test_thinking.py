"""Anthropic extended thinking, end to end through the Python binding.

The OCaml tests pin the adapter's parsing and serialisation. This file pins the
part only Python can show: ``thinking_budget_tokens`` in the agent's model
config survives the C bridge, reaches the request body, and comes back as a
reasoning block in the invoke envelope.

No live provider is contacted: the server below is local and returns a canned
Anthropic-shaped response, so nothing here claims Anthropic accepted anything.
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from par_runtime import Runtime


def _config(base_url: str) -> str:
    return json.dumps({
        "persistence": ["Sqlite", ":memory:"],
        "event_bus": {
            "buffer_capacity": 10,
            "delivery": {
                "max_delivery_attempts": 1,
                "initial_retry_delay": 0.1,
                "retry_backoff": ["Fixed", 0.5],
                "delivery_timeout": 5.0,
            },
            "dlq_enabled": False,
            "critical_event_types": [],
        },
        "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2},
        "shutdown": {"drain_timeout": 3.0, "cancel_grace_period": 1.0, "flush_batch_size": 100},
        "llm_providers": [["anthropic", ["Anthropic", {
            "api_key": "test-key", "base_url": base_url,
        }]]],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
        "bash_confirm": {
            "allow_confirm": False, "always_allow": False, "timeout_seconds": 30.0,
        },
        "event_retention_seconds": 604800.0,
    })


def _anthropic_response() -> dict:
    return {
        "id": "msg_local",
        "type": "message",
        "role": "assistant",
        "model": "claude-test",
        "content": [
            {"type": "thinking", "thinking": "let me think", "signature": "sig-local"},
            {"type": "text", "text": "the answer"},
        ],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 7, "output_tokens": 4},
    }


@pytest.fixture
def thinking_runtime():
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            requests.append(json.loads(self.rfile.read(length)))
            body = json.dumps(_anthropic_response()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        base = f"http://127.0.0.1:{server.server_port}"
        with Runtime(_config(base)) as runtime:
            runtime.register_agent(json.dumps({
                "id": "thinker",
                "system_prompt": "Think before answering.",
                "model": {
                    "provider": "anthropic",
                    "model_name": "claude-test",
                    "temperature": 1.0,
                    "max_tokens": 4096,
                    "thinking_budget_tokens": 2048,
                },
                "tools": [],
            }))
            yield runtime, requests
    finally:
        server.shutdown()
        worker.join(timeout=5)
        server.server_close()


def test_thinking_budget_reaches_the_request(thinking_runtime):
    runtime, requests = thinking_runtime
    runtime.invoke("thinker", "why is the sky blue?")
    assert len(requests) == 1
    body = requests[0]
    assert body["thinking"] == {"type": "enabled", "budget_tokens": 2048}
    # Anthropic rejects temperature/top_p alongside thinking, so they are gone.
    assert "temperature" not in body
    assert "top_p" not in body


def test_reasoning_block_comes_back_in_the_envelope(thinking_runtime):
    runtime, _requests = thinking_runtime
    envelope = json.loads(runtime.invoke("thinker", "why is the sky blue?"))
    assert envelope["status"] == "ok"
    content = envelope["content"]
    assert content["text"] == "the answer"
    reasoning = content["reasoning"]
    assert len(reasoning) == 1
    tag, fields = reasoning[0]
    assert tag == "Reasoning_block"
    assert fields["text"] == "let me think"
    assert fields["signature"] == "sig-local"


def test_budget_limit_is_reported_before_the_request():
    """A budget Anthropic would reject fails locally, with the reason."""
    with Runtime(_config("http://127.0.0.1:1")) as runtime:
        runtime.register_agent(json.dumps({
            "id": "too-small",
            "system_prompt": "x",
            "model": {
                "provider": "anthropic",
                "model_name": "claude-test",
                "max_tokens": 2048,
                "thinking_budget_tokens": 4096,
            },
            "tools": [],
        }))
        with pytest.raises(Exception) as excinfo:
            runtime.invoke("too-small", "hi")
        assert "smaller than max_tokens" in str(excinfo.value)
