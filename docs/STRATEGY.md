# P-A-R 长期战略

**状态**: 战略定义完成（2026-06-02）
**维护者**: P-A-R Contributors
**变更机制**: 战略变更需要新文档 + commit message 明确说明原因

---

## 1. 价值定位

**PAR = OCaml 圈的 LangChain + LangGraph 等价物**

覆盖两类场景：
- **MVP 友好**：问答机器人、翻译工具、基础 RAG
- **严肃生产**：8 状态机、Human-in-the-Loop、多 agent 协作

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

### vs AutoGen
- 不做多 agent 协作（v0.x 不做）

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
| [LangChain](https://github.com/langchain-ai/langchain) | system_prompt 单字符串模式、集成组件范式 | 过度抽象、Python 动态类型 |
| [Vercel AI SDK](https://github.com/vercel/ai) | system 独立属性设计、provider 抽象 | 不需要（Vercel 绑定云） |
| [LiteLLM](https://github.com/BerriAI/litellm) | 透传到 provider 模式 | messages 数组风格（我们用单一字符串） |

---

## 7. 防呆清单（明确不做的）

| 项目 | 不做的理由 |
|------|----------|
| Session tree + branching | PAR 用户用 workflow + PG 持久化，不是交互式 IDE |
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

---

## 9. 相关文档

- [`docs/v0.3-ROADMAP.md`](v0.3-ROADMAP.md) — 当前路线图
- [`README.md`](../README.md) — 项目入口
- [`DESIGN.md`](../DESIGN.md) — 实现设计
- [`AGENTS.md`](../AGENTS.md) — 开发者工作流

---

**最后更新**: 2026-06-02
