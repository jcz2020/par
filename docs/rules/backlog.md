<!-- Internal: Backlog management rules for PAR. Not shipped to opam/PyPI. -->

# Backlog Management (Beads)

PAR uses [Beads](https://github.com/beards-dev/beads) (Dolt-powered issue tracker) for all backlog management. Issues live in the local `.beads/` directory and sync to Dolt Hub for cross-machine persistence.

## When to Create an Issue

| Work type | Create issue? |
|---|---|
| Feature work (>30 min) | Yes |
| Bug fix (>30 min) | Yes |
| API change (types, .mli, CLI flags) | Yes |
| Refactor (>1 file) | Yes |
| Doc update, typo, test addition | Optional (judgment call) |

## Issue Types

- `feature` — new user-facing capability
- `bug` — something broken
- `task` — infrastructure, tooling, docs
- `spike` — research / exploration

## Priority Levels

| Priority | Meaning | Example |
|---|---|---|
| P0 | Blocks current release | Build broken, tests failing |
| P1 | Should ship this milestone | Core feature for v0.5 |
| P2 | Nice to have this milestone | Polish, DX improvement |
| P3 | Next milestone | Deferred feature |
| P4 | Backlog / someday | Idea worth tracking |

## Labels

Use milestone labels to group issues by version:
- `v0.4.4` — current beta stabilization
- `v0.5` — next feature release
- `v0.6+` — future

Use category labels for filtering:
- `sdk`, `cli`, `python`, `docs`, `infra`, `security`, `test`

## Standard Workflow

```
1. bd create --title="..." --description="..." --type=feature --priority=1
2. bd label add <id> v0.5
3. bd update <id> --claim
4. ... write code, commit, push ...
5. bd close <id>
6. bd dolt push
```

## Dependency Management

- `bd link <child> <parent>` — child blocks on parent
- `bd ready` — show issues with no open blockers
- `bd children <id>` — show what depends on this

## Remote Sync

Dolt Hub remote is configured for cross-machine sync:
```bash
bd dolt push    # push local changes to Dolt Hub
bd dolt pull    # pull remote changes
```

JSONL auto-export is enabled as a git-tracked fallback:
- Path: `.beads/issues.jsonl`
- Auto-updates after every write command
- Not a substitute for `bd dolt push`; it's a read-only snapshot

## Meeting / Discussion Capture

After a planning session, batch-create from markdown:
```bash
bd create --batch --file=meeting-notes.md
```

Use `bd remember "insight"` for cross-session decisions that aren't issues.
