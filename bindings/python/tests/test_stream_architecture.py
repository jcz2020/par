import json
import threading
import unittest
from http.server import HTTPServer

from par_runtime import Runtime
from par_runtime._ffi import _lib
from _http_test_helpers import _free_port, _HangingHandler, _config


class TestStreamArchitecture(unittest.TestCase):
    """v0.7.10 regression: verify the new per-handle iterator protocol."""

    @classmethod
    def setUpClass(cls):
        _lib.par_set_request_timeout(1.0)
        cls.port = _free_port()
        cls.server = HTTPServer(("127.0.0.1", cls.port), _HangingHandler)
        cls.server.timeout = 300
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        _lib.par_set_request_timeout(60.0)

    def test_sequential_streams_no_slot_leak(self):
        """a842a7e leaked domain slots; verify 2 sequential streams work."""
        rt = Runtime(_config(f"http://127.0.0.1:{self.port}/v1"))
        try:
            rt.register_agent(json.dumps({
                "id": "a", "system_prompt": "test",
                "model": {"provider": "openai", "model_name": "gpt-4"},
                "max_iterations": 1, "tools": []
            }))
            for i in range(2):
                with self.assertRaises(Exception) as ctx:
                    list(rt.invoke_stream("a", "hello " * 200))
                self.assertIn("timeout", str(ctx.exception).lower(),
                              f"iteration {i}")
        finally:
            rt.close()

    def test_stream_reader_is_iterator(self):
        """invoke_stream returns an iterator with .cancel()."""
        rt = Runtime(_config(f"http://127.0.0.1:{self.port}/v1"))
        try:
            rt.register_agent(json.dumps({
                "id": "a", "system_prompt": "test",
                "model": {"provider": "openai", "model_name": "gpt-4"},
                "max_iterations": 1, "tools": []
            }))
            reader = rt.invoke_stream("a", "hello " * 200)
            self.assertIs(iter(reader), reader)
            self.assertTrue(hasattr(reader, 'cancel'))
            reader.cancel()
            list(reader)
        finally:
            rt.close()
