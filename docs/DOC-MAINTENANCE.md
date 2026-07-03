<!-- language: en -->

# Documentation Maintenance

PAR's public docs ship to opam and PyPI. Internal docs (strategy, roadmap, design rationale) stay gitignored. This file is the public contract for how we keep the boundary clean.

## Why this document exists

PAR publishes two kinds of documents, and the boundary between them is enforced by tooling, not by convention. Public docs (`README.md`, `docs/index.md`, `docs/**/*.md`) ship inside the opam package and the PyPI wheel, so they live in git and reach every user who installs PAR. Internal docs (`STRATEGY.md`, `DESIGN.md`, all ROADMAPs, `plans/`, `sisyphus/`, `opencode/`, `beads/`) stay gitignored, since they only matter to the maintainer. This file is the public contract that keeps the two streams separate: it states which rules apply, which scripts enforce them, and which checks run on every PR.

The rules below are not aesthetic. Each one maps to a check script in `scripts/` and a target in the Makefile, so a doc PR that drifts from the contract fails CI before a reviewer ever sees it. Treat the contract as part of the public API: breaking it breaks downstream users, even though the breakage is invisible until someone tries to translate, install, or link against the broken page.

If you are a new contributor, read this file end to end before opening a doc PR. The contributor guide in `CONTRIBUTING.md` summarizes the rules, but the rationale and the script-by-script mechanics live here, since the summary drifts if we repeat it in two places. If a rule seems arbitrary, check the linked script: the script is the source of truth, and this file explains why the script exists.

This file is itself versioned with the docs. When the rules change, edit this file in the same commit that changes the script, the Makefile target, or the identifier list. A rule that lives only in this file is a wish; a rule that lives in the script is enforced. Maintainers audit the two together at every release.

## Authoring rules

The four subsections below apply to every public doc at every commit. The rules are not optional, and there is no per-doc override: if a doc cannot satisfy a rule, the doc is wrong, not the rule. The scripts enforce the rules; this section explains what they enforce and why.

When a rule and an existing doc disagree, fix the doc. The scripts are the source of truth. A doc that was written before a rule was added is grandfathered only until the next touch, at which point the rule applies in full.

### Language indicator

Every new or modified public doc must open with `<!-- language: en -->` on line 1. The marker is invisible when the file renders, but it gives translation tooling an anchor to branch from. Future translations keep the marker on line 1 and change the language tag, so a machine can always find the source-of-truth file by scanning for the marker line. If you are editing an existing doc and the marker is missing, add it as part of the same commit. The grep `grep -L '<!-- language: en -->' docs/**/*.md` should return empty for every public doc.

The marker must be the very first line, with no leading blank line and no BOM. Markdown renderers treat a leading comment as a no-op, so the rendered output looks identical to a markerless file, but a parser that walks the raw bytes can use the line as an anchor. If a tool inserts a front-matter block (title, weight, slug) above the comment, the marker is no longer on line 1, and the linter flags the file. Move the marker to the top.

When a tool regenerates a doc from a template, the template must include the marker. If the tool strips leading comments, patch the tool, not the output, since regenerated output overwrites the patch on the next build.

A doc that is split across multiple files (for example, a tutorial with one file per chapter) needs the marker on every file, not just the first. The marker is a per-file anchor, and a missing marker in a chapter file makes the chapter invisible to translation tooling. The same rule applies to diagrams: a Mermaid block in a chapter file must be valid on its own, since the chapter is rendered as a standalone page.

### SDK-first

SDK docs are the primary source of truth. CLI docs exist to support the end-user experience, never to replace the SDK reference. When a behavior changes in code, update the SDK docs first, then mirror the change in the CLI guide. This ordering matters: if the SDK and CLI guides drift, the SDK wins, and the CLI guide is rewritten to match. When you add new SDK documentation, `README.md` must include a working code example in its first 50 lines, since the README is the entry point for the entire package and users rarely scroll past the first screen.

The CLI guide covers invocation, flags, exit codes, and config file locations. Anything else (semantics, error categories, retry policy, custom provider protocol) belongs in the SDK reference, even if a CLI example would be shorter. Users who hit a wall on the CLI should always find the SDK reference, not a wall of CLI flags that does not explain the underlying behavior.

If a CLI command surfaces a behavior that the SDK exposes, link the SDK section from the CLI page and stop. Do not duplicate the explanation, since the two will drift. The link is the contract: the SDK page is canonical, the CLI page is a thin wrapper that points at the canonical source.

### No CJK in English public docs

English docs under `docs/` (root) must not contain Chinese characters (Unicode U+4E00 to U+9FFF) in body text. The Chinese mirror lives in `docs/zh/` and is exempt from this rule. The language-switch text `简体中文` that appears in every English doc header is the sole allowed exception. CI runs this check on every PR:

```bash
# Step 1: find English docs with CJK (excluding zh mirror and internal docs)
# Step 2: for each, check if the only CJK is the language-switch text "简体中文"
grep -rPl "[\x{4e00}-\x{9fff}]" README.md docs/ --include='*.md' \
  | grep -v DOC-MAINTENANCE \
  | grep -v zh \
  | while read f; do
      extra=$(grep -P '[\x{4e00}-\x{9fff}]' "$f" | grep -v '简体中文')
      if [ -n "$extra" ]; then echo "$f"; fi
    done
```

Output must be empty. The exclusions: `DOC-MAINTENANCE` lets this rule reference the CJK block range; `zh` skips the Chinese mirror directory; the language-switch text `简体中文` in English doc headers is allowed. The `while` loop ensures only files with CJK **beyond** the language-switch link are flagged.

### Identifier preservation

These literals must never be translated, renamed, or modified in any doc or PR. Inline backticks only, never fenced code blocks, since fenced blocks hide the literal from the search index and make the identifier check skip the line. When you copy an identifier into a new doc, paste it verbatim from this list. When a refactor renames an identifier in code, search the docs with the identifier name, then update every occurrence in the same commit that renames the symbol.

The list is the source of truth. If a new identifier is added to the codebase, add it to this section in the same commit that introduces it. If an identifier is removed, remove it from this section in the commit that deletes it from code. Out-of-date identifier lists cause silent rot: the linter checks that the listed identifiers appear in the right places, but it cannot know which identifiers belong in the list without reading this section.

The list is grouped by category so a reviewer can audit a PR by category. Package names change rarely, MCP event names change when the protocol evolves, JSON field names change when the config schema breaks. Each category is a separate grep target, and a failure in one category points the reviewer at the right mental model.

When a new identifier crosses a category boundary (for example, a new MCP event that also needs a new JSON field), add the new literal to every category it belongs to in the same commit. Splitting the addition across two commits hides a partial failure from the diff and makes the next refactor harder to reason about.

**Package names:** `par`, `par_cli`, `par_runtime`

**Core APIs:** `Runtime.create`, `Runtime.invoke`, `Runtime.register_tool`, `Runtime.register_agent`, `Runtime.mcp_server`

**LLM providers:** `` `Openai ``, `` `Anthropic ``, `` `Mock ``, `` `Ollama ``

**Persistence:** `` `Sqlite ``, `` `Noop ``

**CLI commands** *(removed in v0.6.7; PAR is now SDK-only — see [par-code](https://github.com/jcz2020/par-code) for the interactive agent)*: `par`, `par config`, `par ask`, `par update`, `par history`, `par stats`, `par --version`

**Bash modules:** `Bash_safe_command`, `Bash_policy`, `Bash_blacklist`, `Bash_invoked`, `Bash_completed`

**MCP events:** `Mcp_server_started`, `Mcp_server_failed`, `Mcp_server_stopped`, `Mcp_tool_invoked`, `Mcp_tool_completed`, `Mcp_resource_read`, `Mcp_prompt_rendered`

**File paths:** `~/.par/config.json`, `lib/par.ml`, `docs/sdk/`

**JSON config field names:** `event_bus.max_queue_size`, `dlq_enabled`, `default_quota.max_concurrent_tasks`, `parallel_tool_execution`, `event_retention_days`

A doc update that breaks any of these fails the identifier check in CI.

## Translation rules

- Preserve all OCaml identifiers, opam package names, CLI commands, JSON field names, polymorphic-variant tags, and file paths verbatim. Translation never paraphrases code, never spells out an acronym, and never substitutes a synonym for a type constructor. A translated doc that says `runtime.create` instead of `Runtime.create` is wrong, even if it reads more naturally in the target language. The CI check greps for the exact case-sensitive literal, so a lowercase substitution breaks the link from the doc to the source.
- Replace prose only. Target length 0.80 to 1.20 of the original. A translation may shrink slightly because some languages pack more meaning per word, but it must never grow or shrink by a factor of two. If the target language needs a longer explanation, split it into a separate paragraph and link the original for the user who wants the full version. Length is a proxy for faithfulness: a 300% growth usually means the translator added opinion, not information.
- When translating from Chinese (or any non-English) into English, open the new file with the `<!-- language: en -->` marker, since English is the source of truth for v0.3.2 and later. When translating from English into another language, replace the marker with the appropriate `<!-- language: <code> -->` and keep the English version untouched. The English file stays canonical; every other language is a derivative. If a future refactor changes the English source, the translator must re-run the diff and update the derivative file in a follow-up commit.
- Never translate a doc that links to a non-translated doc. A broken link in a translated page is worse than no translation, since the user assumes the link works and lands in English mid-paragraph. Translate in dependency order: leaf pages first, hub pages last. The Diataxis index (`docs/index.md`) is translated last, since it links to every other page.
- Mark translated files with the language code that matches the prose, not the language code of the original. A French translation of an English doc uses `<!-- language: fr -->` on line 1, not `<!-- language: en -->` with a French body. The marker tells the reader which prose to expect, and a stale marker is a bug.
- Translation review is required before merge. The translator opens a PR, and a second contributor who reads the target language natively reviews for clarity and faithfulness. Automated translation tools are acceptable as a starting point, but the human review is the gate. The identifier check runs on the translated file and catches any identifier drift the human reviewer missed.

## Pre-release checklist

Run all 12 items before tagging a release. Capture the test count from step 2 and propagate it through steps 3, 4, and 9.

1. `make docs-check` exits 0 (catches CJK residue, broken links, identifier drift).
2. `dune runtest` passes. Capture the actual test count.
3. Update the test count in `README.md` and `CHANGES.md` to match the captured number (resolve the 680 / 462 / 644 inconsistency).
4. Verify all 20 built-in tools are listed in the `README.md` "Built-in Tools" table (not 13).
5. Verify `README.md` first 50 lines contain a working OCaml code example.
6. Verify mermaid blocks render: `grep -E '^\`\`\`mermaid' README.md docs/sdk/overview.md`.
7. Verify no internal link rot: `bash scripts/check_doc_links.sh`.
8. Verify OCaml identifiers preserved: `bash scripts/check_doc_identifiers.sh README.md docs/**/*.md`.
9. Verify `CHANGES.md` has an entry for the new version, dated, with the test count.
10. Verify `CONTRIBUTING.md` and `SECURITY.md` exist at repo root.
11. Verify this file (`docs/DOC-MAINTENANCE.md`) is referenced from both `CONTRIBUTING.md` and `AGENTS.md`.
12. Verify `.gitignore` covers all internal docs (`STRATEGY.md`, `DESIGN.md`, all ROADMAPs, `plans/`, `AGENTS.md`, `sisyphus/`, `opencode/`, `beads/`, `release.md`).

If any item fails, do not tag the release. Fix the underlying issue, re-run the failed step, then re-run the full list. Skipping an item to "save time" is how drift enters the release branch, and un-drifting after the tag is two orders of magnitude more expensive.

If two consecutive items both fail for the same root cause (for example, a typo that breaks the identifier list and the changelog), fix the root cause once and re-run both. Do not patch one to mask the other; the masked failure will resurface on the next release.

If a checklist item needs a new tool or a new script, add the tool in the same release cycle. A checklist item that has no executable form is decoration, and decoration drifts. The maintainers review the checklist at every minor version bump and prune items that are no longer useful.

## CI integration

Three check scripts and one Make target gate every PR. Add new checks as `scripts/check_doc_*.sh` and wire them into the Makefile target, so every new rule ships with an executable gate. A rule that is not enforced by a script will drift, since humans forget, and the docs decay silently until a release catches the rot.

- `scripts/check_doc_identifiers.sh` runs the identifier preservation check. It greps the docs for the full identifier list and fails if any literal is missing from a doc that should mention it, or misspelled. The script exits non-zero on the first miss so CI surfaces the error fast.
- `scripts/check_doc_links.sh` runs the link-rot check. It walks every markdown file, extracts relative and anchor links, and verifies that each target exists in the repo. Absolute `http://` and `https://` links are reported but not gated, since external pages can move without warning.
- `make docs-check` orchestrates both scripts plus the CJK grep. Local contributors should run this target before pushing, since it is faster than waiting for the CI runner to report the same failure. The Make target is the entry point: contributors who only know `make` get every check by running it once.

When you add a new check, place the script in `scripts/` with a name that matches the rule, register it in the Makefile target, and reference it from the rule's section in this file. The triple (script, Make entry, doc reference) keeps the rule discoverable from any of the three directions: a developer who hits a CI failure reads the script, a release manager reads the Makefile, a new contributor reads this file.

Local contributors who want a faster loop can run the individual scripts directly. The scripts are standalone bash and exit non-zero on the first failure, so `bash scripts/check_doc_links.sh && bash scripts/check_doc_identifiers.sh` is a reasonable pre-push hook for the impatient. The Make target exists for the rest of us.

If a CI run fails on a doc-only PR, the failure is almost always a missed identifier, a stale link, or a CJK slip. Re-read the failing line against the relevant section of this file; the rule that catches the failure is the rule that needs to be satisfied. Do not patch the script to make the failure go away, since the rule is the contract.

## Linking and diagrams

### Linking conventions

Use relative paths in markdown links. No absolute `/docs/...`. Anchor links use `#section-name` form. Relative paths survive moves inside the repo and stay valid when the docs ship to opam or PyPI, where the install root is not the repo root. When linking to a section, use the heading text in lowercase with hyphens, not the original prose. When the heading changes, the link must change in the same commit, or `scripts/check_doc_links.sh` fails on the next push.

Cross-doc links use the `../<dir>/<file>.md` form, since the docs ship as a tree and the install root varies. Do not use `https://github.com/<org>/par/...` style links inside prose, since the repo URL may move, and the link will silently break. Reserve absolute URLs for the README's badges and the CHANGELOG's release notes, where the URL is the content.

When a section is renamed, search the repo for the old anchor with `grep -rnF '#old-anchor' docs/`. The link check is strict, but it only fires at the next push; the rename commit will land before the broken link is reported. Run the link check locally before pushing to catch the break in the same commit.

### Diagram conventions

Mermaid only. No images hosted in the repo. No external image links. Mermaid blocks must be validated by render, in CI if available, otherwise manually before the PR merges. Mermaid renders inline in GitHub, opam's HTML docs, and most static site generators, so a single source serves every distribution channel. Image files rot when the URL moves, and binary blobs bloat the repo, so we ban both. If a diagram is too complex for Mermaid, simplify it: a smaller diagram that renders is worth more than a precise one that breaks on a future toolchain upgrade.

A Mermaid block uses the standard fence (`mermaid` after the opening triple backtick). Do not use `mermaid-flowchart` or vendor-specific syntax, since the linter only knows `mermaid`. Each diagram is a sibling paragraph in the doc, never an inline fragment inside a sentence, since inline fragments render inconsistently across platforms.

If a Mermaid block is wider than roughly 20 nodes, split it into a top-level overview plus a per-component zoom-in. The overview is one diagram; each zoom-in links from a node in the overview. Users get the bird's-eye view first and the detail on demand, and each diagram stays small enough to render on a phone screen.

Diagrams must use a color palette that survives both light and dark themes. Mermaid's default theme works on light backgrounds; for dark backgrounds, declare `%%{init: {'theme':'base', 'themeVariables':{'primaryColor':'#1f2937'}}}%%` at the top of the block. Test the diagram in both themes by toggling the GitHub theme before merging. A diagram that disappears in dark mode is broken, even if the source compiles.

A diagram that needs to show data shape (table rows, field types) belongs in prose, not in Mermaid. Mermaid renders shapes, not records. Use a markdown table for tabular data and link to it from the diagram's caption.

## See also

- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — public contributor guide
- [`AGENTS.md`](../AGENTS.md) — local agent / maintainer rules
- [`docs/index.md`](index.md) — documentation index

## Multilingual docs

PAR ships docs in two languages:

| Language | Directory | Status |
|----------|-----------|--------|
| English | `docs/` (root) | Primary — ships to opam and PyPI |
| 简体中文 | `docs/zh/` | Mirror — for Chinese-speaking users |

### Rules

1. Every English doc that has a Chinese counterpart must include a language-switch link at the top: `**English** · [简体中文](path-to-zh)`.
2. Every Chinese doc must include a reciprocal link: `[English](path-to-en) · **简体中文**`.
3. The Chinese mirror lives under `docs/zh/` with the same relative structure as the English original. The directory mirrors `docs/` — if the English file is `docs/howto/concurrency.md`, the Chinese file is `docs/zh/howto/concurrency.md`.
4. `README.md` has the language switch at the top, pointing to `docs/zh/README.md` as the Chinese entry point.
5. The CJK ban applies only to the English docs under `docs/` (root). Chinese docs under `docs/zh/` are exempt.
6. The `scripts/check_doc_identifiers.sh` check runs only on English docs, not on `docs/zh/`.
7. When adding a new public doc, create both the English and Chinese versions and add the language-switch links.

### How to add a new language

Follow the `docs/zh/` pattern:

1. Create a directory like `docs/ja-JP/` (using the BCP 47 tag).
2. Mirror the English docs into it.
3. Add the language to the switch row in `README.md`: `**English** · [简体中文](docs/zh/README.md) · [日本語](docs/ja-JP/README.md)`.
4. Add reciprocal links at the top of every file in both the new directory and the English originals.
