# Agent Instructions

<!-- ~120 lines. Full rules in docs/rules/ -->
<!-- SemVer: load 'semver' skill before ANY version change -->
<!-- Version bump: make release-patch/minor/major/beta -->

## Read STRATEGY.md First

**Before starting any v0.3+ work**, read [`docs/STRATEGY.md`](docs/STRATEGY.md).

5 P0 strategic decisions gate all feature work: value proposition (OCaml LangChain+LangGraph), target user (LLM backend engineers), differentiation, priority (type rigor > concurrency > provider > ecosystem), distribution (opam + PyPI).

**If your work conflicts with STRATEGY.md, raise it first.**

## Build & Install

```bash
dune build bin/main.exe      # compile CLI
dune runtest                  # run OCaml tests
make install-dev              # build + install both locations + sync + verify
make sync-version             # sync dune-project version to Python bindings
make validate-version         # check semver format
make check-version-sync       # verify all 3 version files agree
make test-count               # run tests + print count
make release-patch            # bump patch version
make release-minor            # bump minor version
make release-major            # bump major version
make release-beta             # bump + add beta suffix (BUMP_TYPE=minor for minor bump)
```

`dune` is the build system. `make` wraps it. **Always use `make install-dev` after code changes** — it builds, copies to both `/usr/local/bin/par` and `_opam/bin/par`, syncs version, and verifies.

## Version

**Source of truth:** `dune-project` line 3. Synced to:
- `bindings/python/pyproject.toml` line 7
- `bindings/python/par_runtime/__init__.py` line 19

SemVer enforced by CI. Pre-release format: `X.Y.Z-beta.YYYYMMDD` (dot separator).
**Load `semver` skill before any version change.**
**Iron rule: tooling/infra/docs-only changes = NO bump. Refresh beta date suffix only. Must check ROADMAP before any bump.** See `docs/rules/release.md` Pre-Bump Gate.
**【强制】版本号变动（bump MAJOR/MINOR/PATCH、刷新 beta 日期）一律请求用户明确指示。不可自作主张执行 `make release-*` 或手动编辑版本号文件。代码变更可以自主完成，版本号变更不可以。**

## Release Strategy

**Beta-first.** Always ship beta first. See `docs/rules/release.md` for full process.
Only tag/release on explicit "publish release" instruction. Before that: no tags, no CI release, no stable version in docs.

## Documentation

See `docs/rules/docs.md` for full doc maintenance rules. Key points:
- English only in public docs (`docs/` root, not `zh/`)
- OCaml identifiers must never be translated
- `make docs-check` validates CJK, links, identifiers

## Non-Interactive Shell Commands

**Always use `-f` flags:** `cp -f`, `mv -f`, `rm -f`, `rm -rf`. Use `-o BatchMode=yes` for ssh/scp. Use `-y` for apt-get. Use `HOMEBREW_NO_AUTO_UPDATE=1` for brew.

## Backlog Management

See [`docs/rules/backlog.md`](docs/rules/backlog.md) for the full backlog spec. Key rules:
- Work > 30 min → create a bd issue first
- Priority P0-P4; version labels only when planned into a milestone
- Workflow: `bd create` → `claim` → code → `close` → `bd dolt push`

```bash
bd ready              # Find available work (no blockers)
bd create --title="..." --type=feature --priority=1
bd update <id> --claim  # Claim work atomically
bd close <id>           # Complete work
bd dolt push            # Sync to Dolt Hub remote
```

Run `bd prime` for full workflow context. Use `bd remember` for persistent knowledge.

## Session Completion

**Work is NOT complete until `git push` succeeds.**

1. File follow-ups in appropriate place (beads issue, `docs/`, commit message)
2. Run quality gates (tests, linters, builds)
3. **PUSH TO REMOTE** (mandatory):
   ```bash
   git pull --rebase && git push
   git status  # MUST show "up to date with origin"
   ```
4. If using beads: `bd dolt push` before `git push`
5. Verify all changes committed AND pushed
6. Hand off context for next session

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ccf33ec3 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
