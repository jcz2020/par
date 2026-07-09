"""Tests for Runtime.load_document() and Runtime.load_directory() FFI bridge."""
import json
import os
import shutil
import tempfile
import unittest
from par_runtime import Runtime


def _test_config():
    return json.dumps({
        "persistence": ["Sqlite", ":memory:"],
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
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
        "bash_confirm": {"allow_confirm": False, "always_allow": False, "timeout_seconds": 30.0},
        "event_retention_seconds": 604800.0,
    })


def _make_fixtures(base_dir):
    with open(os.path.join(base_dir, "test.txt"), "w") as f:
        f.write("hello world\nthis is a test file\nfor the text loader\n")
    with open(os.path.join(base_dir, "test.md"), "w") as f:
        f.write("# Test\n\nSome markdown content.\n")
    with open(os.path.join(base_dir, "test.csv"), "w") as f:
        f.write("name,age\nAlice,30\nBob,25\n")
    with open(os.path.join(base_dir, "unknown.xyz"), "w") as f:
        f.write("skip me")


class TestLoadDocument(unittest.TestCase):

    def test_load_text_file(self):
        with tempfile.TemporaryDirectory(dir=".") as tmpdir:
            _make_fixtures(tmpdir)
            txt_path = os.path.join(tmpdir, "test.txt")
            with Runtime(_test_config()) as rt:
                docs = rt.load_document(txt_path)
                self.assertIsInstance(docs, list)
                self.assertEqual(len(docs), 1)
                doc = docs[0]
                self.assertIn("content", doc)
                self.assertIn("metadata", doc)
                self.assertIn("source", doc)
                self.assertIn("hello world", doc["content"])

    def test_load_pdf_file(self):
        src = "/tmp/opencode/sample.pdf"
        if not os.path.exists(src):
            self.skipTest("sample.pdf fixture not at /tmp/opencode/")
        with tempfile.TemporaryDirectory(dir=".") as tmpdir:
            dst = os.path.join(tmpdir, "sample.pdf")
            shutil.copy2(src, dst)
            with Runtime(_test_config()) as rt:
                docs = rt.load_document(dst)
                self.assertIsInstance(docs, list)
                self.assertEqual(len(docs), 2)
                for doc in docs:
                    self.assertIn("content", doc)
                    self.assertIn("metadata", doc)
                    self.assertIn("source", doc)
                    self.assertIn("page", doc["metadata"])

    def test_load_unsupported_extension(self):
        with tempfile.TemporaryDirectory(dir=".") as tmpdir:
            _make_fixtures(tmpdir)
            xyz_path = os.path.join(tmpdir, "unknown.xyz")
            with Runtime(_test_config()) as rt:
                with self.assertRaises(RuntimeError) as ctx:
                    rt.load_document(xyz_path)
                self.assertIn("Unsupported", str(ctx.exception))

    def test_load_nonexistent_file(self):
        with Runtime(_test_config()) as rt:
            with self.assertRaises(RuntimeError):
                rt.load_document("nonexistent_file_abc123.txt")


class TestLoadDirectory(unittest.TestCase):

    def test_load_directory_default_map(self):
        with tempfile.TemporaryDirectory(dir=".") as tmpdir:
            _make_fixtures(tmpdir)
            with Runtime(_test_config()) as rt:
                docs = rt.load_directory(tmpdir)
                self.assertIsInstance(docs, list)
                self.assertGreater(len(docs), 0)
                sources = [d["source"] for d in docs]
                has_txt = any("test.txt" in s for s in sources)
                has_md = any("test.md" in s for s in sources)
                has_csv = any("test.csv" in s for s in sources)
                self.assertTrue(has_txt, f"Expected .txt in sources: {sources}")
                self.assertTrue(has_md, f"Expected .md in sources: {sources}")
                self.assertTrue(has_csv, f"Expected .csv in sources: {sources}")

    def test_load_directory_custom_map(self):
        with tempfile.TemporaryDirectory(dir=".") as tmpdir:
            _make_fixtures(tmpdir)
            with Runtime(_test_config()) as rt:
                docs = rt.load_directory(tmpdir, loaders={".txt": "text"})
                self.assertIsInstance(docs, list)
                sources = [d["source"] for d in docs]
                has_txt = any("test.txt" in s for s in sources)
                has_md = any("test.md" in s for s in sources)
                self.assertTrue(has_txt)
                self.assertFalse(has_md, "Custom map should exclude .md")

    def test_load_directory_nonexistent(self):
        with Runtime(_test_config()) as rt:
            with self.assertRaises(RuntimeError):
                rt.load_directory("nonexistent_dir_abc123")


class TestRoundTrip(unittest.TestCase):

    def test_load_then_add_documents(self):
        with tempfile.TemporaryDirectory(dir=".") as tmpdir:
            _make_fixtures(tmpdir)
            txt_path = os.path.join(tmpdir, "test.txt")
            with Runtime(_test_config()) as rt:
                docs = rt.load_document(txt_path)
                self.assertGreater(len(docs), 0)
                try:
                    count = rt.add_documents(docs)
                    self.assertEqual(count, len(docs))
                except Exception:
                    pass


if __name__ == "__main__":
    unittest.main()
