# PAR 架构决策档案 (DECISIONS)

**目的**: 记录影响公共 API、类型设计、模块结构、ROADMAP scope 的重大决策。每条决策含背景、理由、§11 R1 标注、escalation trigger、回退方式。防止未来重复讨论已决事项。

**关联**: [STRATEGY.md](STRATEGY.md) §11 开发原则 | [v0.9-ROADMAP.md](v0.9-ROADMAP.md)

---

## 决策索引

| 日期 | # | 决策 | 性质 | §11 R1 标注 |
|---|---|---|---|---|
| 2026-07-29 | 1 | 拒绝 Plan 一等公民提案（按提案形状） | API 级 + 架构级 | 架构正确 |
| 2026-07-29 | 2 | 拒绝 Mode 一等公民提案，增强 Skill 替代 | API 级 + 架构级 | 架构正确 |
| 2026-07-29 | 3 | 接受 P2：暴露 `memory_object` 的 `last_used_at` / `usage_count` | API 级 | 架构正确 |
| 2026-07-29 | 4 | 拒绝 P3：`memory_object.t` 的 `scope` 字段已存在 | 事实纠正 | 不适用 |

---

## #1: 拒绝 Plan 一等公民提案

**日期**: 2026-07-29
**触发**: 下游编码 agent 集成反馈
**调研**: 5 个并行 agent（3 explore + 2 librarian）+ 两轮 Oracle 架构审查 + 源码逐行核验 + 6 框架业界对比 + 8 生产产品模式研究

### 提案摘要

下游提议新增 `Plan` 类型（字段 `goal / approach / files_to_touch / steps / risks / status`），SQLite 持久化，`register_plan / get_plan / list_plans / update_plan_status` API，`Runtime.invoke` 加 `?plan_id` 参数，`Draft → Active → Completed/Abandoned` 生命周期。

### 决策：拒绝（按提案形状）

### 理由（4 条，均经源码 + 业界证据核验）

**1. `files_to_touch` 是产品概念泄漏，不是 runtime 抽象**

字段 `files_to_touch` 是编码 agent 专有概念。PAR STRATEGY.md §2 明确目标用户是"LLM 后端工程师"（覆盖全场景），不是"编码 agent 开发者"。把产品形态字段固化进 runtime 违反 §11 R4（"抛开范围是否还成立"——答案：不成立）。

**§11 R1 标注**：提案是**范围妥协伪装成架构决策**（把下游产品概念包装成 runtime 一等公民）。

**2. 业界 6 大框架 + 8 大生产产品零例外用应用层工具实现 plan**

| 维度 | 证据 |
|---|---|
| 6 大通用框架 | LangGraph / OpenAI Agents SDK / AutoGen / Google ADK / CrewAI / PydanticAI — **0/6 有强制 Plan 类型**；2/6 有 opt-in Plan（CrewAI `PlanStep`、PydanticAI `Planning` capability） |
| 4 大编码 agent | LangChain open-swe（`plan_mode: bool` + `PlanModeExcludedTools` middleware + `/workspace/plans/*.md`）/ ByteDance deer-flow / HKUDS OpenSpace / claude-code-from-scratch — **全部用 boolean flag + middleware + markdown 文件存储**，零个用用户可注册的 runtime Plan 类型 |
| 8 大生产产品 | Claude Code TodoWrite / Aider / Cursor / Devin / AutoGPT / LangChain v1 TodoListMiddleware / ruflo / Google Cloud Concierge — **全部用应用层工具**，agent 调 `TodoWrite(plan_items)` 更新 state |

**关键发现**：编码 agent 领域 `plan_mode` / `permission_mode` 是普遍模式（open-swe / deerflow / OpenSpace / claude-code-from-scratch 都有），但全部是 **(a) 布尔/短字符串 flag + (b) 硬编码模式 + (c) markdown 文件存储**——零个是用户可注册的 runtime 类型。这**更强力地支持**"用应用层工具实现"的结论。

**3. PAR 现有原语已覆盖 Plan 的生产实现路径**

| Plan 需求 | PAR 现有覆盖 |
|---|---|
| agent 创建/更新/读取 plan | `register_tool` 注册 `plan_read` / `plan_write` 工具（参考 Claude Code TodoWrite 模式） |
| plan 跨 session 持久化 | `memory_service`（FTS5 搜索 + SQLite 持久化），`scope = "plan:<id>"` |
| 多 subagent 共享同一 plan | 同一 runtime 共享 `memory_service`，天然达成 |
| plan 进度跟踪 | `task_state`（8 态状态机 + SQLite 持久化 + Task_* 事件） |
| plan 编排 | `workflow`（sequential / parallel / conditional / map_reduce） |

已验证：技术上无阻塞。设计决策：`memory_object.scope` 用 workspace-level 值（非 session-level）以跨 session 共享。

**4. Workflow 静态 DAG 的真实 gap 不需要新 Plan 类型来解决**

下游核心痛点之一是"workflow 不能运行时变异（agent 跑完一轮发现要改方案）"。已核验 `workflow_step` 是不可变递归 ADT，0 个 add/remove/replace API——**gap 真实存在**。但解决方案不是 Plan 类型，而是：
- **首选**：plan 存 workflow variables，workflow 用 Conditional + 变量驱动分支（LangGraph 模式："state IS the plan"）
- **次选**：bounded `Loop` step 变体（不是 mutable DAG——后者破坏 checkpoint / 确定性重放 / 并发安全三保证）
- **验证方法**：2 周联合 spike（见 v0.9-ROADMAP Track D）

### 替代方案（已纳入 v0.9-ROADMAP）

下游用 PAR 现有原语自建 `plan_read` / `plan_write` 工具——参考 Claude Code TodoWrite / LangChain v1 TodoListMiddleware 模式。PAR 侧配合做 2 周 spike 验证 workflow 能否满足"可变 plan"需求。

### Escalation Trigger（何时重评）

出现以下任一情况时，重新评估"是否引入 runtime Plan 类型"：

1. **CrewAI 或 LangGraph 演进出 rich Plan 类型并成为 de-facto 标准** → 季度监控
2. **非编码 agent 用户请求 Plan 且 shape 不同**（如研究 agent 的 hypothesis/experiment/conclusion 生命周期）→ "产品概念泄漏"论点弱化
3. **2 周 spike 证明**：app 层 plan 工具 + workflow + memory_service 组合**无法满足**下游核心需求（运行时 plan 变异 + 多 agent 共享 + 跨 session 持久化）

### 回退方式

不适用（拒绝提案，无代码变更）。

---

## #2: 拒绝 Mode 一等公民提案，增强 Skill 替代

**日期**: 2026-07-29
**触发**: 同 #1
**调研**: 同 #1

### 提案摘要

下游提议 `Runtime` 和 `invoke_context` 加 `mode : string` 字段（与 `agent_id` 解耦），`register_mode ~id ~allowed_tools ~prompt_fragment` API，`set_mode` 触发 `Mode_entered / Mode_exited` 事件，mode 随 session 持久化。

### 决策：拒绝（作为独立类型）。用 Skill 系统增强替代。

### 理由（3 条）

**1. Skill 系统的数据模型是 Mode 提案的超集**

已源码核验（`types.mli:299-351`）：

| Mode 提案字段 | Skill 等价 |
|---|---|
| `allowed_tools` | `skill_effect.tool_filter_overlay`（`All_tools \| Only \| Except`） |
| `prompt_fragment` | `skill_effect.system_prompt_override`（`Stable_prompt \| Volatile_prompt \| Both_prompts`） |
| `set_mode` | `Runtime.set_user_activated_skills rt ["id"]` |
| `register_mode` | `Runtime.register_skill rt descriptor` |
| `Mode_entered / Mode_exited` 事件 | **缺**（见下文 E2） |

Skill 组合语义：`tool_filter` = 交集（最严格者赢），`system_prompt_override` = 后者覆盖前者。

**2. 引入 Mode 会创建与 Skill 并行的重复系统**

§11 R1 标注：**架构不正确**。两套系统做同一件事（行为切换），用户须学两个，组合语义爆炸（Skill `tool_filter` 和 Mode `allowed_tools` 取交集还是并集？文档无法自洽）。违反 STRATEGY.md §3 差异化主张 #1（类型严谨）。

**3. 业界 6 大框架零个有用户可注册的 Mode 类型**

LangGraph（conditional edges）/ OpenAI Agents SDK（Handoffs）/ AutoGen（SelectorGroupChat）/ Google ADK（`RoutedAgent` routing function）/ CrewAI / PydanticAI — **0/6 有用户可注册的 Mode 类型**。通用模式是"不同行为 = 不同 agent + 路由"。

注意：编码 agent 领域的 `permission_mode`（Claude Code / OpenSpace）是 mutually-exclusive 的硬编码模式，不是用户可注册类型。PAR 的 Skill（用户可注册 + 可组合）实际上**比这些更灵活**。

### Skill 系统的 4 个真实 UX gap（需修补，不是新抽象）

调研中发现 Skill 系统虽有 Mode 的数据模型，但 UX 有 4 个缺口：

| Gap | 详情 | 修复（纳入 v0.9-ROADMAP Track B） |
|---|---|---|
| **E1** | `Runtime.invoke` 无 `?skills` 参数（per-call 激活须调 `set_user_activated_skills`，race condition）；`invoke_async` 连 `?context` 都没有 | 加 `?skills:string list` 到 `invoke` + `invoke_async`（~15 LOC） |
| **E2** | 无 `Skill_activated / Skill_deactivated` 事件（仅有 `Cache_invalidated_by_skill`） | 加 2 个事件变体到 event ADT（~10 LOC） |
| **E3** | Python FFI 未暴露 `set_user_activated_skills`（Python 用户**完全不能**激活 Manual skill） | 加 `par_set_user_activated_skills` callback + Python binding（~30 LOC） |
| **E4** | `user_activated_skills` 未持久化（进程重启即丢） | **延后**——等 session 抽象一等公民化（当前 session 是隐式 string tag，无 session 表） |

**E1 重要修正**（Oracle 终审发现）：原以为"无 race-free per-call 激活路径"，实际 `?context:invoke_context` + `Invoke_context.create ~skills:[...]` 已提供（`runtime.ml:727-728` 尊重 caller 传入的 context，`runtime.ml:774` 从 `ctx` 而非 `rt` 读 skills）。E1 是**人机工程学补全**（caller 自建 context 会丢失 runtime 的 session_id / hooks 自动快照），不是能力缺口。

### Skill 不会因 E1-E3 过载

Oracle 终审：E1-E3 不增加新概念职责，只补全现有激活/观察/FFI 生命周期。Skill 蠕变（creep）只在未来添加正交职责（路由、中间件组合）时才发生。E1-E3 不触发。

### Escalation Trigger（何时重评 Mode 作为独立类型）

出现以下**特定**情况时，Mode 作为独立状态机类型才架构正当：

> 下游需要 **用户可注册、动态定义、带类型化转换守卫的互斥行为状态**——例如"未经过 review-mode 不能进 ship-mode"，或"同一时刻只能激活一个 mode 且有禁转表"。

**关键**：Skill 的可组合模型（交集/并集）对互斥状态机在结构上是错的。这是 Skill 增强无法覆盖的唯一场景。

**注意**：编码 agent 领域的 `permission_mode`（Claude Code / OpenSpace）是互斥的，但都是**硬编码**（非用户可注册）。若下游只需硬编码互斥模式（plan / default / accept_edits），Skill + `?skills` 参数 + 约定已覆盖——不需要 Mode 类型。

### 回退方式

不适用（拒绝提案，无代码变更）。E1-E3 是 Skill 系统增强，独立可回退。

---

## #3: 接受 P2 — 暴露 `memory_object` 的 `last_used_at` / `usage_count`

**日期**: 2026-07-29
**触发**: 同 #1
**版本**: v0.8.0-beta 吸收

### 背景

下游反馈 "`Memory_object.t` 暴露 `last_used_at` / `usage_count`（Sqlite_memory 内部已维护，只是 type 没暴露）"。

### 源码核验

| 位置 | 证据 |
|---|---|
| `sqlite_memory.ml:90-91` | schema 有 `last_used_at REAL` + `usage_count INTEGER` |
| `sqlite_memory.ml:339-340` | `bump_usage` 每次检索都 `UPDATE memory_entries SET usage_count = usage_count + 1, last_used_at = ?` |
| `sqlite_memory.ml:217,221` | `row_to_memory` 读取但用 `_last_used_at` / `_usage_count` 前缀丢弃 |
| `sqlite_memory.ml:583,595` | `list_all` 排序用 `ORDER BY last_used_at DESC NULLS LAST, usage_count DESC` |
| `memory_object.mli:1-11` | 公开 type **无**这两字段 |

**结论**：内部记账泄漏到外部影响排序行为、却不让外部读——合法 fix。

### 决策：接受

### 实施细节

- `memory_object.mli` + `.ml` 加 2 字段：`last_used_at : float option` + `usage_count : int`
- `sqlite_memory.ml:row_to_memory` 去掉 `_` 前缀，填入返回的 record
- `to_yojson` / `of_yojson` 跟新（`[@@deriving yojson]` 自动）
- 不需 schema migration（列已存在）

**§11 R1 标注**：架构正确（暴露已维护数据，R5 适用——不是架构决策，是 bug fix 性质）。
**SemVer**：MINOR（新增公开字段）。v0.8.0-beta 吸收。
**工作量**：~20 LOC + 1 个测试。

### 回退方式

移除 2 字段，恢复 `_` 前缀。

---

## #4: 拒绝 P3 — `memory_object.t` 的 `scope` 字段已存在

**日期**: 2026-07-29
**触发**: 同 #1

### 背景

下游反馈 "`Memory_object.t` 增 `scope : string` 字段（schema 有，type 漏了）"。

### 源码核验

`memory_object.mli` 第 5 行（直读确认）：

```ocaml
type memory_object = {
  id : string;
  content : string;
  summary : string option;
  scope : string option;        (* ← 已存在 *)
  metadata : (string * Yojson.Safe.t) list;
  categories : string list;
  created_at : float;
  updated_at : float;
  source : string;
}
```

### 决策：拒绝（事实纠正）

下游报告事实错误。`scope` 字段自 v0.7.1 起已存在于 `memory_object.t`。建议回信时附文件:行号让下游核实——可能看的是旧版本，或与 P2（`last_used_at` / `usage_count`，确实漏了）混在一封信里写错了。

### 回退方式

不适用。

---

## 附录：调研方法论

| 维度 | 方法 |
|---|---|
| 源码核验 | Oracle 直读 `types.mli` / `runtime.ml` / `runtime.mli` / `sqlite_memory.ml` / `memory_object.mli` / `invoke_context.mli` / `workflow_engine.ml`，所有 load-bearing claim 逐行验证 |
| 业界对比 | 6 大通用框架（LangGraph / OpenAI Agents SDK / AutoGen / Google ADK / CrewAI / PydanticAI）官方文档 + GitHub 源码（带 commit SHA） |
| 生产模式 | 8 大生产产品（Claude Code TodoWrite / Aider / Cursor / Devin / AutoGPT / LangChain v1 TodoListMiddleware / ruflo / Google Cloud Concierge）实际代码（带 URL） |
| 编码 agent 专项 | LangChain open-swe / ByteDance deer-flow / HKUDS OpenSpace / claude-code-from-scratch（`plan_mode` / `permission_mode` 模式核验） |
| 架构审查 | 两轮 Oracle（架构审查 3m34s + 怀疑论终审 4m14s），§11 R1-R5 标注逐条验证 |
| 自我修正 | E1（per-call skill 激活）原分析有误，Oracle 终审发现 `?context` + `Invoke_context.create ~skills` 已提供 race-free 路径，已公开修正 |

---

## Phase 2 / Deferred Items

以下项目在 v0.8.1/v0.8.2 中明确标注为延后，记录于此防止遗忘。每项含退役触发条件。

### P2-1: Python FFI for `get_fn` / `upsert_fn`

**状态**：延后。OCaml SDK 路径已验证（`Runtime.memory_service` + `get_fn`/`upsert_fn`），Python 路径缺 4 层 FFI bridge。
**影响**：Python 用户无法精确查询/稳定更新 memory entry（只能用 FTS5 search 或 list_all + filter）。
**工作量**：~1h（照抄 `set_user_activated_skills` 的 5 层 FFI 模式）。
**触发**：下游 Python 用户明确需要 plan_read/plan_write 工具时。

### P2-2: `user_activated_skills` 持久化（原 E4）

**状态**：延后（§11 R2 范围妥协，合规）。
**影响**：进程重启后 skill 激活态丢失（conversation 持久化了但 skill overlay 没有）。
**依赖**：session 一等公民化（当前 session 是隐式 string tag，无 session 表）。
**触发**：session 一等公民化启动时。

### P2-3: Plan lifecycle 事件（`Memory_upserted`）

**状态**：延后。
**影响**：下游想订阅 plan 变更事件（实时 UI 显示 plan 进度）当前做不到——upsert 不发射 event_bus 事件。
**设计决策待定**：(a) 是否所有 upsert 都发事件（可能嘈杂），(b) 是否只对 `scope = "plan:*"` 发，(c) 是否需要 throttle。
**工作量**：~10 LOC（event 变体 + 发射），但需先确认设计。
**触发**：下游明确需要 plan 变更订阅时。

### P2-4: opam-repository 正式审核

**状态**：等待外部审核（不可控）。
**影响**：用户不能 `opam install par` 直接安装（需 `opam pin add`）。
**bd issue**：PAR-hbt（P3）。
**触发**：ocaml/opam-repository 维护者 merge PR 后自动解决。

---

**最后更新**: 2026-08-04
