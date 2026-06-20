#!/usr/bin/env python3
"""release-acceptance-test.py - End-to-end install test for par-runtime wheel.

Usage: release-acceptance-test.py <wheel-path> <expected-version>

Exit codes:
  0: all required tests passed
  1: Level 1 failed (import / version mismatch) - BLOCKING
  2: Level 2 failed (Runtime init / tool registration) - BLOCKING
  3: invalid arguments or missing wheel
"""
import json
import shutil
import subprocess
import sys
import venv
from pathlib import Path


# Validated fixture, copy of bindings/python/tests/test_runtime.py::_test_config()
# Uses OCaml polymorphic variant encoding (["Sqlite", ":memory:"]), NOT the stale
# README shape ({"tag": "sqlite", "contents": ":memory:"}).
TEST_CONFIG = json.dumps({
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
})


def run_in_venv(venv_python: str, code: str):
    """Run Python code in venv, return (exit_code, stdout, stderr)."""
    result = subprocess.run(
        [venv_python, "-c", code],
        capture_output=True, text=True,
    )
    return result.returncode, result.stdout, result.stderr


def fail(msg: str, level: int, extra_stdout: str = "", extra_stderr: str = ""):
    """Print structured failure to stderr and return the exit code."""
    print(f"FAIL: {msg}", file=sys.stderr)
    if extra_stdout:
        print(f"stdout: {extra_stdout}", file=sys.stderr)
    if extra_stderr:
        print(f"stderr: {extra_stderr}", file=sys.stderr)
    return level


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <wheel-path> <expected-version>", file=sys.stderr)
        return 3

    wheel_path = Path(sys.argv[1]).resolve()
    expected_version = sys.argv[2]

    if not wheel_path.exists():
        print(f"FAIL: wheel not found at {wheel_path}", file=sys.stderr)
        return 3

    print(f"Testing wheel: {wheel_path.name}")
    print(f"Expected version: {expected_version}")
    print(f"Wheel size: {wheel_path.stat().st_size:,} bytes")
    print()

    # Create fresh venv (idempotent: clear any stale venv first)
    venv_dir = Path("/tmp/par-acceptance-venv")
    if venv_dir.exists():
        shutil.rmtree(venv_dir, ignore_errors=True)
    print(f"Creating venv at {venv_dir}...")
    venv.create(venv_dir, with_pip=True, clear=True)
    venv_pip = str(venv_dir / "bin" / "pip")
    venv_python = str(venv_dir / "bin" / "python")

    # Install wheel into the venv
    print("\n=== Installing wheel ===")
    result = subprocess.run(
        [venv_pip, "install", "--no-cache-dir", str(wheel_path)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return fail("pip install failed", 1, result.stdout, result.stderr)
    print("PASS: pip install")

    # Level 1: import + version match (BLOCKING)
    print("\n=== Level 1: import + version (MUST pass) ===")
    # Avoid f-string / quote conflict by using a plain string + assertions
    # outside the embedded code, plus a clean repr()-based error message.
    code = (
        "import par_runtime\n"
        f"_v = par_runtime.__version__\n"
        f"_e = {expected_version!r}\n"
        f"assert _v == _e, 'version mismatch: ' + repr(_v) + ' != ' + repr(_e)\n"
        "print('import ok, version', _v)\n"
    )
    rc, out, err = run_in_venv(venv_python, code)
    if rc != 0:
        return fail("Level 1 (import + version)", 1, out, err)
    print(f"PASS: {out.strip()}")

    # Level 2: Runtime init + register_tool + close (BLOCKING)
    print("\n=== Level 2: Runtime init + register_tool + close (SHOULD pass) ===")
    code = (
        "import json\n"
        "from par_runtime import Runtime\n"
        f"config = {TEST_CONFIG!r}\n"
        "rt = Runtime(config)\n"
        "rt.register_tool('echo', 'Echo tool', '{\"type\": \"object\"}')\n"
        "rt.close()\n"
        "print('Runtime lifecycle ok')\n"
    )
    rc, out, err = run_in_venv(venv_python, code)
    if rc != 0:
        return fail("Level 2 (Runtime lifecycle)", 2, out, err)
    print(f"PASS: {out.strip()}")

    # Level 3: informational only - never blocks
    print("\n=== Level 3: informational (never fails the build) ===")
    code = "import par_runtime; print('exports:', par_runtime.__all__)"
    rc, out, _err = run_in_venv(venv_python, code)
    if rc == 0:
        print(out.strip())
    else:
        print("(skipped: __all__ not introspectable)")

    code = (
        "from par_runtime._ffi import _find_library; "
        "print('so path:', _find_library())"
    )
    rc, out, _err = run_in_venv(venv_python, code)
    if rc == 0:
        print(out.strip())
    else:
        print("(skipped: _find_library not callable)")

    print("\n=== ALL TESTS PASSED ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
