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

<!-- BEGIN RELEASE RULES -->
## Release & Distribution Rules

### 发布流程

v0.3.4+ 的发布管道：

1. **开发完成** → 所有 commits 在 `release/vX.Y.Z` 分支上
2. **合并到 main** → `git checkout main && git merge release/vX.Y.Z`
3. **打 tag** → `git tag -a vX.Y.Z -m "Release vX.Y.Z"`
4. **推送** → `git push origin main --tags`
5. **CI 自动构建** → `release.yml` 在 ubuntu-latest / macos-15 / macos-13 上编译二进制
6. **GitHub Release** → `release.yml` 自动创建 Release，上传 `par-linux-x64`、`par-macos-arm64`、`par-macos-x64`、`sha512-checksums.txt`
7. **手动发布 opam**（首次）→ 下载 tarball + .opam 文件，提交到 opam-repository
8. **手动发布 PyPI**（首次）→ 下载 wheel，`twine upload dist/*.whl`
9. **验证** → `curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash && par --version`

### 二进制命名约定

Release 产物命名格式：`par-{platform}`

| Platform | Runner | 产物名 |
|----------|--------|--------|
| linux-x64 | ubuntu-latest | `par-linux-x64` |
| linux-arm64 | (无 runner) | 暂不支持 |
| macos-arm64 | macos-15 | `par-macos-arm64` |
| macos-x64 | macos-13 | `par-macos-x64` |

校验文件：`sha512-checksums.txt`，格式为 `sha512sum` 输出：
```
{hash}  par-linux-x64
{hash}  par-macos-arm64
{hash}  par-macos-x64
```

### install.sh 使用

```bash
# 一键安装最新版
curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash

# 安装指定版本
PAR_INSTALL_VERSION=v0.3.4 curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash

# 安装到自定义位置
PAR_INSTALL_PREFIX=~/.local curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash

# 源码编译
bash scripts/build-from-source.sh
```

### par upgrade 命令

```bash
par upgrade           # 检查并安装最新版
par upgrade --check   # 只检查不安装
```

工作流程：GitHub API → 获取最新 tag → 下载 `par-{platform}` → SHA-512 验证 → `Unix.rename` 替换自身。

### CI/CD 工作流

| Workflow | 触发条件 | 作用 |
|----------|---------|------|
| `ci.yml` | push/PR to main | 3 平台测试 |
| `release.yml` | tag `v*.*.*` | 构建 3 平台二进制 + SHA-512 → GitHub Release |
| `opam-publish.yml` | tag `v*.*.*` | 生成 tarball + .opam → GitHub Release（手动提交 opam-repo） |
| `pypi-publish.yml` | tag `v*.*.*` | 构建 wheel → GitHub Release（手动 twine upload） |

### 发布检查清单（Pre-release 以外）

在 Pre-release checklist 之外，发布时还需确认：

1. `install.sh` 中的 `GITHUB_REPO` 变量正确
2. `par upgrade` 能正确解析 GitHub Release 的 `tag_name`
3. `sha512-checksums.txt` 在 Release assets 中存在
4. 手动测试：`curl ... | bash && par --version && par upgrade --check`

### 本地测试发布管道

`par upgrade` 和 `install.sh` 都依赖 GitHub Release 产物，本地无法直接端到端测试。按以下方式分级验证：

**1. 不需要网络的测试（每次开发后必做）**

```bash
# 编译 + 安装
dune build bin/main.exe
cp -f _build/default/bin/main.exe /usr/local/bin/par

# 基本功能
par --version                                    # 版本号正确
par upgrade --help                               # 帮助输出正确
par upgrade --check                              # 会失败（无 Release），但确认平台检测和 API 调用正常
```

`par upgrade --check` 在无 Release 时会报 "Failed to fetch release info: HTTP 404"（正常），说明：
- 平台检测成功（输出了 `linux-x64` 或对应平台）
- TLS/Cohttp_eio 链路正常
- GitHub API 调用到达

**2. 需要 Release 产物的测试（打 tag 后做一次）**

打 tag 推送后，等 `release.yml` 跑完，然后：

```bash
# 测试 install.sh
PAR_INSTALL_VERSION=vX.Y.Z curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
par --version                                    # 确认版本

# 测试 par upgrade（先装旧版再升级）
# ... 安装旧版 ...
par upgrade --check                              # 应显示 "Update available: 旧 -> 新"
par upgrade                                      # 应显示 "Upgrade complete"

# 测试 checksums 文件存在
curl -fsSL https://github.com/jcz2020/par/releases/download/vX.Y.Z/sha512-checksums.txt
```

**3. 模拟本地 Release（不推 tag 的本地验证）**

如果想在推 tag 之前模拟 release 产物：

```bash
# 手动构建本地二进制
dune build bin/main.exe

# 创建本地 checksums
sha512sum _build/default/bin/main.exe > /tmp/sha512-checksums.txt

# 手动模拟 install.sh 的下载逻辑
mkdir -p /tmp/par-test && cd /tmp/par-test
cp -f /root/dev/PAR/_build/default/bin/main.exe par-linux-x64
sha512sum -c <(grep par-linux-x64 /tmp/sha512-checksums.txt)  # 验证 checksum

# 用本地文件测试 par upgrade 的 checksum 解析
# （需要 mock HTTP，或直接在 utop 中测试 parse_checksum_for 函数）
```

**4. 不可测的部分（接受风险）**

- `Unix.rename` 原子替换自身：在 Linux 上可靠，macOS 上也可靠（同一文件系统）
- `self_path()` 通过 `/proc/self/exe` 解析：仅 Linux 有效，macOS 回退到 `Sys.argv.(0)`
- `par upgrade` 在 `_opam/bin/par` 路径下会替换 `_opam/bin/par`（不是 `/usr/local/bin/par`）— 这是正确行为，替换当前运行的实例

### v0.3.5 待处理（v0.3.4 发布中发现的问题）

1. **Release 产物命名规范化**：当前命名不一致（`par-linux-x64` vs `par-0.3.4.tar.gz` vs `par_runtime-0.3.4-py3-none-any.whl`）。需要统一为 `par-{version}-{platform}` 格式（如 `par-0.3.4-linux-x64`），tarball 为 `par-0.3.4.tar.gz`，wheel 为 `par_runtime-0.3.4-py3-none-any.whl`。`install.sh` 和 `par upgrade` 的下载 URL 需同步更新。
2. **Release 增加安装使用说明**：GitHub Release body 需要包含分平台、分包的安装指南：CLI（curl 安装）、opam（`opam install par`）、PyPI（`pip install par_runtime`）、源码编译（`scripts/build-from-source.sh`），以及 macOS 补充说明。
3. **CLI 升级命令改为 `par update`**：当前叫 `upgrade` 太长。改为 `par update`，去掉 `--check` flag（没必要，直接跑就完事了，显示结果即可）。
4. **CLI help 美化**：`par --help` / `par <cmd> --help` 需要支持 `-h` 缩写；输出增加颜色区分（命令名高亮、描述灰色等）；同模块内减少多余空行，信息密度更高。参考 `rustc --help` 或 `cargo --help` 的风格。
5. **CI 修复与发布流程优化**：v0.3.4 的 CI 反复失败（`str`/`unix` 依赖、`par_postgres.opam` 的 `postgresql` 不在标准 opam-repo），最终靠手动构建发布。需要：(a) 修复 CI 让 `release.yml` 真正能跑通（macOS runner 编译、opam 依赖解析）；(b) 考虑更简单的打包方式（如 Docker 多阶段构建、nix、或 `opam lock` 锁定依赖）减少 CI 不稳定性；(c) 评估开发规则是否需要补充 CI 调试/绕过指南，避免下次迭代再卡在 CI 上。

### v0.4 规划（已确认目标）

**主题**：事件持久化 + 架构升级

#### 事件持久化（PAR-9e1 重新定义）

目标：将当前半成品的 `save_events` / `load_events` 做成完整可用的 SDK 能力。

**当前状态**：接口定义了、三份实现（SQLite/PostgreSQL/Noop）写了，但 Runtime 引擎从不调用。对 SDK 用户来说是误导性接口。

**需要做的事**：
1. 在引擎/event_bus 管线中接入事件持久化调用（event publish 时自动走 `save_events_fn`）
2. 决定异步 vs 同步（写库不能阻塞 Agent 循环）
3. 决定批量 vs 逐条（高频事件下性能考量）
4. 评估存储成本和清理策略（一个 Agent 跑 5 分钟可能产生几百个事件）
5. SDK 用户开箱即用 — 配了持久化就自动存事件，无需额外代码

**CLI 体验目标**：让 CLI 用户也能感受到事件持久化的价值，例如：
- `par history <task_id>` — 查看某个任务的事件链
- `par stats` — 用量统计（token 消耗、工具调用频率）
- `par replay <task_id>` — 回放任务事件链用于调试

#### 其他 v0.4 项目（v0.3.1 路线图已确认归属）

| 项 | 说明 | 估时 |
|---|------|------|
| **MCP HTTP/SSE transport** | 支持远程 MCP Server | 1–2 周 |
| **MCP Sampling** | Server → LLM 双向流 | 1 周 |
| **bash 交互式确认** | 通过 OPS-6 hook 集成 | 0.5 天 |
| **par_sandbox 评估** | OS 沙箱独立 opam 包 | 2–3 周（若做） |
| **Python callback register_tool** | ctypes CFUNCTYPE + C shim | 待评估 |
| **MCP tool 按需加载** | 50+ tool 场景优化 | 1 周（若做） |
<!-- END RELEASE RULES -->

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

**CLI commands:** `par`, `par config`, `par ask`, `par upgrade`, `par --version`

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
