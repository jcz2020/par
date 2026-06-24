# Decision: par_postgres opam publication strategy

**Status**: Source-only for now; evaluate pgx migration for opam publication
**Date**: 2026-06-17

## Context

PAR ships a PostgreSQL persistence backend as a separate `par_postgres` opam package. Currently it's source-only (builds from the repo) because `postgresql` (the OCaml binding) is not in the standard opam-repository on all platforms, causing CI failures.

## Options considered

| Option | Pro | Con |
|--------|-----|-----|
| **A. Source-only (current)** | No opam-repository dependency issues | Users must build from source |
| **B. Publish to opam-repository** | One-command install | `postgresql` dependency may fail on some platforms |
| **C. Migrate to pgx** | pgx is pure-OCaml, no C bindings, easier to publish | Rewrite of persistence layer (~2 days) |
| **D. Self-host opam repo** | Full control, no opam-repository review delay | Users need extra remote |

## Decision

**Keep source-only (Option A) for v0.4.x. Evaluate pgx migration (Option C) for v0.5.**

## Rationale

1. **PostgreSQL is optional**: Most users use SQLite (default). PostgreSQL is for production deployments where building from source is acceptable.
2. **pgx rewrite is non-trivial**: The current `postgres_persistence.ml` uses caqti-eio + postgresql. Migrating to pgx would require rewriting all queries (~200 lines) and testing against real PostgreSQL.
3. **CI exclusion works**: The current CI excludes `par_postgres` from dependency resolution. This is documented in CHANGES.md v0.3.4.

## When to revisit

- User requests `opam install par_postgres` one-liner
- pgx adds eio support (currently async/lwt only — would need an eio adapter)
- PAR reaches v1.0 and needs production-grade opam distribution

## If implementing pgx migration

1. Add `pgx` dependency to `par_postgres.opam`
2. Rewrite `postgres_persistence.ml` using `Pgx_io` (if eio adapter exists) or wrap in `Lwt_eio`
3. Remove `postgresql` and `caqti-eio` from `par_postgres` deps
4. Test against PostgreSQL 14+ in CI
5. Publish to opam-repository
