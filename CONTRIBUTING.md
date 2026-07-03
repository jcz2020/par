<!-- language: en -->

# Contributing to PAR

PAR is an open-source project and we welcome contributions of all kinds: bug reports, feature proposals, documentation improvements, and code. This guide explains how to set up a development environment, follow our documentation standards, and submit a pull request.

## Code of Conduct

Be respectful. Follow the OCaml community norms. This project adheres to the same standards as the wider OCaml and open-source communities. Report unacceptable behavior via GitHub issues.

## Getting Started

### Prerequisites

You'll need OCaml 5.4 or later (for effects and multicore support), opam 2.1 or later, dune 3.16 or later, `make`, and `git`.

### Fork and clone

Fork the repository on GitHub, then clone your fork locally with `git clone https://github.com/<your-username>/par.git`, then `cd par`.

### Install dependencies

From the repository root, run `opam install . --deps-only` to install OCaml dependencies.

## Local Development

PAR uses `make` as the entry point for common tasks:

- `make build` builds everything.
- `make test` (or `dune runtest`) runs all OCaml tests.
- `cd bindings/python && python3 -m pytest tests/` runs the Python binding tests.
- `make docs-check` verifies the doc rules: CJK residue, broken links, identifier preservation.

## Documentation Standards

This section is the most important one for new contributors. Read it before opening a documentation pull request.

**SDK-first.** SDK documentation is the primary source of truth. CLI documentation exists to support the end-user experience, not to replace the SDK reference. When a behavior changes in code, update the SDK docs first, then mirror the change in the CLI guide.

**English-only public docs.** Public documentation is English-only. Do not introduce Chinese characters (Unicode U+4E00 through U+9FFF) or any other non-English content in any public doc. Every doc opens with an `<!-- language: en -->` marker on its first line to declare its language. Future translations branch from this anchor.

**OCaml identifier preservation.** Code-level identifiers must never be translated, modified, or paraphrased. This includes literals like `Runtime.create`, `` `Sqlite ``, `par`, `par_runtime`, every MCP event name (such as `Mcp_server_started`), every bash module name (such as `Bash_safe_command`), and every JSON config field name (such as `event_bus.max_queue_size`). A doc update that breaks any of these fails the identifier check in CI. See [`docs/rules/docs.md`](docs/rules/docs.md) for the complete identifier list and the rationale.

**CLI identifiers (v0.6.7).** The old CLI commands (`par`, `par config`, `par ask`, `par update`, `par history`, `par stats`, `par --version`) and the `par_cli` package name no longer exist in this repo. They should NOT appear in doc identifiers (the registry above already excludes them). For the interactive Agent product based on this SDK, see [par-code](https://github.com/jcz2020/par-code).

**Pre-release checklist.** Before tagging a release, walk through these seven checks. The full fourteen-item checklist is maintained internally for release managers.

1. `make docs-check` passes.
2. `dune runtest` passes (capture the test count for the release notes).
3. `make check-install-sh` passes (install.sh syntax + help output — mandatory since v0.6.7 when install.sh became the SDK wizard).
4. The first 50 lines of `README.md` contain a working OCaml example.
5. No CJK characters appear in any public doc.
6. `CHANGES.md` has an entry for the new version.
7. **Beta tags are pre-release.** Tags with `-beta.` or `-rc.` are automatically published as GitHub pre-release. Only stable tags (`vX.Y.Z`) appear as latest.

For the full authoring rules, translation rules, and CI integration, see [`docs/rules/docs.md`](docs/rules/docs.md).

## Pull Request Process

We follow an atomic-commit workflow. One commit equals one logical change. Squash or fixup commits locally before pushing so reviewers can read a focused diff.

Commit messages follow the conventional-commit format `<type>(<scope>): <description>`, where `<type>` is one of `feat`, `fix`, `docs`, `chore`, `test`, or `refactor`. For documentation changes, the scope is the version: `docs(v0.3.2): translate sdk/agent.md to English`.

Rebase your branch onto the latest main before requesting review. We do not accept merge commits from feature branches.

If a bead issue exists for the change, reference it in the PR description. This repository uses the `bd` CLI for issue tracking, so contributors who work in a beads-enabled environment can link issues automatically.

## Issue Templates

**Bug report.** Describe what you did, what you expected, what happened. Include OCaml version, PAR version, OS, and a minimal repro.

**Feature request.** Describe the use case. Explain why existing APIs don't solve it. Reference `docs/sdk/overview.md` for current capabilities.

**Documentation issue.** File and line of the issue. Quote the original text. Explain the confusion or inaccuracy.

## See also

- [`README.md`](README.md): project overview
- [`docs/index.md`](docs/index.md): documentation index
- [`CHANGES.md`](CHANGES.md): changelog
- [`SECURITY.md`](SECURITY.md): security disclosure
- [`docs/rules/docs.md`](docs/rules/docs.md): documentation maintenance rules
