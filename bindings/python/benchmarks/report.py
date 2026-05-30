"""Benchmark report generator: LaTeX table + Markdown table + console summary.

Usage:
    from benchmarks.report import generate_reports
    generate_reports(results_dict, output_dir="/path/to/docs/paper")
"""
from __future__ import annotations
import json
import os
from typing import Any

_CORE_KEYS = ["lifecycle", "register_tool", "invoke"]


def _overhead_ratio(ffi_mean: float, py_mean: float) -> str:
    """Compute FFI overhead ratio vs pure Python."""
    if py_mean <= 0:
        return "N/A"
    return f"{ffi_mean / py_mean:.2f}x"


def _render_row_md(r: dict[str, Any], ffi: dict[str, Any], py: dict[str, Any]) -> str:
    ratio = _overhead_ratio(ffi["mean"], py["mean"])
    return (f"| {r['name']} | {ffi['mean']:.0f} | {ffi['p99']:.0f} | "
            f"{py['mean']:.0f} | {py['p99']:.0f} | {ratio} |")


def _render_row_latex(r: dict[str, Any], ffi: dict[str, Any], py: dict[str, Any]) -> str:
    ratio = _overhead_ratio(ffi["mean"], py["mean"])
    rv = ratio.replace("x", "").replace("N/A", "--")
    name = r["name"].replace("_", r"\_")
    return f"{name} & {ffi['mean']:.0f} & {py['mean']:.0f} & {rv} \\\\"


def format_markdown(results: dict[str, Any]) -> str:
    """Generate GitHub-flavored Markdown table from benchmark results."""
    lines = [
        "# PAR FFI Benchmark Results", "",
        "## FFI Overhead vs Pure Python Baseline", "",
        "| Operation | FFI Mean (ns) | FFI p99 (ns) | Python Mean (ns) | Python p99 (ns) | Overhead |",
        "|-----------|--------------|-------------|-----------------|----------------|----------|",
    ]
    for key in _CORE_KEYS:
        if key not in results:
            continue
        r = results[key]
        lines.append(_render_row_md(r, r["ffi"], r["python"]))

    lines.extend(["", "## Scalability: Tool Registration", "",
        "| Tool Count | FFI Mean (ns) | Python Mean (ns) | Overhead |",
        "|-----------|--------------|-----------------|----------|"])
    for r in results.get("scalability", []):
        ratio = _overhead_ratio(r["ffi"]["mean"], r["python"]["mean"])
        lines.append(f"| {r['tool_count']} | {r['ffi']['mean']:.0f} | {r['python']['mean']:.0f} | {ratio} |")

    if "memory" in results:
        mem = results["memory"]
        delta = mem["ffi_rss_kb"] - mem["python_rss_kb"]
        lines.extend(["", "## Memory Overhead", "",
            "| Metric | FFI | Pure Python | Delta |", "|--------|-----|-------------|-------|",
            f"| RSS Delta | {mem['ffi_rss_kb']} KB | {mem['python_rss_kb']} KB | {delta} KB (N/A: below measurement granularity) |"])
    lines.append("")
    return "\n".join(lines)


def format_latex(results: dict[str, Any]) -> str:
    """Generate LaTeX table with booktabs + siunitx for paper."""
    lines = [
        r"\begin{table}[t]", r"\centering",
        r"\caption{FFI call overhead: ctypes binding vs pure Python baseline}",
        r"\label{tab:ffi-overhead}",
        r"\begin{tabular}{l S[table-format=6.0] S[table-format=6.0] l}",
        r"\toprule",
        r"Operation & {FFI Mean (ns)} & {Python Mean (ns)} & {Overhead} \\", r"\midrule",
    ]
    for key in _CORE_KEYS:
        if key not in results:
            continue
        r = results[key]
        lines.append(_render_row_latex(r, r["ffi"], r["python"]))
    lines.append(r"\midrule")
    for r in results.get("scalability", []):
        lines.append(_render_row_latex(r, r["ffi"], r["python"]))
    lines.extend([r"\bottomrule", r"\end{tabular}", r"\end{table}"])
    return "\n".join(lines)


def print_summary(results: dict[str, Any]) -> None:
    """Print plain-text console summary of benchmark results."""
    print("\n" + "=" * 60 + "\nBENCHMARK SUMMARY\n" + "=" * 60)
    for key in _CORE_KEYS:
        if key not in results:
            continue
        r = results[key]
        ffi, py = r["ffi"], r["python"]
        ratio = _overhead_ratio(ffi["mean"], py["mean"])
        print(f"\n  {r['name']}:")
        print(f"    FFI:     {ffi['mean']:.0f} ns (p99={ffi['p99']:.0f}, CoV={ffi['cov']:.1f}%)")
        print(f"    Python:  {py['mean']:.0f} ns (p99={py['p99']:.0f}, CoV={py['cov']:.1f}%)")
        print(f"    Overhead: {ratio}")
    if "memory" in results:
        mem = results["memory"]
        print(f"\n  Memory: FFI={mem['ffi_rss_kb']}KB Python={mem['python_rss_kb']}KB")


def generate_reports(results: dict[str, Any], output_dir: str | None = None) -> tuple[str, str]:
    """Generate all report formats from benchmark results. Returns (markdown, latex)."""
    md = format_markdown(results)
    latex = format_latex(results)
    print_summary(results)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
        md_path = os.path.join(output_dir, "benchmark_ffi_data.md")
        tex_path = os.path.join(output_dir, "benchmark_ffi_table.tex")
        with open(md_path, "w") as f:
            f.write(md)
        with open(tex_path, "w") as f:
            f.write(latex)
        print(f"\nReports saved to:\n  {md_path}\n  {tex_path}")
    return md, latex


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("Usage: python -m benchmarks.report <results.json> [output_dir]")
        sys.exit(1)
    with open(sys.argv[1]) as f:
        results = json.load(f)
    generate_reports(results, sys.argv[2] if len(sys.argv) > 2 else None)
