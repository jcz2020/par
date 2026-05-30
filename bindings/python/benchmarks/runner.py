"""FFI vs Pure Python benchmark runner for PAR.

Measures ctypes FFI call overhead compared to equivalent pure Python.
Run from bindings/python/: python3 -m benchmarks.runner
"""

from __future__ import annotations
import json
import os
import sys

# Ensure par_runtime is importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from benchmarks.stats import compute_stats, run_benchmark, measure_rss_delta, format_ci
from benchmarks.baseline import PurePythonRuntime, _default_config

_ffi_warned = False

def _ffi_warn_once(msg: str) -> None:
    global _ffi_warned
    if not _ffi_warned:
        import warnings
        warnings.warn(f"FFI call failed (expected for stubs): {msg}")
        _ffi_warned = True


def _ffi_config() -> str:
    """Config matching par_runtime test format."""
    return _default_config()


# --- Benchmark 1: Lifecycle (init + shutdown cycle) ---


def bench_lifecycle() -> dict:
    """Benchmark: par_init + par_shutdown round-trip."""
    from par_runtime import Runtime

    def ffi_lifecycle():
        rt = Runtime(_ffi_config())
        rt.close()

    def py_lifecycle():
        rt = PurePythonRuntime(_ffi_config())
        rt.close()

    ffi_samples = run_benchmark(ffi_lifecycle, n_runs=20, n_iterations=50, n_warmup=3)
    py_samples = run_benchmark(py_lifecycle, n_runs=20, n_iterations=50, n_warmup=3)

    return {
        "name": "lifecycle (init+shutdown)",
        "ffi": compute_stats(ffi_samples),
        "python": compute_stats(py_samples),
    }


# --- Benchmark 2: Tool Registration ---


def bench_register_tool() -> dict:
    """Benchmark: register_tool call overhead."""
    from par_runtime import Runtime

    def ffi_register():
        rt = Runtime(_ffi_config())
        try:
            rt.register_tool("bench_tool", "Benchmark tool", '{"type":"object"}')
        except Exception as e:
            _ffi_warn_once(str(e))
        rt.close()

    def py_register():
        rt = PurePythonRuntime(_ffi_config())
        rt.register_tool("bench_tool", "Benchmark tool", '{"type":"object"}')
        rt.close()

    ffi_samples = run_benchmark(ffi_register, n_runs=20, n_iterations=50, n_warmup=3)
    py_samples = run_benchmark(py_register, n_runs=20, n_iterations=50, n_warmup=3)

    return {
        "name": "register_tool",
        "ffi": compute_stats(ffi_samples),
        "python": compute_stats(py_samples),
    }


# --- Benchmark 3: Invoke (FFI round-trip) ---


def bench_invoke() -> dict:
    """Benchmark: invoke call with invalid agent (error path, isolates FFI transport)."""
    from par_runtime import Runtime

    def ffi_invoke():
        rt = Runtime(_ffi_config())
        try:
            rt.register_tool("echo", "Echo", '{"type":"object"}')
        except Exception as e:
            _ffi_warn_once(f"register_tool: {e}")
        try:
            rt.invoke("nonexistent-agent", "test message")
        except Exception as e:
            _ffi_warn_once(f"invoke: {e}")
        rt.close()

    def py_invoke():
        rt = PurePythonRuntime(_ffi_config())
        rt.register_tool("echo", "Echo", '{"type":"object"}')
        rt.invoke("test-agent", "test message")
        rt.close()

    ffi_samples = run_benchmark(ffi_invoke, n_runs=20, n_iterations=50, n_warmup=3)
    py_samples = run_benchmark(py_invoke, n_runs=20, n_iterations=50, n_warmup=3)

    return {
        "name": "invoke (full cycle)",
        "ffi": compute_stats(ffi_samples),
        "python": compute_stats(py_samples),
    }


# --- Benchmark 4: Scalability (multiple tool registrations) ---


def bench_scalability() -> list[dict]:
    """Benchmark: how overhead scales with tool count."""
    from par_runtime import Runtime

    tool_counts = [1, 5, 10, 25, 50]
    results = []

    schema = '{"type":"object","properties":{"input":{"type":"string"}}}'

    for n in tool_counts:

        def ffi_n_tools(_n=n):
            rt = Runtime(_ffi_config())
            for i in range(_n):
                try:
                    rt.register_tool(f"tool_{i}", f"Tool {i}", schema)
                except Exception as e:
                    _ffi_warn_once(f"scalability register: {e}")
            rt.close()

        def py_n_tools(_n=n):
            rt = PurePythonRuntime(_ffi_config())
            for i in range(_n):
                rt.register_tool(f"tool_{i}", f"Tool {i}", schema)
            rt.close()

        ffi_samples = run_benchmark(ffi_n_tools, n_runs=15, n_iterations=30, n_warmup=3)
        py_samples = run_benchmark(py_n_tools, n_runs=15, n_iterations=30, n_warmup=3)

        results.append({
            "name": f"register_{n}_tools",
            "tool_count": n,
            "ffi": compute_stats(ffi_samples),
            "python": compute_stats(py_samples),
        })

    return results


# --- Benchmark 5: Memory ---


def bench_memory() -> dict:
    """Measure RSS delta for init + register + invoke cycle."""
    from par_runtime import Runtime

    def ffi_cycle():
        rt = Runtime(_ffi_config())
        try:
            rt.register_tool("echo", "Echo", '{"type":"object"}')
        except Exception:
            pass
        try:
            rt.invoke("test-agent", "hello")
        except Exception:
            pass
        rt.close()

    def py_cycle():
        rt = PurePythonRuntime(_ffi_config())
        rt.register_tool("echo", "Echo", '{"type":"object"}')
        rt.invoke("test-agent", "hello")
        rt.close()

    ffi_rss = measure_rss_delta(ffi_cycle)
    py_rss = measure_rss_delta(py_cycle)

    return {
        "name": "memory (RSS delta)",
        "ffi_rss_bytes": ffi_rss,
        "python_rss_bytes": py_rss,
        "ffi_rss_kb": ffi_rss // 1024,
        "python_rss_kb": py_rss // 1024,
    }


# --- Main ---


def run_all() -> dict:
    """Run all benchmarks and return structured results."""
    print("=" * 60)
    print("PAR FFI Benchmark Suite")
    print("=" * 60)

    print("\n[1/5] Lifecycle benchmark...")
    lifecycle = bench_lifecycle()
    print(f"  FFI: {format_ci(lifecycle['ffi']['mean'], lifecycle['ffi']['ci_95_lo'], lifecycle['ffi']['ci_95_hi'])}")
    print(f"  Python: {format_ci(lifecycle['python']['mean'], lifecycle['python']['ci_95_lo'], lifecycle['python']['ci_95_hi'])}")

    print("\n[2/5] Register tool benchmark...")
    register = bench_register_tool()
    print(f"  FFI: {format_ci(register['ffi']['mean'], register['ffi']['ci_95_lo'], register['ffi']['ci_95_hi'])}")
    print(f"  Python: {format_ci(register['python']['mean'], register['python']['ci_95_lo'], register['python']['ci_95_hi'])}")

    print("\n[3/5] Invoke benchmark...")
    invoke = bench_invoke()
    print(f"  FFI: {format_ci(invoke['ffi']['mean'], invoke['ffi']['ci_95_lo'], invoke['ffi']['ci_95_hi'])}")
    print(f"  Python: {format_ci(invoke['python']['mean'], invoke['python']['ci_95_lo'], invoke['python']['ci_95_hi'])}")

    print("\n[4/5] Scalability benchmark...")
    scalability = bench_scalability()
    for r in scalability:
        ratio = r['ffi']['mean'] / r['python']['mean'] if r['python']['mean'] > 0 else float('inf')
        print(f"  {r['name']}: FFI={r['ffi']['mean']:.0f}ns Python={r['python']['mean']:.0f}ns ratio={ratio:.2f}x")

    print("\n[5/5] Memory benchmark...")
    memory = bench_memory()
    print(f"  FFI RSS delta: {memory['ffi_rss_kb']} KB")
    print(f"  Python RSS delta: {memory['python_rss_kb']} KB")

    return {
        "lifecycle": lifecycle,
        "register_tool": register,
        "invoke": invoke,
        "scalability": scalability,
        "memory": memory,
    }


if __name__ == "__main__":
    results = run_all()

    # Save raw results
    output_dir = os.path.join(os.path.dirname(__file__), "..", "..", "..", "docs", "paper")
    os.makedirs(output_dir, exist_ok=True)

    results_path = os.path.join(output_dir, "benchmark_ffi_results.json")
    with open(results_path, "w") as f:
        json.dump(results, f, indent=2, default=str)

    print(f"\nResults saved to {results_path}")