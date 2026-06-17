<!-- Internal: Backlog management rules for PAR. Not shipped to opam/PyPI. -->

# Backlog Management (Beads)

PAR uses [Beads](https://github.com/gastownhall/beads) (Dolt-powered issue tracker) for all backlog management. Issues live in the local `.beads/` directory and sync to Dolt Hub for cross-machine persistence.

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

**版本号标签**：创建需求时不标版本号。只有明确纳入版本计划时才加。
```bash
# 创建时：只有优先级，不标版本
bd create --title="..." --type=feature --priority=2

# 排期确认后：才标版本
bd label add <id> v0.5
```

版本号标签格式：`v0.4.4`、`v0.5`、`v0.6+`

分类标签（可选）：`sdk`、`cli`、`python`、`docs`、`infra`、`security`、`test`

## Standard Workflow

```
1. bd create --title="..." --description="..." --type=feature --priority=2
2. bd update <id> --claim
3. ... write code, commit, push ...
4. bd close <id>
5. bd dolt push
```

排期确认后补版本标签：
```
bd label add <id> v0.5
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

JSONL export is available as a git-tracked fallback:
- Path: `.beads/issues.jsonl`
- Run `bd export > .beads/issues.jsonl` to refresh manually
- Not a substitute for `bd dolt push`; it's a read-only snapshot

## Meeting / Discussion Capture

After a planning session, batch-create from markdown:
```bash
bd create --batch --file=meeting-notes.md
```

Use `bd remember "insight"` for cross-session decisions that aren't issues.
