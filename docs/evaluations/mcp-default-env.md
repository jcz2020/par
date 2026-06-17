# Evaluation: MCP `?mcp_default_env` parameter

**Status**: Defer — current strict whitelist is sufficient
**Date**: 2026-06-17

## Context

PAR's `Mcp_transport_stdio.default_child_env` uses a hardcoded POSIX whitelist: `HOME, LOGNAME, PATH, SHELL, TERM, USER`. Users may want to pass additional environment variables to MCP servers (e.g., `GITHUB_TOKEN` for the GitHub MCP server).

## Decision

**Keep the current strict whitelist. Do NOT add `?mcp_default_env` parameter yet.**

## Rationale

1. **Security**: The whitelist prevents secret leakage to untrusted npm packages. Relaxing it increases attack surface.
2. **User config already exists**: The `server_config`'s `env` field allows users to explicitly pass env vars per server. This is the correct, auditable approach.
3. **No user demand**: No one has requested a broader default env.

## When to revisit

- Users report friction from having to manually specify common env vars
- A pattern emerges of env vars that >3 MCP servers commonly need

## If implemented

```ocaml
type mcp_env_policy = [`Strict | `Inherit_all | `Inherit_named of string list]
(* In Runtime.create config: *)
mcp_default_env : mcp_env_policy  (* default: `Strict *)
```
