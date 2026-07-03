# Agent Instructions

<!-- ~120 lines. Full rules in docs/rules/ -->
<!-- SemVer: load 'semver' skill before ANY version change -->
<!-- Version bump: make release-patch/minor/major/beta -->

## Read STRATEGY.md First

**Before starting any v0.3+ work**, read [`docs/STRATEGY.md`](docs/STRATEGY.md).

5 P0 strategic decisions gate all feature work: value proposition (OCaml LangChain+LangGraph), target user (LLM backend engineers), differentiation, priority (type rigor > concurrency > provider > ecosystem), distribution (opam + PyPI).

**If your work conflicts with STRATEGY.md, raise it first.**

## Development Principle: "一次做对" (Do It Right Once)

**Before writing or finalizing any ROADMAP / scope decision**, read [`docs/STRATEGY.md` §11 开发原则](docs/STRATEGY.md).

Core rule: when short-term engineering compromise conflicts with long-term architectural correctness, **choose long-term correctness**. Range can grow, schedule can slip, but **architecture must not be compromised for scope**.

**Mandatory for every architectural / API / type-design decision:**

- **R1**: Explicitly label each decision as **架构正确** (architecturally correct) vs **范围妥协** (scope compromise). Disguising the latter as the former is the most serious planning error in this project.
- **R2**: Any scope compromise MUST come with a long-term replacement plan + trigger condition. No "deal with it later" without a retirement date.
- **R3**: Default to **"一次做对"** (expand scope, do it right) over "分两步走" (split into two versions). Two-step is allowed ONLY when: (a) single step breaks SemVer major constraint, (b) requires unfinished upstream dependency, (c) requires unknown technical validation (use spike first), (d) user explicitly directs. Even when splitting, step 1 must pave the road for step 2 (API design compatible with final form).
- **R4**: During planning, actively self-challenge: *"抛开开发周期和范围,只考虑长远规划和用户怎么用更爽,这个决策还成立吗?"* If the answer is NO, proactively propose a flip to the user — do not wait to be challenged. Discovering a compromise only after the user pushes back is planning failure.
- **R5**: Applies to architecture / type design / API design / public type changes / ROADMAP scope. Does NOT apply to bugfixes (always minimal), docs, CI, deps.

**ROADMAP cannot be finalized until every key decision passes the §11.3 verification checklist.** See `docs/STRATEGY.md` §11 for full rules, history (the 2026-06-30 v0.6.4 case that established this principle), and the verification checklist.

## Build & Install

```bash
dune build                  # build the library + FFI
dune runtest                  # run OCaml tests
make install-dev              # build + install both locations + sync + verify

## Install Script Maintenance (MANDATORY)

`install.sh` is the interactive SDK installer wizard (Python vs OCaml). It evolves across versions. **Every version that touches `install.sh`, `bindings/python/`, `lib/ffi/`, or `dune-project` (package/deps changes) MUST verify install.sh still works before tagging.**

Run `make check-install-sh` — it checks:
1. `bash -n install.sh` — syntax valid
2. `bash install.sh --help` — arg parsing + help output render correctly

A version tag MUST NOT be pushed if `make check-install-sh` fails.
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

### No Downstream Identifiable Information (MANDATORY)

**Never record specific upstream/downstream project names, company names, customer names, or feedback-source identifiers in any committed artifact.** This repo is public. Naming specific partners misleads other developers (suggests endorsement / availability / API stability commitments that were never made) and breaches confidentiality expectations.

**Forbidden in commits, docs, code comments, CHANGES.md, plans, ROADMAP files, ADRs, bd issue text pushed via `bd dolt push`, release notes, README, and any other tracked content:**
- Specific product or project names from downstream/upstream integrators (e.g. ❌ "Project X reported...", ❌ "Customer Y uses PAR for...")
- Identifiable company or team names
- Identifiable agent / module / component names from other projects
- Direct quotes or paraphrases of feedback that could be traced back to a specific partner
- Counts or lists that fingerprint a specific deployment ("3 agents named A/B/C")

**Allowed:**
- Generic terms: "a downstream project", "an integrator", "integration feedback", "downstream integration report", "production user"
- Counts in aggregate that cannot fingerprint: "downstream feedback triggered this change"
- Architecture patterns and domain observations not tied to a named party

**When fixing or closing work that originated from downstream feedback:**
- Describe the technical defect and its fix in generic terms
- Do NOT credit or mention the partner by name anywhere persisted
- Internal channel comms (chat, session transcripts) are not under this rule, but anything committed is

**Enforcement:** `docs/rules/disclosure.md` has the full spec and migration playbook for cleaning up pre-existing violations. Run `make docs-check` (which includes `make check-disclosure`) after every doc edit; the scanner (`scripts/check_disclosure.sh`) blocks PRs that add forbidden identifiers and runs in CI via `.github/workflows/disclosure.yml`.

**Migration policy:** When this rule is tightened, pre-existing violations are cleaned in a dedicated sweep commit (`docs: sanitize downstream identifiers per new disclosure rule`). Do not silently rewrite historical content during unrelated work — keep the cleanup auditable.

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
