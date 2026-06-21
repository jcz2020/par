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
| Skills system (SKILL.md) | 产品决策，不是 SDK 决策 |
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
| 2026-06-21 | v0.4.8 stable 发布 | 首个 stable release（Runtime.invoke_structured）。GH Release + opam-repo PR #30086 已提交；PyPI 待上传。**关键里程碑：项目首次进入"用户可安装"状态** |
| 2026-06-21 | 分发渠道首次落地 | opam-repo PR 提交（ocaml/opam-repository#30086，含 `par` + `par_cli`），GH Release binaries (linux-x64, macos-arm64) 首次提供，install.sh 验证可装。PyPI `par-runtime` 待用户配置 token 后上传 |
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

**最后更新**: 2026-06-21

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
