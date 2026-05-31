"""Tests for PAR Python binding."""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from par_runtime import Runtime, PARError, PARInitError, PARToolError
from par_runtime._ffi import _lib


def _test_config():
    return json.dumps({
        "persistence": {"tag": "sqlite", "contents": ":memory:"},
        "event_bus": {
            "max_queue_size": 10,
            "dlq_enabled": False,
            "dlq_max_size": 5,
        },
        "default_quota": {
            "max_tokens": 1024,
            "max_iterations": 5,
            "timeout_seconds": 5.0,
        },
        "shutdown": {
            "grace_period_seconds": 1.0,
            "force_after_seconds": 2.0,
        },
        "llm_providers": [],
        "eval_limits": {
            "max_depth": 10,
            "max_node_visits": 1000,
        },
    })


class TestLibraryLoading(unittest.TestCase):
    def test_library_loaded(self):
        self.assertIsNotNone(_lib)
        self.assertIsNotNone(_lib.par_init)
        self.assertIsNotNone(_lib.par_shutdown)
        self.assertIsNotNone(_lib.par_invoke)


class TestRuntimeInit(unittest.TestCase):
    def test_init_with_valid_config(self):
        rt = Runtime(_test_config())
        self.assertIsNotNone(rt._handle)
        rt.close()
        self.assertIsNone(rt._handle)

    def test_init_with_context_manager(self):
        with Runtime(_test_config()) as rt:
            self.assertIsNotNone(rt._handle)
        self.assertIsNone(rt._handle)

    def test_init_with_invalid_config(self):
        try:
            rt = Runtime("not valid json {{{")
            rt.close()
        except PARInitError:
            pass

    def test_double_close(self):
        rt = Runtime(_test_config())
        rt.close()
        rt.close()

    def test_repr(self):
        rt = Runtime(_test_config())
        self.assertIn("active", repr(rt))
        rt.close()
        self.assertIn("closed", repr(rt))


class TestToolRegistration(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime(_test_config())

    def tearDown(self):
        self.rt.close()

    def test_register_tool(self):
        try:
            self.rt.register_tool(
                "test_tool",
                "A test tool",
                json.dumps({"type": "object"}),
            )
        except PARToolError:
            pass


class TestErrorHandling(unittest.TestCase):
    def test_operations_after_close(self):
        rt = Runtime(_test_config())
        rt.close()
        with self.assertRaises(PARError):
            rt.register_tool("x", "x", "{}")


if __name__ == "__main__":
    unittest.main()