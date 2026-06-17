# Decision: MCP tool on-demand loading

**Status**: Deferred — profile real-world usage first
**Date**: 2026-06-17

## Context

When an MCP server exposes 100+ tools (e.g., a comprehensive GitHub MCP server), registering all tools upfront consumes memory and pollutes the LLM's tool list.

## Decision

**Do NOT implement on-demand loading yet. Profile real-world usage first.**

## Rationale

1. **No evidence of the problem**: Current PAR users connect to MCP servers with 5-20 tools. The 100+ tool scenario is hypothetical.
2. **LLM API limits are the real bottleneck**: OpenAI allows max 128 tools per request. Anthropic allows 64. On-demand loading would need to respect these limits regardless.
3. **Complexity cost**: On-demand loading requires a two-phase tool discovery (list → lazy register on first reference) that adds latency to the first tool call and complexity to the engine.

## When to revisit

- A user connects to an MCP server with >50 tools
- LLM tool-call accuracy degrades due to tool list bloat
- Users report slow startup times from tool registration

## Alternative (if needed)

- Tool subsetting at the agent level (already supported via `tools: string list option` on `agent_entry`)
- MCP server config could accept a `tools_filter` field to pre-filter which tools to register
