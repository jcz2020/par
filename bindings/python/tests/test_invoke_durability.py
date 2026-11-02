"""Durable invokes through Python (PAR-mrr).

The recovery semantics live in the OCaml tests; this file pins the binding:
the durable flag reaches the runtime, the envelope exposes the id, the
checkpoint is removed on success, and the recovery surface is callable and
fails loudly instead of silently doing nothing.
"""

import json
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from _http_test_helpers import _config
from par_runtime import PARInvokeError, Runtime


def _mock_provider():
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            requests.append(json.loads(self.rfile.read(length)))
            body = json.dumps({
                "model": "durable-test",
                "choices": [{
                    "message": {"role": "assistant", "content": "done"},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4},
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
    return server, worker, requests


def _agent():
    return json.dumps({
        "id": "durable",
        "system_prompt": "Durability fixture.",
        "model": {"provider": "openai", "model_name": "durable-test", "temperature": 0.0},
        "tools": [],
    })


def _config_with_db(tmp_path, base_url):
    config = json.loads(_config(base_url))
    config["persistence"] = ["Sqlite", str(tmp_path / "durable.db")]
    return json.dumps(config)


@pytest.fixture
def durable_runtime(tmp_path):
    server, worker, _requests = _mock_provider()
    try:
        base_url = f"http://127.0.0.1:{server.server_port}/v1"
        with Runtime(_config_with_db(tmp_path, base_url)) as runtime:
            runtime.register_agent(_agent())
            yield runtime, tmp_path / "durable.db"
    finally:
        server.shutdown()
        worker.join(timeout=5)
        server.server_close()


def test_named_run_returns_its_id_and_leaves_no_checkpoint(durable_runtime):
    runtime, db_path = durable_runtime
    envelope = json.loads(runtime.invoke("durable", "hi", invoke_id="py-run-1"))
    assert envelope["status"] == "ok"
    assert envelope["invoke_id"] == "py-run-1"

    with sqlite3.connect(db_path) as conn:
        rows = conn.execute("SELECT COUNT(*) FROM invoke_checkpoints").fetchone()[0]
    assert rows == 0, "a successful run must not leave an in-flight row"


def test_durable_flag_mints_an_id(durable_runtime):
    runtime, _db_path = durable_runtime
    envelope = json.loads(runtime.invoke("durable", "hi", durable=True))
    assert envelope["status"] == "ok"
    assert isinstance(envelope["invoke_id"], str) and envelope["invoke_id"]


def test_orphan_listing_and_recovery_refusals(durable_runtime):
    runtime, _db_path = durable_runtime
    assert runtime.list_orphaned_invokes() == []
    # Nothing was rehydrated at startup, so recovery must refuse rather than
    # resume an arbitrary id.
    with pytest.raises(PARInvokeError, match="not recorded as an orphan"):
        runtime.recover_invoke("never-existed")


def test_non_durable_envelope_has_no_id(durable_runtime):
    runtime, _db_path = durable_runtime
    envelope = json.loads(runtime.invoke("durable", "hi"))
    assert envelope["status"] == "ok"
    assert envelope["invoke_id"] is None
