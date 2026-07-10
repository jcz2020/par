# P-A-R 长期战略

**状态**: 战略定义完成（2026-06-02）
**维护者**: P-A-R Contributors
**变更机制**: 战略变更需要新文档 + commit message 明确说明原因

---

## 1. 价值定位

**PAR = OCaml 圈的 LangChain + LangGraph 等价物**

覆盖两类场景：
- **MVP 友好**：问答机器人、翻译工具、基础 RAG
- **严肃生产**：状态机、Human-in-the-Loop、多 agent 协作（typed handoff）

核心承诺：
- 集成组件 + 提示词管理（学 LangChain）
- 类型化状态保证（学 LangGraph）
- 不偏向学术研究，也不偏向快速原型

---

## 2. 目标用户

**LLM 后端工程师**

特征：
- 工作中需要构建 agent 系统作为产品一部分
- 重视部署性（Docker, k8s, opam）
- 关心 runtime overhead、稳定性、故障恢复
- 可能从 Python / Go / Rust 后端转来

**非目标用户**（避免做错方向）：
- 纯学术研究者（要的是 paper，不是 SDK）
- 终端用户（要的是产品，不是 SDK）
- 纯前端工程师（agent runtime 跟前端无关）

---

## 3. 差异化主张

### vs LangChain (Python)
1. **类型严谨**："LangChain 能崩的错，PAR 在 build 时就报"
2. **Eio 轻量**："同负载下 PAR 内存/CPU 仅为 Python 项目的 1/5"
3. **原生多 provider**：OpenAI / Anthropic / Ollama / Custom 零成本切换

### vs pi-agent-core (TypeScript)
4. **OCaml 生态唯一选择**：他们不重叠，PAR 是 OCaml 圈唯一选项

### vs AutoGen / OpenAI Agents SDK / CrewAI
5. **类型化多 Agent 切换**：handoff 通过 typed ADT constructor 实现而非 JSON 约定（v0.4+ 规划）

---

## 4. 优先级（资源分配）

按重要性排序的资源分配原则：

| 优先级 | 维度 | 理由 |
|--------|------|------|
| **1** | **类型严谨** | Q3 主张 #1，是 PAR 不可被复制的核心优势 |
| **2** | **并发性能** | Eio 是 PAR 技术差异化（Q3 主张 #2） |
| **3** | **多 provider 适配** | Q3 主张 #3，**变现点**（实际项目用得到） |
| **4** | **OCaml 生态定位** | 受众天花板，长期需考虑但不是紧急 |

**应用规则**：当时间紧张时，砍 4 → 砍 3 → 砍 2 → 砍 1。

---

## 5. 发布策略

**opam + PyPI 双发布**

| 包 | 渠道 | 用途 |
|----|------|------|
| `par` | opam | OCaml SDK（OCaml 后端） |
| `par_runtime` | PyPI | Python 包，通过 ctypes 调用 par_capi.so（Python 后端） |

**不做的发布**：
- ❌ Docker（v0.x 不做，让用户自己打包）
- ❌ npm（不是 TS 项目）
- ❌ Conda（OCaml/Python 都不走 Conda）

---

## 6. 借鉴来源（已验证项目）

| 项目 | 借鉴什么 | 不借鉴什么 |
|------|---------|----------|
| [pi-agent-core](https://github.com/earendil-works/pi) (58.9k stars) | Steering/Follow-up 队列、onUpdate 工具流式、system_prompt 单字符串模式 | Session tree、compaction、thinking levels、custom message types |
| [LangChain](https://github.com/langchain-ai/langchain) / [LangGraph](https://github.com/langchain-ai/langgraph) | system_prompt 单字符串模式、集成组件范式、3 表持久化（checkpoints + blobs + writes） | 过度抽象、Python 动态类型 |
| [OpenAI Agents SDK](https://github.com/openai/openai-agents-python) | Handoff 合成工具模式（transfer_to_<agent>）、RunContextWrapper DI 容器（不进 LLM） | 无内置持久化、Python-only |
| [AutoGen](https://github.com/microsoft/autogen) | BaseChatMessage/BaseAgentEvent 事件模型、save_state/restore_state 序列化 | Swarm 的隐式 routing |
| [Google ADK](https://github.com/google/adk-python) | EventActions（state_delta/transfer_to_agent）、三级状态前缀（app:/user:/session:） | 过度复杂的状态管理体系 |
| [PydanticAI](https://github.com/pydantic/pydantic-ai) | 结构化输出 = 合成工具、RunContext 承载 deps | Python type hints 不适用于 OCaml |
| [Anthropic Claude](https://docs.anthropic.com) | append-only content blocks（text/tool_use/tool_result）、Session Runner 断线恢复 | 断线恢复是远程 API 问题，PAR 不需要 |
| [Vercel AI SDK](https://github.com/vercel/ai) | system 独立属性设计、provider 抽象 | 不需要（Vercel 绑定云） |
| [LiteLLM](https://github.com/BerriAI/litellm) | 透传到 provider 模式 | messages 数组风格（我们用单一字符串） |

---

## 7. 防呆清单（明确不做的）

| 项目 | 不做的理由 |
|------|----------|
| Session tree + branching（完整版） | PAR 用户用 workflow + PG 持久化，不是交互式 IDE。窄化：支持单链 handoff（agent A → B），不支持树状分支 |
| Compaction（LLM 摘要压缩） | PAR 走显式 `context_strategy`，不依赖隐式摘要 |
| Thinking levels | Provider-specific 概念，PAR 走 provider-agnostic |
| Custom message types | TS declaration merging 是 TS-only 特性 |
| ~~Skills system (SKILL.md)~~ | **Removed 2026-06-24** — see §8 changelog. Skill system shipped in v0.5.2 with typed design differentiation. |
| Docker 官方镜像 | v0.x 不做，让用户自打包 |
| 学术 paper 投稿 | 战略转向工程价值（2026-06-02 决议：删 v1.0 论文） |

---

## 8. 变更日志

| 日期 | 变更 | 原因 |
|------|------|------|
| 2026-06-02 | 战略首版 | 启动 v0.3.0 前的 P0 阻断项讨论结果 |
| 2026-06-02 | 删除论文方向 | 论文不是 PAR 的核心价值（学术贡献有限，工程价值高） |
| 2026-06-02 | 借鉴 pi-agent-core | 58.9k stars，验证过的设计模式可移植 |
| 2026-06-09 | 放弃"不做多 agent 协作"限制 | 主流框架研究完成：OpenAI Agents/LangGraph/AutoGen/CrewAI/Google ADK/PydanticAI 均支持 handoff。PAR 窄化为 typed ADT handoff（单链 A→B），不做树状分支 |
| 2026-06-09 | 新增 7 个借鉴来源 | LangGraph（3 表持久化）、OpenAI Agents（handoff + DI）、AutoGen（序列化）、Google ADK（EventActions）、PydanticAI（结构化输出）、Anthropic（content blocks）、CrewAI（任务上下文） |
| 2026-06-09 | 发布策略：beta-first | 开发阶段版本号带 `-beta` 后缀，只有用户明确说"发布正式版"时才执行 release 操作并去掉后缀 |
| 2026-06-21 | v0.4.8 stable 发布 | 首个 stable release（Runtime.invoke_structured）。GH Release + opam-repository PR #30086 已提交；PyPI 待上传。**关键里程碑：项目首次进入"用户可安装"状态** |
| 2026-06-21 | 分发渠道首次落地 | opam-repository PR 提交（ocaml/opam-repository#30086，含 `par` + `par_cli`），GH Release binaries (linux-x64, macos-arm64) 首次提供，install.sh 验证可装。PyPI `par-runtime` 待用户配置 token 后上传 |
| 2026-06-21 | PyPI 三次 P0 失败 → 转向 v0.5.0 重设计 | v0.4.8 缺 .so（PAR-0qf）、v0.4.9 glibc 2.38 太新（PAR-8cs）、v0.4.10 setuptools<61 UNKNOWN 文件名（PAR-cog）。根因：release pipeline 缺端到端验收测试 + build 环境不固定。**用户决定 B 路径：不再发 v0.4.x hotfix，作为 v0.5.0 Track A 重设（manylinux + auditwheel + 验收门）**。详见 docs/release-pipeline-redesign.md |
| 2026-06-21 | **决定反转：v0.4.11 在 v0.4.x 系列彻底修，不推 v0.5.\*** | 用户改主意：希望在 v0.4.11 彻底解决（不是 v0.5.\*）。**v0.4.11 scope**: setuptools upgrade + ubuntu-22.04 pinning（已 v0.4.10 完成 binary 部分）+ 3 平台 acceptance test workflow（Debian 12/Ubuntu 22.04/Ubuntu 24.04）+ 本地 dry-run script + release.md E2E 程序文档。**v0.5+ stretch**：manylinux glibc 2.17、ARM64、macOS wheel、OIDC auto-upload。准备工作（roadmap + 脚本骨架 + bd 重定向）已完成，下个 session 执行。 |
| 2026-06-21 | 战略教训 | "本地编译产物 QA ≠ CI 产物 QA" — install-dev 覆盖本地 binary 掩盖了 GH Release binary 的 glibc 问题。**今后所有 release 验证必须在隔离环境（容器/沙箱 venv）下载实际产物测试** |
| 2026-06-21 | **决定反转：v0.4.11 在 v0.4.x 系列彻底修，不推 v0.5.\*** | 用户改主意：希望在 v0.4.11 彻底解决（不是 v0.5.\*）。**v0.4.11 scope**: setuptools upgrade + ubuntu-22.04 pinning（已 v0.4.10 完成 binary 部分）+ 3 平台 acceptance test workflow（Debian 12/Ubuntu 22.04/Ubuntu 24.04）+ 本地 dry-run script + release.md E2E 程序文档。**v0.5+ stretch**：manylinux glibc 2.17、ARM64、macOS wheel、OIDC auto-upload。准备工作（roadmap + 脚本骨架 + bd 重定向）已完成，下个 session 执行。 |
| 2026-06-21 | v0.4.12 scope: 工作流审计 + 新 CI 工作流 + OIDC + manylinux scaffold | 用户决策："直接用 v0.4.12 把这些事做了"，澄清"老的 Linux 我觉得完全可以不必兼容"（即放弃 manylinux2014/CentOS 7）。**v0.4.12 实际 scope**: 修 GH Release 三方竞争（release.yml vs pypi-publish.yml vs opam-publish.yml）；标准化 opam 包列表（弃用 `*.opam` 通配符）；加 nightly.yml、codeql.yml（仅 Python+Actions，OCaml 不在 CodeQL 支持列表）、dependency-review.yml；加 Python 3.8-3.13 矩阵；加 OIDC PyPI trusted publisher（待用户在 pypi.org 注册）；加 manylinux Dockerfile 作为 v0.4.13+ 的脚手架。**完成于 v0.4.13**: manylinux wheel 已启用并发布（`par_runtime-0.4.13-py3-none-manylinux_2_28_x86_64.whl`，11.3 MB）。**未使用** dummy `_loader.c` —— 现代 auditwheel v6+ 默认开启 `allow_graft=True`，会扫描 wheel 内所有 ELF 文件（包括通过 `package_data` 提供的 ctypes-loaded `.so`），无需 dummy ext 制造 DT_NEEDED。**推迟到 v0.5.0 (MINOR)**: ARM64 Linux wheel、macOS universal2 wheel（新增平台 = MINOR per SemVer §7）。 |

---

## 9. 相关文档

- [`docs/v0.3-ROADMAP.md`](v0.3-ROADMAP.md) — 当前路线图
- [`README.md`](../README.md) — 项目入口
- [`DESIGN.md`](../DESIGN.md) — 实现设计
- [`AGENTS.md`](../AGENTS.md) — 开发者工作流

---

**最后更新**: 2026-06-26

---

## 10. 发布策略：Beta-First

**规则**：开发完成后，**永远先提交 beta 版**。只有在用户明确说"发布正式版"时，才执行 release 相关操作。

### 版本号约定

| 阶段 | 版本号格式 | 示例 |
|------|-----------|------|
| 开发/合并 | `X.Y.Z-beta-YYYYMMDD` | `0.5.0-beta-20260610` |
| 正式发布 | `X.Y.Z` | `0.5.0` |

### 工作流

1. **开发完成** → 版本号设为 `X.Y.Z-beta`，合并到 main，**不打 tag、不触发 CI release**
2. **用户说"发布正式版"** → 去掉 `-beta` 后缀，打 tag `vX.Y.Z`，推送触发 release pipeline

### Agent 必须遵守

- **禁止**在用户说"发布正式版"之前执行以下操作：
  - 去掉版本号后缀
  - 打 git tag
  - 触发 release workflow
  - 更新 README/CHANGES 中的正式版本号和 test count
- beta 阶段可以更新 CHANGES.md 添加 beta 条目，但版本号必须带 `-beta`

| 2026-06-21 | **v0.5.0 scope: ARM64 Linux + ARM64 macOS wheels** | 用户决策："那就开搞吧 v0.5.0"。**scope 锁定**: (1) `manylinux_2_28_aarch64` (新) — `ubuntu-22.04-arm64` runner + `quay.io/pypa/manylinux_2_28_aarch64` 容器 + auditwheel。**不**做 universal2 — `macos-13` (Intel) 2026-06-19 已永久放弃（free tier queue 24h+ 必超时，见 `.github/workflows/ci.yml` L16），Intel Mac 用户回退到 sdist 源码编译（PyPI 2026 流量 <5%，可接受）。**scope 排除**: musllinux wheels (≥95% PyPI Linux 由 manylinux 覆盖)、Windows wheel (MSVC 编译链过重)、`-manylinux_2_17` RHEL 7/CentOS 7（用户 2026-06-21 明确拒绝）。**CI 成本**: 3 job matrix, ~$0.18/release (x86_64 $0.08 + aarch64 $0.016 + macos-15 $0.08)。**SemVer**: MINOR (新增平台 = MINOR per SemVer §7，public API 不变)。**验证**: Oracle 终审必须确认 PyPI 3 wheels + GH Release 3 assets + acceptance CI 5 platforms (debian:12/ubuntu:22.04/ubuntu:24.04/debian:bookworm-arm64/macos-15) 全绿。 |

| 2026-06-21 | **v0.5.0 scope 修订 (实际交付)**: macOS arm64-only; ARM64 Linux 推到 v0.5.1+ | 用户决策："跳过 ARM64 Linux, 只发 x86_64 + macOS-arm64"。**根因**: GitHub Actions 免费 tier ARM64 runner 完全不可用 — `ubuntu-22.04-arm64` / `ubuntu-24.04-arm64` 都 queue 45min+ 从未派发；qemu-binfmt 在 `ubuntu-22.04` host 上跑 `quay.io/pypa/manylinux_2_28_aarch64:latest` 容器, 容器启动即崩溃 (`Error response from daemon: container is not running`)。**v0.5.0 实际交付**: 2 wheels — `par_runtime-0.5.0-py3-none-manylinux_2_28_x86_64.whl` (11.3 MB) + `par_runtime-0.5.0-py3-none-macosx_11_0_arm64.whl` (6.5 MB)。**v0.5.1+ 待办**: ARM64 Linux wheel — 等 (a) GH Actions ARM quota 改善, (b) 用户自建 self-hosted ARM runner, 或 (c) 切到 cross-compile toolchain。**技术细节**: macOS wheel 平台 tag 通过 `wheel tags --platform-tag macosx_11_0_arm64` 设置 — 单纯 mv 改文件名会导致 PyPI 400 (内部 WHEEL Tag field 必须匹配)。 |

| 2026-06-21 | **【待恢复】ARM64 Linux 轮子临时移除** | **范围级变更**: v0.5.0 原计划发布 3 个轮子 (x86_64 Linux + ARM64 Linux + ARM64 macOS)，实际只发布了 2 个 (x86_64 Linux + ARM64 macOS)。**根因**: GitHub Actions 免费 tier ARM64 runner (`ubuntu-22.04-arm64` / `ubuntu-24.04-arm64`) 饱和 queue 45min+ 从未派发; qemu-binfmt 在 x86_64 host 上跑 `quay.io/pypa/manylinux_2_28_aarch64:latest` 容器启动即崩溃 (`Error response from daemon: container is not running`)。**用户决策 2026-06-21**: 跳过 ARM64 Linux, 推到 v0.5.1+。**【强制恢复条件】**: 项目功能相对完善后 (预计 v0.6-v0.8 区间)，必须恢复 ARM64 Linux 轮子支持。恢复路径优先级: (1) 等待 GH Actions ARM 配额改善 (2) 用户自建 self-hosted ARM runner (3) 切换到 OCaml cross-compile toolchain + aarch64 sysroot。**恢复信号**: 出现以下任一情况时立即排期 — (a) ARM Linux 用户在 issue 报告 `pip install` 失败 (b) PyPI 下载统计显示 ARM Linux 需求 >5% (c) 项目发布 v1.0 前的 feature freeze 阶段。**技术债务记录**: `par_runtime-0.5.0-py3-none-manylinux_2_28_aarch64.whl` 的 wheel tag 格式、auditwheel 修复流程、manylinux_2_28_aarch64 容器路径已在 v0.5.0-beta.post1-post5 中验证过 (除 runner 可用性问题外其他都 ready)。恢复时参考 commit 6a12c01 (初始 3-job matrix) 和 90aae3b (qemu 尝试)。 |
| 2026-06-24 | **v0.5.2 战略反转: skill 系统移出 §7 防呆清单** | **项目成熟度** (runtime / agents / tools / middleware / persistence / RAG / streaming 全部 stable) + 下游项目需求。Skill 系统按 §3 差异化主张做了类型化设计 (typed `tool_filter` ADT, `skill_trigger` ADT, `expected_output` — 比 Claude Code 更类型化, 比 OpenAI 更 filesystem-native, 比 LangChain 更 success-criteria-aware)。**Scope locked in**: `docs/v0.5.2-ROADMAP.md` Track A. **可逆性**: 若下游需求证明为假, 重新加回 §7 该行 + revert Track A 代码即可。代价: 1 个 PR revert。 |
| 2026-06-26 | **【范围级变更】PostgreSQL 持久化后端移除 — SQLite only** | **变更前**: 三层持久化 (`Sqlite` 开发 / `Postgresql` 生产 / `Noop` 测试)，独立 `par_postgres` opam 包，`caqti-eio` 依赖，公开类型含 `` `Postgresql of string `` 变体，CLI `--db-uri` 指 PostgreSQL 连接串。**变更后**: 两层持久化 (`Sqlite` 唯一持久化后端 / `Noop` 测试)，删除 `par_postgres` opam 包，移除 `caqti-eio` 依赖，公开类型 `persistence : [ `Sqlite of string ]`（`` `Postgresql `` 变体移除，破坏性变更），CLI `--db-uri` 改指 SQLite 数据库路径。**原因**: (1) SQLite 对当前用户群 (LLM 后端工程师做单进程 agent) 已足够; (2) PG 后端长期受 FFI/CI 可用性困扰 (`postgresql` opam 包不在标准 repo, CI 需特殊排除); (3) 收窄维护面，集中精力到 §4 轴 #1/#2 (类型严谨 + 并发)。**影响范围**: 公开 `persistence` 类型 (对 pattern-match `` `Postgresql `` 的 SDK 用户是破坏性变更)、CLI `--db-uri` 语义、全部持久化相关文档 (EN + ZH)、opam 包面 (`par_postgres` 删除)、构建脚本 (不再需要 pg 客户端库)、`docs/rules/docs.md` + `docs/DOC-MAINTENANCE.md` 标识符保留清单 (移除 `par_postgres` + `` `Postgresql ``)。**对多实例水平扩展的影响**: SQLite 文件锁不支持跨容器多进程写同一文件——这是当前已知限制。双层持久化模型 (本地 SQLite + 远程 tier) 在路线图上 (v0.6+, bd issue `PAR-4dt`)，远程 tier 不再特指 Postgres (可能是对象存储或未来后端)。**回退方式**: 从 commit `cb5d795` (移除前) 恢复 `lib/postgres/` + `par_postgres.opam` + caqti-eio 依赖。详见 `CHANGES.md` v0.5.4-beta "Removed — PostgreSQL persistence backend"。 |
| 2026-06-27 | **【API级变更】v0.6.0: on_max_tokens_behavior ADT + max_continuation_chunks** | **变更前**: `finish_reason=Max_tokens` 时引擎无条件丢弃截断输出并盲目重发相同 prompt (v0.5.5-beta 修复为先检测内容再返回部分结果)。**变更后**: 新增 `type on_max_tokens_behavior = Retry | Continue | Return_partial` 公开 ADT + `on_max_tokens` + `max_continuation_chunks` 两个可选 `agent_config` 字段 + `Llm_response_truncated` 事件变体。默认 `Return_partial` (v0.5.5 Phase 1 行为)。**原因**: 三家头部产品调研发现业界对此无共识 — Claude Code 自动升档+重试3次 (最激进)、Codex CLI 盲目重试 (openai/codex#14753 已知 bug 未修)、MiMo Code 直接返回部分 (最克制)。PAR 的 typed ADT 方案是 §3 差异化主张 #1 (类型严谨) 的直接体现：比 Codex 的通用错误通道更精准，比 Claude Code 的硬编码常量更可配置。**影响范围**: `agent_config` 公开类型 (新增 2 个可选字段，通过 `make_agent` 的可选参数构造，keyword-arg 调用者不受影响)、`event` 类型 (新增 1 个变体，有 `[@@deriving yojson]`)、FFI JSON parser (`par_capi.ml`)、Python binding (零代码改动 — 纯 JSON 透传)。**回退方式**: 移除 `on_max_tokens_behavior` ADT + 2 个字段 + 事件变体，恢复 v0.5.5-beta engine.ml Max_tokens 分支。详见 `CHANGES.md` v0.6.0-beta "Added — Configurable on_max_tokens_behavior policy"。 |
| 2026-06-30 | **【API级变更】v0.6.3: Auto Context Compression by Window Ratio** | **变更前**: `context_strategy` 三种变体 (Truncate_oldest / Summarize / Sliding_window) 都是绝对阈值触发，无 ratio-based 自动压缩；`make_agent` 默认 `Sliding_window {max_messages=100; max_tokens=200000}`；`context_strategy` 在 FFI 中硬编码不可配置；引擎每次迭代无条件 apply strategy；模型 context window 大小全代码库无任何字段追踪；`Context_compressed` 事件类型不存在。**变更后**: 新增 3 个 `agent_config` 可选字段 (`context_compression_threshold : float option` 默认 `Some 0.8` / `compression_cooldown_messages : int option` 默认 `Some 6` / `context_window_override : int option`)，新增 `llm_service.context_window_fn : (unit -> int) option` capability，新增 `Context_compressed` + `Context_compression_skipped` 两个 event 变体 (后者带 typed `` `Below_threshold | `Cooldown_active | `No_window_size | `No_strategy `` 多态变体 reason)，新增 `Context_manager` 5 个 pure helpers (`default_context_window` 静态查表 / `resolve_context_window` 三层 resolver / `estimated_tokens_with_margin` 1.2× 余量 / `should_compress` 纯决策函数 / `apply_default_summarize`)，`make_agent` 默认 `context_strategy` 从 `Sliding_window` 改为 `Summarize {max_tokens=8000; summary_model=None}` (BREAKING)，引擎 `engine.ml:517` 加入 ratio gate + cooldown ref + 事件发射，FFI JSON parser 解析 4 个字段。**原因**: 业界调研 (librarian bg_940617fc) 确认所有有默认的主流生产 agent 框架均用 LLM-summarize (Letta `sliding_window` mode / Anthropic `compact_20260112` / LangChain `ConversationSummaryBufferMemory` / CrewAI `respect_context_window=True`)，零个用 truncate-drop。PAR 80% pre-emptive trigger 优于 Letta/CrewAI 的 reactive-on-error。typed skip-reason ADT 是 §3 差异化主张 #1 (类型严谨) 的直接体现。**影响范围**: `agent_config` 公开类型 (新增 3 个可选字段)、`llm_service` (新增 capability 字段，所有 3 个构造站点更新)、`event` 类型 (新增 2 个变体 + 1 个 named polymorphic variant type)、`Engine.run_agent` (ReAct loop 加入 ratio gate + cooldown ref)、`Runtime.make_agent` (3 个新可选参数 + 默认 strategy 改变)、FFI JSON parser (`par_capi.ml`)、Python binding (零代码改动 — JSON 透传)。**回退方式**: 移除 3 个 agent_config 字段 + llm_service.capability + 2 个 event 变体 + Context_manager helpers + engine.ml ratio gate；恢复 `make_agent` 默认 `Sliding_window`。详见 `CHANGES.md` v0.6.3-beta "Auto Context Compression by Window Ratio"。 |
| 2026-06-30 | **【战略级变更】新增 §11 开发原则:"一次做对"** | **变更前**: STRATEGY.md 无显式开发原则段;规划决策常以"范围可控/周期短"为由牺牲长期架构正确性,工程妥协与架构决策混为一谈。**变更后**: 新增 §11《开发原则》段,确立"一次做对"为核心原则,要求所有架构决策优先长期正确性,禁止用范围/周期作为架构妥协的借口,工程妥协必须显式标注并附长期替代方案。**原因**: v0.6.4 规划时 agent 提出 4 条决策(message flatten 保留 / Stable-Volatile 仅 template 生效 / Auto-caching 自动标 / 永久 soft-fail),用户挑战"抛开周期与范围是否仍这样决策"后,发现 3 条是工程妥协伪装成架构决策。此为复发模式,必须升级为战略级原则。**影响范围**: 所有版本规划、ROADMAP 编写、架构决策记录、agent 规划行为。AGENTS.md 同步加引用让每次规划可见。**回退方式**: 删除 §11 + AGENTS.md 引用 + 本行变更日志。 |
| 2026-06-30 | **【API级变更】v0.6.4-beta (partial): content_block list + prompt caching infrastructure** | **变更前**: `message.content : string option` 扁平字符串;`usage_stats` 3 字段;无 `cache_control`/`cache_ttl`/`content_block` 类型;无 `cache_strategy` ADT;无 `cache_control_fn` capability;无 `prompt_cache_key`;无 cache event 变体。**变更后**(Track A-G+E 完成): 新增 `content_block` ADT(4 变体,each with `cache_control option`)、`cache_control`、`cache_ttl`、`image_source` 类型;`message.content` → `message.content_blocks : content_block list`(BREAKING);`usage_stats` 扩展到 6 字段(BREAKING);新增 `cache_strategy` ADT on `agent_config`(BREAKING);`llm_service.cache_control_fn` capability(BREAKING);`Openai.prompt_cache_key`(BREAKING);Anthropic adapter 发射 cache_control wire markers;OpenAI adapter 解析 cached_tokens + 注入 prompt_cache_key;5 个新 cache event 变体;`Cache_breakpoint` budget manager 模块;`Message` helper 模块。**未完成**: Track B(Stable/Volatile phantom types — 需要 OCaml existential record field 类型设计)、Track H(新测试文件)。**影响范围**: 43 文件改动,465 insertions,198 deletions。**回退方式**: revert commits b4a721d + b827690。 |
| 2026-07-02 | **【API级变更+架构级变更】v0.6.5-beta: Workspace 模块 — Sys.getcwd 从安全原语中放逐** | **变更前**: `Bash_safe_command.sandboxed_path_of_string` 以 `Sys.getcwd()` (进程全局 ambient state) 为安全锚点;绝对路径在类型层被硬拒;6 个文件工具 (read/ls/find/grep/write/edit) 各自内联 3-check 但**缺少敏感前缀检查**;`sensitive_prefixes()` 是全局函数 (第二 ambient 权威向量);`Runtime.create` 无 workspace 参数。**变更后**: 新增 `Workspace` 模块 (`lib/core/workspace.ml`) — 不可伪造 `private` 值,携带 `roots : string list` (多根,从第一天起) + `policy : workspace_policy` (敏感前缀随 workspace 走);`admit` 函数替代 `sandboxed_path_of_string` — workspace 参数 mandatory,**绝对路径在 workspace 根下被放行** (核心行为变更);`sandboxed_path` 类型移至 Workspace;`sandboxed_path_of_string`/`_cwd`/`_to_string` 全删;`make_exec` cwd 改 mandatory;`Runtime.create` 新增 `?workspace:Workspace.workspace` 可选参数 (下游集成商可注入自定义 workspace 实现多 worktree 隔离);`Sys.getcwd()` 仅剩 `Workspace.of_cwd` 一处 bootstrap + 3 个便利定位点 (skill_loader/par_capi/main)。**§11 R1 标注**: 架构正确 (非范围妥协) — workspace 作为唯一路径权威是终态设计,多根从第一天起,无 ambient authority。**§11 R3 评估**: 单步完成 (新模块 + 所有调用点一次迁移),非两步走。**原因**: 下游集成反馈 (worktree-per-task 工作流) 暴露 CWD-anchored sandbox 的结构性冲突 — 一个进程无法服务多个 worktree;与 Claude Code #26262 同源问题。Oracle 架构咨询确认 `Sys.getcwd()` 作为安全锚点是 ambient authority 反模式,Option E (workspace 抽象) 是正确的终态。**影响范围**: `Bash_safe_command` 公开 API (类型迁移 + 3 函数删除,8 项破坏性变更 — 见 CHANGES.md 迁移表)、`Builtin_tools.builtin_tools` (新增 `~workspace` mandatory 参数)、`Workflow_engine.exec_context` (新增 `workspace` mandatory 字段)、`Runtime.create` (新增 `?workspace` 可选参数)、`Runtime.runtime` record (新增 `workspace` 字段)、6 个文件工具 (路径验证统一走 `Workspace.admit`,获得此前缺失的敏感前缀检查 — 安全提升)。1253 tests passing。**回退方式**: revert commit 8a2b55e + 后续修复 commits。详见 `CHANGES.md` v0.6.5-beta "[UNRELEASED] — Workspace Abstraction"。 |
| 2026-07-02 | **【API级变更】v0.6.4-beta.2-beta.5: prompt caching 完成版** | **变更前**: v0.6.4-beta (partial) 的 Track B/H 未完成;Anthropic adapter 的 `extract_system_prompt` 压扁 system prompt 为裸字符串导致 cache_control 标记丢失;`tool_descriptor_to_json` 不 emit cache_control;`build_message_json` 仅处理 Text_block;FFI `parse_cache_strategy` bare "with_cache_of" 静默降级为 No_caching;FFI skill_prompt_zone 不可从 Python 达达。**变更后**: (1) Runtime zone_tag 方式落地(commit 6a22c7f)— phantom types 被 OCaml record field 限制排除,runtime `zone_tag` 是架构正确方案。(2) `mark_tool`/`mark_message` 用户层 API 落地。(3) `skill_prompt_zone` ADT (Stable_prompt/Volatile_prompt/Both_prompts) 替代 `string option`。(4) B.4 hard-fail 升级(原计划 v0.6.5,用户指令提前到 v0.6.4)。(5) Anthropic adapter `emit_block_with_cache` 全 4 block variants + `extract_system_prompt` 返回 `content_block list` + `tool_descriptor_to_json` emit cache_control + `build_request_body` emit system as List。(6) FFI 2 bug 修复(parse_cache_strategy fail-fast + skill_prompt_zone 3-form parser)。(7) `apply_breakpoints` 移除 Tool-location namespace 混淆。(8) `Both_prompts` 语义修正(拼接 stable+volatile)。**影响范围**: 累计 60+ 文件,1228 tests。**回退方式**: revert commits 7016172..cf6ac09。**Oracle 验证**: 两轮 VERIFIED,真实 API 验证通过(MiniMax 端点接受 cache_control 格式)。 |
| 2026-07-02 | **【API级变更】v0.6.6-beta: per-run workspace override (闭合 v0.6.5 Option E 缺口)** | **变更前**: v0.6.5 落地了 `Workspace` 抽象与 `Runtime.create ?workspace`,但 `invoke`/`submit_workflow`/`submit_workflow_async`/`invoke_workflow_sync` 四个公共入口的签名里**没有** `?workspace` 参数 — 它们只接收 runtime,workspace 在 runtime 建好时固定。一个 agent-server 进程建一个 runtime → 一个 workspace → 该进程所有 workflow/invoke 共享同一 workspace,无法并发服务 N 个 worktree。Oracle Option E 审计明确指出 "workspace is property of the run, not the process" 未实现。**变更后**: 四个公共入口均接受 `?workspace:Workspace.workspace` 可选参数;`per_call_registry ~rt ~workspace` 为每次调用构建 fresh `Tool_registry` — copy_all 用户工具后,用 `rt.bash_rebuild` 重建 bash handler + `rt.file_tools_rebuild` 重建文件工具 (read/ls/find/grep/write/edit),全部绑定到 `rt' = {rt with workspace}`;`handler_fn` 签名**不变** (避免 30+ 文件级联);`Tool_registry.copy_all` 新增;`Runtime.register_file_tools_rebuild` 暴露给注册 builtin 工具的调用方 (bin/main.ml 捕获 Eio switch+net)。**§11 R1 标注**: 架构正确 (per-call registry 比 handler_fn 签名改更干净 — workspace 是 run-scoped 非 call-scoped)。**§11 R3 评估**: 单步完成。**§11 R2 范围妥协 (Decision #4)**: 用户自定义工具 (via `register_tool`) 的 per-call 覆盖推迟到 v0.7 (register_tool 签名改是 SemVer 破坏,触发条件: v0.7 周期或下游反馈)。**Oracle 验证**: 两轮 (首轮 REJECT 文件工具未覆盖 + 缺 e2e 测试 → 修复 file_tools_rebuild + e2e invoke Mock 测试 → 二轮 VERIFIED)。**影响范围**: runtime.mli/ml (4 API 入口 + per_call_registry + 2 rebuild 字段)、tool_registry.ml/mli (copy_all)、bin/main.ml (register_file_tools_rebuild)、6 个新测试。1260 tests passing。无 breaking change。**回退方式**: revert commits 0a8331e..89ccc77;`?workspace` 参数移除即恢复 v0.6.5 行为。 |
| 2026-07-03 | **【范围级变更】v0.6.7-beta: 删除 CLI (产品 UX 下沉到独立 PAR Code 仓库)** | **变更前**: PAR 仓库自带 CLI 应用 (`bin/main.ml` 1741 行 — REPL、config 向导、ask/history/stats/工具注册全套)。一个 agent-runtime 仓库自带产品级 UX,造成 (a) 用户困惑: 该用 `par` 还是 PAR Code?(b) 维护分心: 引擎团队维护产品级 CLI;(c) 定位模糊: PAR 是引擎还是产品?`install.sh` 175 行从 GH Releases 下载 CLI 二进制。README hero 段以 `curl \| bash → par ask` 开头;`docs/cli.md`、`par_cli` opam 包、4 个 CLI 测试 (`test_cli_args`/`test_cli_dispatch`/`test_session_resume_cli`) 全存在。**变更后**: 删除整个 `bin/`、`par_cli` opam 包 + `par_cli.opam`、CLI 测试、`docs/cli.md`;重写 `install.sh` 为交互式 SDK 安装向导 (检测系统 → 选 Python(1) vs OCaml(2) → 验环境 → 用户确认后缺 opam 自动跑官方安装脚本到 `~/.opam` → 装 → 验证);`install-dev` 改用 Python `par_runtime.__version__` 校验;CI 5 个 workflow 全部清 `par_cli` 引用 (`ci.yml`/`nightly.yml`/`opam-publish.yml`/`pypi-publish.yml` 改 `opam install par`;`release.yml` 删除 binary build/upload,转为 release notes 引导 `pip install` / `opam install par`);README hero 段 SDK-first (Python+OCaml),`docs/index.md` 移除 CLI section。`par_cli` 此前**未成功发布**到 opam-repository (v0.4.8 时期提交过 PR,但从未合并),所以删除零外部影响——CHANGES.md 记录这次移除,opam-repository 无需撤包。**§11 R1 标注**: 架构正确——分层清洁化(引擎归引擎、产品归产品);PAR 是 SDK/运行时,不是产品。**§11 R3 评估**: 单步完成(无需两步走,无外部用户)。**§11 R2**: 不适用(无范围妥协,这是分层修正)。**影响范围**: `bin/` 删除 (1741 行+4 个辅助文件)、`par_cli` 包 + 5 个 CI workflow + Makefile install 目标 + AGENTS.md + README + `docs/cli.md` + `docs/index.md` + 4 个测试 + 顶层配置(总计 ~25 文件)。1248 tests pass (1260 - 12 个 CLI 测试用例)。**回退方式**: revert commits 23697fc..c472413;恢复 `bin/`、`par_cli` 包、CI workflow 与 makefile 原状。 |
| 2026-07-09 | **【API级+架构级+依赖级+范围级变更】v0.7.0-beta: Document Loaders Framework — RAG 前置阶段补齐** | **变更前**: PAR 已有完整 RAG 基础设施(`Vector_store` sqlite-vec 后端 + `Chunking` 3 策略 + `embedding_service` + `Runtime.invoke_with_rag`),但管道只接受裸字符串——用户必须自己把 PDF/HTML/CSV 读成 string 再喂进 `add_documents`。这是 LangChain `DocumentLoader` 占据的位置(81k+ 仓库使用)。**变更后**: 新增 `lib/documents/` 子目录(7 模块,14 文件,≤16 上限留余量)—— (1) `Document.t` record(`content:string; metadata:(string,Yojson.Safe.t) Hashtbl.t; source:string`)+ `Meta` 子模块(empty/singleton/add/add_string/add_int/to_yojson/of_yojson)+ `module type LOADER`(`lazy_load:unit -> Document.t Seq.t` 为 canonical,`load:unit -> Document.t list` 为便利)+ `load_error` ADT(5 变体);(2) 5 个格式 loader(TDD):`Text_loader`/`Markdown_loader`(YAML frontmatter via `Yaml`)/`Html_loader`(`lambdasoup` 剥离 script/style/nav)/`Csv_loader`(row-per-Document,列名→metadata)/`Pdf_loader`(camlpdf `Pdftext` 简单抽取,每页一 Document);(3) `Directory_loader` 扩展名→loader 关联表(LlamaIndex 模式)+ `default_map`;(4) Python FFI 5 层链(`par_capi.ml` 的 `do_load_document`/`do_load_directory` + `Callback.register` → `par_ffi.h/.c` C bridge `call2_exn`/`call3_exn` → `_ffi.py` ctypes → `runtime.py` `Runtime.load_document`/`load_directory`)返回 JSON list of `{content, metadata, source}` dicts 可直接喂 `add_documents()`;(5) 3 个新 deps(`camlpdf`/`csv`/`omd`,全 LGPL+OCaml-linking-exception 或 ISC,MIT 兼容)。**§11 R1 标注(12 条决策)**: 全部架构正确——`lib/documents/` 新子模块而非 `lib/core/document_loader.ml` 单文件(`lib/core/` 已 53 文件超舒适区);`Document.t` 不进 `types.ml`(已 1259 行超 800 静态上限);字段名 `content` 而非 LangChain `page_content`(内部一致性 > Python 历史包袱,与 `Vector_store.document.content` 对齐零摩擦);`lazy_load` canonical(LangChain 现代 API 已 deprecated `load_and_split`);Chunking 保持独立(LangChain 自己 deprecate `load_and_split`,组合优于耦合);extension→loader 关联表(OCaml-idiomatic);metadata `(string, Yojson.Safe.t) Hashtbl.t`(与 `Vector_store.document.metadata` 对齐);MINOR bump(SemVer §7,纯新增零破坏)。**§11 R2 范围妥协(2 条,R2 合规)**: (D8) `.docx` 推迟到 v0.7.1——无 maintained OCaml 库存在,DIY(camlzip+xml-light ~200 LOC)是伪装架构的范围妥协,ship 即成永久维护负担,**退役触发**:opam 出现 maintained 库 / downstream >5 reactions / v0.7.1 规划周期,三选一;迁移代价低(独立模块,零现有代码改动)。(D9) PDF 简单 text stream 抽取而非 layout-preserving——多栏/表格/scanned PDF 抽取质量差,**退役触发**:downstream 真实语料抽取失败率 >20% 或 v0.8 周期;迁移路径:替换 `Pdf_loader.extract_text` 内部实现为 layout-aware(接口不变);mli docstring + docs/sdk/document_loaders.md EN+ZH 都明示限制。**§11 R3 评估**: 5 loader + 共享 `Document.t`/`LOADER` 契约一次 ship(分批无收益);.docx 推迟属 R3 exception(c)"未知技术验证"(spike-first 决定),非范围妥协伪装。**§11 R4 自问**: 12 条决策全部过"抛开周期与范围,长远用户怎么用更爽"测试;2 处真妥协已附退役计划与触发条件。**原因**: README "Coming next" 已预告 v0.7+ 方向(external vector stores / document loaders / multimodal);连续 5 个 patch(v0.6.5→v0.6.9)打磨引擎本身边际收益递减,需要新能力解锁真实场景。**影响范围**: 新增 `lib/documents/`(14 文件)+ `lib/par.ml`(+8 module re-exports)+ `lib/ffi/`(`par_capi.ml`+`par_ffi.h/.c`)+ `bindings/python/`(2 文件 + 1 新测试)+ `docs/sdk/document_loaders.md` EN+ZH + `docs/{index,zh/index}.md` + `mkdocs.yml` + `README.md`+`docs/zh/README.md` + `CHANGES.md` + `dune-project`+`par.opam`+`lib/dune`(deps)。1269 OCaml tests + 8 Python tests passing(0 failures)。零破坏性变更。**回退方式**: revert commits c0589b2..f6ce927(6 个原子 commits);`lib/documents/` 整目录删除 + `lib/par.ml`/`test/dune` 还原 + dune-project deps 行删除,完全恢复 v0.6.9 行为。详见 `CHANGES.md` v0.7.0-beta "Document Loaders Framework"。 |

| 2026-07-09 | **【API级+架构级变更】v0.7.1-beta: Concurrency + Memory + Scope + Deprecation + Dynamic Prompt** | `invoke_context` per-call 隔离(Eio.Fiber carrier)+ `invoke_async`;`Memory_service`(FTS5)+ 3 builtin tools;`Agent_call response_schema`;persistence `scope` 维度;`Deprecation.warn_once`;per-turn `system_prompt_appendix`;Auto-skill override fix;FFI persistence fix。1387 tests。**审计(2026-07-10)**: 17 issues(2 critical: `invoke_structured` 绕过 Invoke_context + `run_structured` 不注入 appendix)。详见 `docs/audit/v0.7.x-findings.md`。 |
| 2026-07-10 | **【API级+架构级+范围级变更】v0.7.2-beta: Windows Capability + Vector Memory + SDK Docs** | `Capability` 模块(平台能力检测)+ FFI `#ifdef _WIN32`(SRWLOCK)+ workspace 路径归一化 + 进程生成门控 + vec0.dll vendor;vec0 虚拟表 + `search_mode`(Keyword/Vector/Hybrid/Auto)+ RRF hybrid search + sync triggers;SDK 文档全套 EN+ZH。CI: Ubuntu ✅ + macOS ✅。Windows CI 移除(MinGW `par_ffi.c:121` 指针类型错误,待 v0.7.3)。**审计(2026-07-10)**: 20 issues(2 P0: Auto 死代码 + update 泄漏)。详见 `docs/audit/v0.7.x-findings.md`。 |
| 2026-07-10 | **【审计记录】v0.7.0–v0.7.2 全量审计** | 4 agent 并行审计 → 48 去重问题(10 P0 + 6 P1 + 10 P2 + 12 P3)。Oracle 验证 8/8 spot-check。核心: Auto 死代码 + update 不删旧行 + invoke_structured 绕过 Invoke_context + 5 FFI 锁内分配 + 10 文档签名错误。完整在 `docs/audit/v0.7.x-findings.md`。 |

---

## 11. 开发原则

**"一次做对"(Do It Right Once)** —— 本项目规划与架构决策的核心原则,2026-06-30 确立。

### 11.1 原则表述

> 当短期工程妥协与长期架构正确性冲突时,**选长期正确性**。
>
> 不允许"v0.X 妥协 + v0.X+1 重构"的双步走,**除非有强证据证明单步不可行**。
>
> 范围可以扩大,周期可以延长,但**架构不能为范围妥协**。

### 11.2 可操作规则(强制)

**R1. 决策论证必须区分"技术正确"与"范围妥协"**
- 提出任何决策时,必须明确标注该决策的性质:
  - **架构正确**:基于技术客观性的决策。例如"4-cap 是外部 API 合约,不该用类型系统固化"。
  - **范围妥协**:为控制单版本范围而做的让步。例如"先保留 flatten,v0.7 再引入 content_block list"。
- **禁止把范围妥协伪装成架构决策**。这是本项目最严重的规划错误。

**R2. 范围妥协必须附长期替代方案 + 触发条件**
- 如果决定走范围妥协路线,必须记录:
  - 长期正确的方案是什么
  - 什么时候触发迁移(版本号、信号、依赖项)
  - 迁移代价估算
- 没有"等以后再说"的妥协。每个妥协必须有具体的退役计划。

**R3. "扩大范围做对" vs "分两步走"的判断准则**
- **默认选"一次做对"**,扩大范围。
- 仅在以下情况允许分两步:
  1. 单步会破坏 SemVer 重大约束(如同时改 5+ 个核心公开类型)
  2. 单步需要未完成的上游依赖(如 native Gemini adapter 还没写)
  3. 单步需要未知技术验证(用 spike 先验)
  4. 用户明确指示分步(本条不能由 agent 自决)
- 即使分步,第一步也必须**为第二步铺路**(API 设计兼容最终形态),不能挖坑。

**R4. agent 主动挑战义务**
- 规划阶段,agent 必须**主动自我挑战**:
  > "抛开开发周期和范围,只考虑长远规划和用户怎么用更爽,这个决策还成立吗?"
- 如果答案是"不成立",必须**主动提出翻盘方案**给用户,而不是等用户挑战。
- 用户挑战后才发现的妥协,是 agent 规划失职。

**R5. 适用范围**
- 本原则适用于:**架构决策、类型设计、API 设计、公开类型变更、ROADMAP scope 锁定**。
- 本原则**不适用于**:bugfix(永远最小化改动)、文档微调、CI 配置、依赖升级(这些走各自的标准流程)。

### 11.3 验证检查(每个版本规划阶段必过)

写 ROADMAP 时,对每条关键决策问以下问题:

- [ ] 这是架构正确,还是范围妥协?
- [ ] 如果是范围妥协,长期方案是什么?何时触发迁移?
- [ ] 抛开周期与范围,这个决策还成立吗?
- [ ] 如果不成立,我是否主动提出了翻盘方案?

**未通过此检查的 ROADMAP 不能定稿。**

### 11.4 历史教训(2026-06-30 v0.6.4 规划案例)

v0.6.4 prompt caching 规划时,agent 提出 4 条决策:

| # | 原"决策" | 性质 | 长期正确做法 |
|---|---|---|---|
| 1 | 保留 `message.content : string option` 扁平,不引入 `content_block list` | **范围妥协**(伪装架构) | 引入 `content_block list`,给 multimodal + per-block cache_control 铺路 |
| 2 | Stable/Volatile 仅对 `system_prompt_template` 生效 | **范围妥协**(漏掉主要 bug 来源) | `stable`/`volatile` 应是 `system_prompt` 显式类型属性,所有用户必须声明 |
| 3 | `Auto_caching` 策略自动标 last-tool + last-message | **范围妥协**(自作主张) | 用户显式 `mark_cache_breakpoint`,PAR 不猜 |
| 4 | 永久 soft-fail(模板有 volatile builtin 时静默跳过) | **范围妥协**(把类型保证降级成 runtime hint) | v0.6.4 soft 过渡 → v0.6.5 hard fail(构造期拒绝) |

用户挑战后,4 条全部翻盘,scope 扩大。此案例确立 §11 原则,避免复发。
