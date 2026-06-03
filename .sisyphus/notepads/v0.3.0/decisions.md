# Decisions — PAR v0.3.0

## Resolved During Planning
1. UX-3: One tool failure does NOT cancel others (adopt pi-agent-core Promise.all behavior)
2. UX-5d: No escape hatch — make_agent is only path to construct agent_config
3. UX-4: Mustache variable substitution only — no lambdas/partials/sections
4. TOOL-1f: Overlapping edits → reject (not auto-merge) for safety
5. OPS-1b: Use 63-bit OCaml int for metrics (no overflow risk)
6. Tool-1a: Binary file detection → base64 encode
7. Tool-1d: grep regex timeout 30s, partial results on timeout
8. UX-1: Queue cap at 100 messages, oldest dropped on overflow
