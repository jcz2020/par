# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## ⚠️ Read STRATEGY.md First

**Before starting any v0.3+ work**, read [`docs/STRATEGY.md`](docs/STRATEGY.md).

It contains the 5 P0 strategic decisions that gate all feature work:
- Q1: Value proposition (PAR = OCaml's LangChain + LangGraph)
- Q2: Target user (LLM backend engineers)
- Q3: Differentiation vs LangChain / pi-agent-core
- Q4: Priority order (type rigor > concurrency > provider > ecosystem)
- Q5: Distribution (opam + PyPI dual)

**If your work conflicts with STRATEGY.md, raise it first** — don't silently violate strategic decisions.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BUILD RULES -->
## Build & Compilation Rules

### 构建命令

```bash
dune build                   # 编译全部
dune build bin/main.exe      # 只编译 CLI
dune runtest                 # 跑测试
dune build lib/ffi/par_capi.so  # 编译 C FFI 共享库（Python 绑定需要）
```

`dune` 是唯一构建工具。没有 `Makefile`，`make` 只是对 `dune` 的薄封装。**永远直接用 dune**。

### dune `.exe` 后缀

dune 的惯例：**所有平台**（包括 Linux）的可执行文件输出都带 `.exe` 后缀。

```bash
_build/default/bin/main.exe   # ← 这是标准 ELF Linux 二进制，不是 Windows PE
```

`file _build/default/bin/main.exe` 会确认 `ELF 64-bit LSB executable`。不要因为看到 `.exe` 就认为需要另找产物。

### 二进制安装

**编译成功 ≠ 安装完成。** 编译后必须手动拷贝到两个位置：

```bash
cp -f _build/default/bin/main.exe /usr/local/bin/par
cp -f _build/default/bin/main.exe _opam/bin/par
```

- `/usr/local/bin/par` — 系统 PATH 通用位置
- `_opam/bin/par` — opam 本地 switch 的 bin，可能在 PATH 中优先级更高

**两处必须同步更新**，否则会出现版本不一致。

### 版本一致性

系统里可能存在多个 `par` 二进制。**修改代码后必须验证实际运行的是最新版本**：

```bash
# 检查 PATH 里实际命中哪个
which par

# 确认版本号
par --version

# 如果版本不对，检查所有安装位置
whereis par

# 强制覆盖所有位置
cp -f _build/default/bin/main.exe /usr/local/bin/par
cp -f _build/default/bin/main.exe _opam/bin/par
```

**改了代码、装了二进制、但版本还是旧的** = 你漏了一个安装位置。

### PATH 优先级

`_opam/bin` 可能排在 `/usr/local/bin` 前面（由 opam `eval $(opam env)` 注入）。这意味着：

1. `which par` 可能指向 `_opam/bin/par`
2. 只更新 `/usr/local/bin/par` 不够，用户实际运行的还是旧的 `_opam/bin/par`
3. **两个位置都必须 cp**

验证方法：
```bash
which par && par --version
```

### 版本号同步

**`dune-project` 是唯一版本源。** 版本号出现在 3 个位置，修改时必须同步：

| 文件 | 修改方式 |
|------|---------|
| `dune-project` 第 3 行 | **手动改**（唯一的手动入口） |
| `bindings/python/pyproject.toml` | `make sync-version` 自动同步 |
| `bindings/python/par_runtime/__init__.py` | `make sync-version` 自动同步 |

**修改版本号的正确步骤：**

1. 编辑 `dune-project` 第 3 行 `(version "X.Y.Z")`
2. `dune build` — 重新生成 `par.opam` / `par_cli.opam`（不要手改）
3. `make sync-version` — 同步到 Python 绑定
4. 确认：`grep -r 'version' dune-project bindings/python/pyproject.toml bindings/python/par_runtime/__init__.py`

### 编译后检查清单

每次修改 OCaml 源码后：

1. `dune build bin/main.exe` — 编译成功（exit 0，无输出 = 成功）
2. `cp -f` 到两个安装位置
3. `par --version` 确认版本号正确
4. 如果改了测试：`dune runtest`
<!-- END BUILD RULES -->

<!-- BEGIN DOC MAINTENANCE -->
## Documentation Maintenance

PAR's public docs (`README.md`, `docs/index.md`, `docs/**/*.md`) ship to opam and PyPI, so they live in git and follow these rules. Internal docs (STRATEGY.md, DESIGN.md, all ROADMAPs, plans/, sisyphus/, opencode/, beads/) stay gitignored and have no constraints from this section.

### Language indicator

Every new or modified public doc must open with `<!-- language: en -->` as line 1. Future translations branch from this anchor.

### SDK-first

SDK docs are primary. The CLI exists for end-user experience. When you add new SDK documentation, `README.md` must include a working code example in its first 50 lines.

### No CJK in English public docs

English docs under `docs/` (root) must not contain Chinese characters (Unicode U+4E00 to U+9FFF) in body text. The Chinese mirror lives in `docs/zh-CN/` and is exempt from this rule. CI runs this check:

```bash
# Step 1: find English docs with CJK (excluding zh-CN mirror and internal docs)
# Step 2: for each, check if the only CJK is the language-switch text "简体中文"
grep -rPl "[\x{4e00}-\x{9fff}]" README.md docs/ --include='*.md' \
  | grep -v DOC-MAINTENANCE \
  | grep -v zh-CN \
  | while read f; do
      extra=$(grep -P '[\x{4e00}-\x{9fff}]' "$f" | grep -v '简体中文')
      if [ -n "$extra" ]; then echo "$f"; fi
    done
```

Output must be empty. The exclusions: `DOC-MAINTENANCE` lets this rule reference the Chinese block range; `zh-CN` skips the Chinese mirror directory; the language-switch text `简体中文` in English doc headers is allowed. The `while` loop ensures only files with CJK **beyond** the language-switch link are flagged.

### OCaml identifier preservation

These literals must never be translated, renamed, or modified in any doc or PR. A doc update that breaks any of these fails the identifier check in CI.

**Package names:** `par`, `par_cli`, `par_runtime`, `par_postgres`

**Core APIs:** `Runtime.create`, `Runtime.invoke`, `Runtime.register_tool`, `Runtime.register_agent`, `Runtime.mcp_server`

**LLM providers:** `` `Openai ``, `` `Anthropic ``, `` `Mock ``, `` `Ollama ``

**Persistence:** `` `Sqlite ``, `` `Postgresql ``, `` `Noop ``

**CLI commands:** `par`, `par config`, `par ask`, `par --version`

**Bash modules:** `Bash_safe_command`, `Bash_policy`, `Bash_blacklist`, `Bash_invoked`, `Bash_completed`

**MCP events:** `Mcp_server_started`, `Mcp_server_failed`, `Mcp_server_stopped`, `Mcp_tool_invoked`, `Mcp_tool_completed`, `Mcp_resource_read`, `Mcp_prompt_rendered`

**File paths:** `~/.par/config.json`, `lib/par.ml`, `docs/sdk/`

**JSON config field names:** `event_bus.max_queue_size`, `dlq_enabled`, `default_quota.max_concurrent_tasks`, `parallel_tool_execution`

### Pre-release checklist

Run all 12 items before tagging a release. Capture the test count from step 2 and propagate it through step 3, 4, and 9.

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
11. Verify `docs/DOC-MAINTENANCE.md` is referenced from both `CONTRIBUTING.md` and this file.
12. Verify `.gitignore` covers all internal docs (STRATEGY.md, DESIGN.md, all ROADMAPs, plans/, AGENTS.md, sisyphus/, opencode/, beads/, release.md).

### CI integration

Three check scripts gate every PR:

- `scripts/check_doc_identifiers.sh` runs the identifier preservation check.
- `scripts/check_doc_links.sh` runs the link-rot check.
- `make docs-check` runs all doc checks (orchestrates both scripts plus the CJK grep).

### Linking conventions

Use relative paths in links. No absolute `/docs/...`. Anchor links use `#section-name` form.

### Diagram conventions

Mermaid only. No images hosted in the repo. No external image links.

<!-- END DOC MAINTENANCE -->

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
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
