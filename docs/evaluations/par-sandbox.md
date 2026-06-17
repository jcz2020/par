# ADR: par_sandbox — OS-level sandboxing for bash tool

**Status**: Deferred to v0.5+
**Date**: 2026-06-17

## Context

PAR's bash tool uses a type-safe ADT (`Safe_command`) + Policy Functor + 31-entry blacklist. This is application-level safety — no OS sandbox (bwrap, landlock, seccomp) is used.

## Decision

**Defer OS-level sandboxing to v0.5+ as a separate `par_sandbox` opam package.**

## Rationale

1. **Cross-platform complexity**: bwrap is Linux-only, sandbox-exec is macOS-only. Supporting both doubles maintenance.
2. **Root requirements**: bwrap requires setuid or user namespaces; not available in all containers.
3. **Current safety is adequate**: The ADT + blacklist + CWD locking + env stripping + timeout + process group cleanup covers the common attack vectors for an LLM-driven bash tool.
4. **Demand not yet validated**: No users have requested OS-level isolation. PAR's target users (LLM backend engineers) deploy in containers where the OS sandbox is the container runtime itself.

## Future evaluation triggers

- User request for stronger isolation guarantees
- PAR adoption in multi-tenant environments
- Regulatory compliance requirements

## Implementation plan (when triggered)

- `par_sandbox` as optional opam package
- Linux: bwrap with `--unshare-all --ro-bind / / --bind /tmp /tmp`
- macOS: sandbox-exec with a deny-by-default profile
- Integration via Policy Functor's `filter` function (already pluggable)
