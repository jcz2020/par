# PAR FFI Benchmark Results

## FFI Overhead vs Pure Python Baseline

| Operation | FFI Mean (ns) | FFI p99 (ns) | Python Mean (ns) | Python p99 (ns) | Overhead |
|-----------|--------------|-------------|-----------------|----------------|----------|
| lifecycle (init+shutdown) | 149945 | 286961 | 93625 | 316295 | 1.60x |
| register_tool | 186529 | 439477 | 84512 | 216189 | 2.21x |
| invoke (full cycle) | 235425 | 514768 | 124826 | 288028 | 1.89x |

## Scalability: Tool Registration

| Tool Count | FFI Mean (ns) | Python Mean (ns) | Overhead |
|-----------|--------------|-----------------|----------|
| 1 | 134514 | 82846 | 1.62x |
| 5 | 220833 | 94042 | 2.35x |
| 10 | 224150 | 36929 | 6.07x |
| 25 | 520759 | 118722 | 4.39x |
| 50 | 886288 | 95507 | 9.28x |

## Memory Overhead

| Metric | FFI | Pure Python | Delta |
|--------|-----|-------------|-------|
| RSS Delta | 0 KB | 0 KB | 0 KB (N/A: below measurement granularity) |
