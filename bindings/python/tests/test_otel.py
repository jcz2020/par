"""OpenTelemetry adapter (v0.18 W2-S4).

Requires the optional extra: ``pip install "par-runtime[otel]"``. The base
test matrix skips this file; the mypy job installs the extra.
"""
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

pytest.importorskip("opentelemetry.sdk")

from par_runtime import (  # noqa: E402
    AgentConfig,
    ModelConfig,
    Runtime,
    RuntimeConfig,
    ToolSpec,
)
from par_runtime.otel import OTelTracer  # noqa: E402


def _start_provider():
    responses = [
        {
            "model": "otel-test",
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [{
                        "id": "call-1",
                        "type": "function",
                        "function": {"name": "echo", "arguments": "{}"},
                    }],
                },
                "finish_reason": "tool_calls",
            }],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        },
        {
            "model": "otel-test",
            "choices": [{
                "message": {"role": "assistant", "content": "done"},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        },
    ]

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            self.rfile.read(length)
            body = json.dumps(responses.pop(0)).encode()
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


def test_otel_exports_the_invoke_tree():
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
        InMemorySpanExporter,
    )

    server, base_url = _start_provider()
    try:
        exporter = InMemorySpanExporter()
        provider = TracerProvider()
        provider.add_span_processor(SimpleSpanProcessor(exporter))
        otel = OTelTracer(provider.get_tracer("par-test"))

        config = RuntimeConfig(
            llm_providers=[[
                "default",
                ["Openai", {
                    "api_key": "sk-test",
                    "base_url": base_url,
                    "organization": None,
                    "embedding_model": None,
                }],
            ]],
        )
        agent = AgentConfig(
            id="otel-agent",
            system_prompt="You are an OTel fixture.",
            model=ModelConfig(model_name="otel-test", temperature=0.0),
            tools=[ToolSpec(name="echo", description="Echo")],
        )
        with Runtime(config) as rt:
            otel.attach(rt)
            rt.register_tool("echo", "Echo", '{"type": "object"}')
            rt.register_agent(agent)
            result = rt.invoke_result("otel-agent", "hello")
            assert result.text == "done"

        spans = exporter.get_finished_spans()
        names = sorted(span.name for span in spans)
        assert names == ["invoke", "llm.complete", "llm.complete", "tool.call"]

        root = next(span for span in spans if span.name == "invoke")
        # The adapter pins the runtime trace id with a synthetic remote parent,
        # so OTel keeps its own span ids while the trace id matches PAR's.
        assert root.parent is not None and root.parent.is_remote
        children = [span for span in spans if span.name != "invoke"]
        for child in children:
            assert child.context.trace_id == root.context.trace_id
            assert child.parent is not None
            assert child.parent.span_id == root.context.span_id
        tool_span = next(span for span in spans if span.name == "tool.call")
        assert tool_span.attributes["tool.name"] == "echo"
        llm_span = next(span for span in spans if span.name == "llm.complete")
        assert llm_span.attributes["gen_ai.system"] == "openai"
    finally:
        server.shutdown()
