"""Typed Runtime entry points (v0.18 W1-S2).

``Runtime(...)`` and ``register_agent(...)`` accept a typed model, a dict or
the legacy JSON string; ``invoke_result()`` returns an ``InvokeResult`` and
``invoke()`` keeps returning the raw envelope behind a deprecation warning.
The three config forms must reach the same OCaml runtime configuration.
"""
import json
import warnings
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from par_runtime import (
    AgentConfig,
    InvokeResult,
    ModelConfig,
    PARInitError,
    Runtime,
    RuntimeConfig,
    Sqlite,
    ToolSpec,
)


def _start_provider(text="typed hello"):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            self.rfile.read(length)
            body = json.dumps({
                "model": "typed-test",
                "choices": [{
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
                }],
                "usage": {
                    "prompt_tokens": 4,
                    "completion_tokens": 2,
                    "total_tokens": 6,
                },
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    import threading

    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def _config_dict(base_url):
    return {
        "persistence": ["Sqlite", ":memory:"],
        "llm_providers": [[
            "d",
            ["Openai", {
                "api_key": "sk-test",
                "base_url": base_url,
                "organization": None,
                "embedding_model": None,
            }],
        ]],
    }


def _agent(id="typed"):
    return AgentConfig(
        id=id,
        system_prompt="You are a typed fixture.",
        model=ModelConfig(model_name="typed-test", temperature=0.0),
        tools=[ToolSpec(name="echo", description="Echo input")],
    )


def test_typed_config_and_agent_invoke_result():
    server, base_url = _start_provider()
    try:
        with Runtime(RuntimeConfig(
            persistence=Sqlite(":memory:"),
            llm_providers=_config_dict(base_url)["llm_providers"],
        )) as rt:
            rt.register_agent(_agent())
            result = rt.invoke_result("typed", "hello")
            assert isinstance(result, InvokeResult)
            assert result.text == "typed hello"
            assert result.finish_reason == "stop"
            assert result.usage.total_tokens == 6
            assert result.model == "typed-test"
    finally:
        server.shutdown()


def test_typed_dict_and_str_configs_behave_identically():
    server, base_url = _start_provider()
    try:
        typed = RuntimeConfig(
            persistence=Sqlite(":memory:"),
            llm_providers=_config_dict(base_url)["llm_providers"],
        )
        raw = _config_dict(base_url)

        results = []
        for config in (typed, raw, json.dumps(raw)):
            with Runtime(config) as rt:
                rt.register_agent(_agent(config.__class__.__name__))
                results.append(rt.invoke_result(
                    config.__class__.__name__, "hello").text)
        assert results == ["typed hello", "typed hello", "typed hello"]
    finally:
        server.shutdown()


def test_register_agent_accepts_all_three_forms():
    server, base_url = _start_provider()
    try:
        raw_agent = _agent("from-dict").to_dict()
        with Runtime(_config_dict(base_url)) as rt:
            rt.register_agent(_agent("from-model"))
            rt.register_agent(raw_agent)
            rt.register_agent(json.dumps(raw_agent))
            for agent_id in ("from-model", "from-dict"):
                assert rt.invoke_result(agent_id, "hi").text == "typed hello"
    finally:
        server.shutdown()


def test_invoke_still_returns_json_with_a_deprecation_warning():
    server, base_url = _start_provider()
    try:
        with Runtime(_config_dict(base_url)) as rt:
            rt.register_agent(_agent())
            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                raw = rt.invoke("typed", "hello")
            assert isinstance(raw, str)
            assert json.loads(raw)["content"]["text"] == "typed hello"
            assert any(
                issubclass(w.category, DeprecationWarning) for w in caught
            )
    finally:
        server.shutdown()


def test_typed_config_rejects_non_serializable_dicts():
    with pytest.raises(PARInitError):
        Runtime({"persistence": ["Sqlite", ":memory:"], "eval_limits": {1, 2}})
