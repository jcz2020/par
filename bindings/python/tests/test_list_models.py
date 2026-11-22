"""Runtime.list_models through the C bridge (PAR-xmap)."""
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from par_runtime import PARError, Runtime, RuntimeConfig


def _start_models_server():
    names = ["gpt-4o", "gpt-4o-mini"]

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/models", "/v1/models"):
                self.send_response(404)
                self.end_headers()
                return
            body = json.dumps({
                "object": "list",
                "data": [{"id": name, "object": "model"} for name in names],
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


def test_list_models_returns_provider_models():
    server, base_url = _start_models_server()
    try:
        config = RuntimeConfig(llm_providers=[[
            "default",
            ["Openai", {
                "api_key": "sk-test",
                "base_url": base_url,
                "organization": None,
                "embedding_model": None,
            }],
        ]])
        with Runtime(config) as rt:
            assert rt.list_models() == ["gpt-4o", "gpt-4o-mini"]
            assert rt.list_models("default") == ["gpt-4o", "gpt-4o-mini"]
    finally:
        server.shutdown()


def test_list_models_unknown_provider_raises():
    with Runtime(RuntimeConfig()) as rt:
        with pytest.raises(PARError):
            rt.list_models("missing")
