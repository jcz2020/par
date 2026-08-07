import json
import unittest
from par_runtime import Runtime
from par_runtime._ffi import _lib
from _http_test_helpers import _start_server, _SlowStreamHandler, _config


class TestStreamIdleTimeout(unittest.TestCase):
    """Verify streaming uses idle timeout (between chunks), not total timeout.
    With 2s timeout: a stream sending chunks 0.5s apart for 3s total must
    survive (idle resets on each chunk), proving it's not a hard total cap."""

    def test_slow_stream_does_not_timeout(self):
        _lib.par_set_request_timeout(2.0)
        server, port = _start_server(_SlowStreamHandler)
        try:
            rt = Runtime(_config(f"http://127.0.0.1:{port}/v1"))
            try:
                rt.register_agent(json.dumps({
                    "id": "a", "system_prompt": "test",
                    "model": {"provider": "openai", "model_name": "gpt-4"},
                    "max_iterations": 1, "tools": []
                }))
                events = list(rt.invoke_stream("a", "hello"))
                self.assertGreater(len(events), 0)
            finally:
                rt.close()
        finally:
            _lib.par_set_request_timeout(60.0)
            server.shutdown()
