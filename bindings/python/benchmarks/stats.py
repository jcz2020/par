"""Kalibera/Jones benchmarking statistics (see Kalibera & Jones, 2013)."""

from __future__ import annotations

import math
import statistics
import time
from dataclasses import dataclass
from typing import Callable

# 95% CI t-distribution critical values: key=degrees of freedom (n-1)
T_TABLE_95: dict[int, float] = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571,
    6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228,
    15: 2.131, 20: 2.086, 25: 2.060, 30: 2.042, 40: 2.021,
    60: 2.000, 120: 1.980,
}


@dataclass
class BenchmarkResult:
    """Statistical summary of a benchmark measurement."""
    name: str
    n_runs: int
    n_iterations: int
    mean_ns: float
    median_ns: float
    std_ns: float
    p95_ns: float
    p99_ns: float
    ci_95_lo: float
    ci_95_hi: float
    min_ns: float
    max_ns: float
    cov: float  # coefficient of variation (%)
    unit: str = "ns"


def _t_critical(df: int) -> float:
    """Look up Student's t critical value, interpolating if needed."""
    if df in T_TABLE_95:
        return T_TABLE_95[df]
    keys = sorted(T_TABLE_95.keys())
    if df <= 1:
        return T_TABLE_95[1]
    if df >= 120:
        return 1.96
    lo, hi = keys[0], keys[-1]
    for k in keys:
        if k < df:
            lo = k
        if k > df and hi == keys[-1]:
            hi = k
            break
    return T_TABLE_95[lo] + (T_TABLE_95[hi] - T_TABLE_95[lo]) * (df - lo) / (hi - lo)


def compute_stats(samples: list[float]) -> dict[str, float]:
    """Compute statistical summary from per-iteration samples (nanoseconds).

    Returns dict: mean, median, std, p95, p99, ci_95_lo, ci_95_hi, min, max, cov.
    """
    if not samples:
        raise ValueError("samples must be non-empty")
    n = len(samples)
    s = sorted(samples)
    mean = statistics.mean(s)
    std = statistics.stdev(s) if n >= 2 else 0.0
    se = std / math.sqrt(n) if n >= 2 else 0.0
    t = _t_critical(n - 1)
    ci_lo = mean - t * se
    ci_hi = mean + t * se
    p95_idx = max(0, min(math.ceil(0.95 * n) - 1, n - 1))
    p99_idx = max(0, min(math.ceil(0.99 * n) - 1, n - 1))
    return {
        "mean": mean, "median": s[n // 2], "std": std,
        "p95": s[p95_idx], "p99": s[p99_idx],
        "ci_95_lo": ci_lo, "ci_95_hi": ci_hi,
        "min": s[0], "max": s[-1],
        "cov": (std / mean * 100) if mean != 0 else 0.0,
    }


def run_benchmark(
    func: Callable[[], None],
    *,
    n_runs: int = 20,
    n_iterations: int = 1000,
    n_warmup: int = 5,
) -> list[float]:
    """Run benchmark: warmup, then n_runs × n_iterations, returns per-iteration ns."""
    for _ in range(n_warmup):
        for _ in range(n_iterations):
            func()

    per_run_ns: list[float] = []
    for _ in range(n_runs):
        start = time.perf_counter_ns()
        for _ in range(n_iterations):
            func()
        elapsed = time.perf_counter_ns() - start
        per_run_ns.append(elapsed / n_iterations)
    return per_run_ns

def measure_rss_delta(func: Callable[[], None]) -> int:
    """Measure RSS delta (bytes) via /proc/self/status; returns 0 on non-Linux."""
    import platform

    if platform.system() != "Linux":
        return 0

    def _get_rss_kb() -> int:
        try:
            with open("/proc/self/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        return int(line.split()[1])
        except (OSError, ValueError):
            return 0
        return 0

    rss_before = _get_rss_kb()
    func()
    rss_after = _get_rss_kb()
    return (rss_after - rss_before) * 1024


def format_ci(mean: float, ci_lo: float, ci_hi: float, unit: str = "ns") -> str:
    """Format mean with 95% confidence interval."""
    return f"{mean:.1f} {unit} [{ci_lo:.1f}, {ci_hi:.1f}]"
