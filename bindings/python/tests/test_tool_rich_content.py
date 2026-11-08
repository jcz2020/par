"""A Python tool hands the model content (an image), not just a JSON payload.

Before this, a tool's return value was flattened into text, so a model could
never see what the tool produced. This file pins the Python side of the
loop: the handler returns the shared envelope, and the image arrives in the
tool result the provider is sent.
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from _http_test_helpers import _config
from par_runtime import Runtime, image_base64, text, tool_content


def _agent():
    return json.dumps({
        "id": "shooter",
        "system_prompt": "Take a screenshot and describe it.",
        "model": {"provider": "openai", "model_name": "vision-test", "temperature": 0.0},
        "tools": [{
            "name": "shot",
            "description": "Takes a screenshot",
            "input_schema": {"type": "object"},
        }],
    })


def _runtime_with_handler(tmp_path, handler):
    """A runtime whose one tool returns whatever [handler] produces."""
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            requests.append(json.loads(self.rfile.read(length)))
            if len(requests) == 1:
                message = {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [{
                        "id": "call-1",
                        "type": "function",
                        "function": {"name": "shot", "arguments": "{}"},
                    }],
                }
                finish = "tool_calls"
            else:
                message = {"role": "assistant", "content": "I can see it."}
                finish = "stop"
            body = json.dumps({
                "model": "vision-test",
                "choices": [{"message": message, "finish_reason": finish}],
                "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7},
            }).encode()
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
        config = json.loads(_config(f"http://127.0.0.1:{server.server_port}/v1"))
        config["persistence"] = ["Sqlite", str(tmp_path / "rich.db")]
        with Runtime(json.dumps(config)) as runtime:
            runtime.register_agent(_agent())
            runtime.register_tool_with_handler(
                "shot", "Takes a screenshot", '{"type": "object"}', handler,
            )
            yield runtime, requests
    finally:
        server.shutdown()
        worker.join(timeout=5)
        server.server_close()


@pytest.fixture
def vision_runtime(tmp_path):
    yield from _runtime_with_handler(
        tmp_path,
        lambda _input: json.dumps(tool_content(
            text("a screenshot"), image_base64("aGk=", media_type="image/png"),
        )),
    )


@pytest.fixture
def plain_runtime(tmp_path):
    yield from _runtime_with_handler(
        tmp_path, lambda _input: json.dumps({"path": "/tmp/shot.png"}),
    )


def test_tool_content_reaches_the_provider(vision_runtime):
    runtime, requests = vision_runtime
    envelope = json.loads(runtime.invoke("shooter", "take a screenshot"))
    assert envelope["status"] == "ok"
    assert len(requests) == 2, "the model was not asked twice"

    tool_messages = [m for m in requests[1]["messages"] if m["role"] == "tool"]
    assert len(tool_messages) == 1
    content = tool_messages[0]["content"]
    assert isinstance(content, list), "a rich tool result must not be flattened to a string"
    assert content[0] == {"type": "text", "text": "a screenshot"}
    assert content[1] == {
        "type": "image_url",
        "image_url": {"url": "data:image/png;base64,aGk="},
    }


def test_a_plain_payload_is_still_text(plain_runtime):
    """The common path must not change: a JSON payload is still a string."""
    runtime, requests = plain_runtime
    runtime.invoke("shooter", "take a screenshot")
    tool_messages = [m for m in requests[1]["messages"] if m["role"] == "tool"]
    assert len(tool_messages) == 1
    assert isinstance(tool_messages[0]["content"], str)
    assert "/tmp/shot.png" in tool_messages[0]["content"]
