<!-- language: zh -->
**[English](https://github.com/jcz2020/par/blob/main/docs/DECISIONS.md)** · 简体中文

# PAR 架构决策档案 (DECISIONS)

**目的**: 记录影响公共 API、类型设计、模块结构、ROADMAP scope 的重大决策。每条决策含背景、理由、§11 R1 标注、escalation trigger、回退方式。防止未来重复讨论已决事项。

**关联**: [STRATEGY.md](https://github.com/jcz2020/par/blob/main/docs/STRATEGY.md) §11 开发原则 | v0.9-ROADMAP.md（内部文档）

---

## 决策索引

| 日期 | # | 决策 | 性质 | §11 R1 标注 |
|---|---|---|---|---|
| 2026-07-29 | 1 | 拒绝 Plan 一等公民提案（按提案形状） | API 级 + 架构级 | 架构正确 |
| 2026-07-29 | 2 | 拒绝 Mode 一等公民提案，增强 Skill 替代 | API 级 + 架构级 | 架构正确 |
| 2026-07-29 | 3 | 接受 P2：暴露 `memory_object` 的 `last_used_at` / `usage_count` | API 级 | 架构正确 |
| 2026-07-29 | 4 | 拒绝 P3：`memory_object.t` 的 `scope` 字段已存在 | 事实纠正 | 不适用 |
| 2026-08-09 | 5 | 取消 Plan/Goal spike（v0.9 Track D）：调研已充分，SDK 不做产品概念 | 范围级 | 架构正确 |
| 2026-10-21 | 6 | 三层边界判据：PAR / par-code / 独立能力项目 | 战略级 | 架构正确 |
| 2026-11-02 | 7 | 持久化执行语义：at-least-once + 显式恢复 + 原子控制流节点 | API 级 + 架构级 | 架构正确 |
| 2026-11-03 | 8 | 持久化 invoke：批次检查点 + 显式恢复 + 运行名由调用方给 | API 级 + 架构级 | 架构正确（3 处 R2 妥协） |
| 2026-11-03 | 9 | 注入的 event_bus 与内部持久化总线组合而非二选一 | API 级 | 架构正确 |

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
- **验证方法**：~~2 周联合 spike~~（**已取消，见 #5**）——调研结论已充分，app 层工具方案被业界 6/6 框架 + 8/8 生产产品验证

### 替代方案（app 层工具模式——业界标准做法）

下游用 PAR 现有原语自建 `plan_read` / `plan_write` 工具——参考 Claude Code TodoWrite / LangChain v1 TodoListMiddleware 模式。这是 6/6 业界框架的标准做法，不需要 SDK 侧配合验证。

### Escalation Trigger（何时重评）

出现以下任一情况时，重新评估"是否引入 runtime Plan 类型"：

1. **CrewAI 或 LangGraph 演进出 rich Plan 类型并成为 de-facto 标准** → 季度监控
2. **非编码 agent 用户请求 Plan 且 shape 不同**（如研究 agent 的 hypothesis/experiment/conclusion 生命周期）→ "产品概念泄漏"论点弱化
3. **下游实测反馈**：app 层 plan 工具 + workflow + memory_service 组合**无法满足**下游核心需求（运行时 plan 变异 + 多 agent 共享 + 跨 session 持久化）——需下游提供具体用例证明现有原语不够（非假设性问题）

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

## #5: 取消 Plan/Goal spike（v0.9 Track D）

**日期**: 2026-08-09
**触发**: 战略复盘——v0.9.0 ROADMAP 新鲜度核实后发现 Track A+B 已以 v0.8.1 发出，仅 Track D spike 未启动

### 背景

v0.9-ROADMAP Track D 规划了 2 周 Plan/Goal spike（联合下游），验证三个 option：(A) bounded `Loop` step、(B) 中性 `Goal` 类型、(C) 维持现状 + 文档。

### 决策：取消 spike，SDK 不做 Plan/Goal 类型

§11 R1 标注：**架构正确**（范围级——"不做"也是架构决策）。

理由：

1. **调研已充分**。#1 的调研（6/6 框架 + 8/8 生产产品零例外用 app 层工具）已给出确定结论。spike 是当时为对外交涉留的台阶（"联合验证 2 周再定"），不是技术必要性。再花 2 周不改变答案。

2. **SDK 不做产品概念**。Plan/Goal 的字段（`files_to_touch` / `steps` / status 状态机）是产品层决定的。SDK 硬编码 = 把某个下游的产品模型耦合进运行时，违反 narrow-deep-module 原则。PAR 现有原语（`register_tool` + `memory_service` + `workflow`）全覆盖。

3. **唯一可分离的子问题**：bounded `Loop` workflow step。但那是工作流引擎的控制流原语（iteration），不是 plan 语义。该不该加取决于"用户有无表达不出现有 Sequential + Conditional + Map_reduce 组合的迭代需求"，与 Plan/Goal 独立，不紧急，单独评估。

### Escalation Trigger

同 #1（CrewAI/LangGraph 演进出 runtime Plan 类型 / 非编码 agent 不同 shape / 下游实测证明现有原语不够）。

### 回退方式

不适用（取消研究，无代码变更）。

---

## #6: 三层边界判据 — PAR / par-code / 独立能力项目

**日期**: 2026-10-21
**触发**: 规划 URL 抓取增强时，发现「放进 PAR 还是另起项目」的判断反复摇摆，且多次在核实前就下了架构结论。根因是判断时只用了两分类，忽略了既有的第三层。

### 背景

v0.6.7 已经确立过一次边界：「引擎归引擎、产品归产品」——CLI 从 PAR 移出，产品形态下沉到独立的 par-code 仓库。那条决策确立了「PAR 是什么」，但没有回答「一个既不是运行时语义、也不是产品 UX 的能力该去哪」。

同时存在三个实际约束：

1. **PAR 没有插件系统**。可用扩展位只有两个：`Runtime.register_tool`（普通函数 + JSON Schema）与 MCP client（stdio / HTTP-SSE）。
2. **par-code 已是既有的第二层**。它自己就有 `par_code_git_tools.ml` / `par_code_memory_tools.ml` / `par_code_plan_tools.ml` —— 产品专用能力工具住在这里，通过 `register_tool` 接进 PAR，模式已经存在。
3. **par-code 自己的策略已写明耦合关系**（par-code `docs/STRATEGY.md` §2）：它同时是用户工具和 PAR 的验证用例，「当 par-code 发现 PAR 的限制时，第一反应是修 PAR，而不是在 par-code 里绕开」。

### 决策

按「这个能力承诺的是运行时保证，还是产品形态，还是领域适配」分三层：

| 层 | 归属 | 判据 | 落地形态 |
|---|---|---|---|
| **运行时语义** | PAR | 需要**保证**的地方：类型契约、事件、ReAct 循环、工具协议、provider 协议、并发、持久化 | OCaml SDK / Python binding |
| **产品形态 / 领域能力** | par-code | 属于 agent 产品形态或代码领域能力：REPL、goal chaining、代码专用工具（git / plan / memory） | par-code 内的 `par_code_*_tools.ml`，经 `register_tool` 注册 |
| **领域适配器** | 独立项目 | 需要异构重型依赖栈（浏览器、搜索引擎 SDK 等） | 普通库（`register_tool` 消费）或 MCP server（跨客户端复用时） |

补充规则：

- **运行时层面的限制 → 修 PAR**，即使 par-code 是唯一受影响的消费者。这是 par-code §2 已经写下的耦合承诺。
- **领域能力默认不单独开项目**。先看它是否属于 par-code；只有当它需要非 PAR 的消费者（Claude Code 等 MCP 客户端）或需要自己的依赖栈时，才做成独立项目。
- **不新增插件机制**。独立项目用 `register_tool` 或 MCP 接入，不为它们扩展 PAR 的 API 表面。

### 理由

1. **判据可判定**。前两类的区别是「是否是运行时该保证的东西」，这是可以逐条论证的；而「是否另起项目」不是——它会随项目数量线性增加判断成本。
2. **避免重复发明扩展位**。PAR 已有 MCP client，若再设计「插件系统」，就是第二个同类机制，且没有 MCP 的跨客户端复用价值。
3. **与既有决策一致**。本决策是 v0.6.7「引擎归引擎」的三层细化，不推翻它。

### 现状约束（MCP 路径尚不可用）

MCP server 目前**不能**让模型直接调用其工具：`tool_registry.ml` 与 `engine.ml` 无任何 MCP 引用，`Mcp_client.call_tool` 在库内没有调用点，测试也只覆盖服务器生命周期与原始 JSON-RPC。因此：

- 走 `register_tool` 的形态今天可用（Python 侧 `register_tool_with_handler` 已在绑定中）。
- 走 MCP 的形态需要先补上工具接线（见 bd `PAR-zno`），这也是 par-code 自己的 roadmap v0.11.0「MCP 客户端初始化」的前置条件。

### Escalation Trigger

出现以下任一情况时重评：

- 某能力被多个非 PAR 客户端需要 → 倾向 MCP 形态。
- PAR 的 opam 依赖面因某能力而不可接受 → 该能力移出 PAR。
- par-code 之外的第二个 PAR 旗舰消费者出现 → 重新评估「产品能力放 par-code」这一层是否仍然成立。

### 回退方式

不适用（文档级决策，无代码变更）。

---

## #7: 持久化执行的语义边界（at-least-once + 显式恢复）

**日期**: 2026-11-02
**触发**: 实现 `PAR-ni4`（持久化工作流执行）后，发布前审查发现检查点虽在写、却不可恢复。需要把「到底保证什么」固定下来，而不是每次由实现细节决定。

### 决策

1. **语义是 at-least-once**。进程在某一步执行中途死亡时，检查点仍指向上一个完成的步，该步会在恢复时重跑。PAR 不提供 exactly-once，也不假装提供。
2. **恢复是显式的**。`Runtime.create` 只负责把 `running` 行读回并发 `Workflow_orphaned`；不自动执行。是否重跑有副作用的步骤由调用方决定。
3. **控制流节点是原子的**。`Parallel`、`Map_reduce`、`Sub_workflow`、`Conditional` 的子树不写检查点；崩溃后整块重跑。理由：节点内部的并发/分支状态无法从检查点安全重建，部分恢复会造出"半执行"的假状态。
4. **检查点携带步后状态**。写入的是该步完成后累积的变量，而不是运行开始时的变量。`schema_version` 记录格式版本；更高版本被拒绝，而不是猜测。
5. **恢复资格来自启动时的孤儿集合**，不是 `Wf_running` 状态本身。状态无法区分"崩溃孤儿"与"本进程正在跑"，按状态恢复会导致双重执行。

### §11 R1 标注

**架构正确**。前四条是把「运行时保证」写成可验证的契约；第五条是审查中发现的实现缺陷，属于正确性要求而非范围妥协。

**范围妥协（R2 合规）**：
- 子工作流不能独立恢复（崩溃后整块重跑）。退役触发：出现需要细粒度恢复子工作流的部署，且检查点能安全表达子运行边界。
- agent 循环中途崩溃恢复不做（`PAR-mrr`）。退役触发：出现「长工具调用崩溃后无法接受重跑」的生产反馈。**已于 2026-11-03 退役，见 #8。**
- 流式 reasoning 的块级结构同理，见推理块决策。

### 已知冲突（已解决）

`~event_bus` 在 persistence 非 noop 时被忽略：运行时自建总线用于落盘，注入的服务收不到 `Workflow_orphaned` 等事件。

**已于 2026-11-03 解决，见 #9**：两个总线组合，事件先发内部（落盘）再发调用方。`Workflow_orphaned` 与 `Invoke_orphaned` 现在都能被注入的总线看到。

### Escalation Trigger

- 出现要求 exactly-once 的部署 → 需要幂等键 + 工具回执表，重新评估整体模型。
- 检查点体积成为问题（变量累积）→ 需要压缩或增量检查点。
- 恢复被误用为「重启即继续」→ 说明显式恢复的门槛设计需要更醒目的文档/API 反馈。

### 回退方式

公开面为 additive；删除 `Runtime.recover_workflow`、孤儿集合与 `Workflow_orphaned` 即回到 v0.13 行为。带 `schema_version` 的检查点旧二进制可读（缺字段按 1）。

---

## #8: 持久化 invoke 的恢复语义（agent 循环崩溃恢复）

**日期**: 2026-11-03
**触发**: `PAR-mrr`。v0.14 让工作流可恢复，但 agent 循环中途崩溃后，已完成的工具调用只存在于内存里，重跑会重复副作用。

### 决策

1. **检查点表独立**：新增 `invoke_checkpoints`（`invoke_id` 主键、`state_json`、`updated_at`）。不复用 `task_states`（invoke 不是 task 行，把会话大小的负载塞进调度器状态记录会让每次任务查询为用不到的数据付费），也不塞进 `approvals`（那是审批状态）。这张表是 `PAR-4dt` Checkpointer 层的第一块，工作流表暂不迁移。
2. **边界是工具批次**：第 0 次迭代后写一次，之后每个完成的工具批次后写一次。并行批次是原子的——全部结果折入会话后才写一次，批次内部崩溃则整批重跑（与 #7 的 `Parallel` 规则同构）。
3. **行存在 = 在途**：任何终止结果（成功、失败、取消、审批挂起）都删除该行。启动时发现的行走 `Invoke_orphaned` + 显式 `Runtime.recover_invoke`，资格规则复用 #7：只认启动时记录的孤儿集合，并加在途保护，避免恢复一个活运行导致双重执行。
4. **运行名由调用方给**：`~invoke_id` 隐含 `durable = true`。自动生成的 id 只出现在返回值里，而崩溃的进程返回不了它——「可恢复」的前提是调用方能命名。
5. **系统提示词原样重放**：恢复不重算 skill / appendix，避免恢复后的上下文与崩溃前不一致。
6. **可选开启**：`~durable` 默认 `false`。

### §11 R1 标注

**架构正确**：1–5 是契约。第 3 条复用了 #7 审查中发现的正确性要求——状态本身无法区分孤儿与活运行。

**范围妥协（R2 合规）**：
- 每步重写整份会话快照（单次 O(n)，累计 O(n²) 字节写入量）。退役触发：快照改为增量/差分后，把 `durable` 改为默认开启。
- 审批挂起不并入同一条恢复路径，仍由 `approvals` 行 + `resume_approval` 负责。退役触发：出现「同一运行既要跨崩溃又要跨审批」的部署需求。
- 工作流检查点未迁移到统一 Checkpointer。退役触发：`PAR-4dt` 的 Store 层落地时一并迁移。
- `invoke_structured` / `invoke_generate` 不支持 durable。退役触发：结构化输出的长工具循环出现崩溃恢复需求。

### Escalation Trigger

- 检查点体积成为瓶颈 → 需要增量快照。
- 出现 exactly-once 要求 → 需要幂等键 + 工具回执表。
- 恢复被当作「重启即继续」→ 说明显式恢复的门槛需要更醒目的文档/API 反馈。

### 回退方式

公开面为 additive。删除 `invoke_checkpoints` 表、`Runtime.recover_invoke` / `list_orphaned_invokes`、`Invoke_orphaned` 事件与 `~durable` / `~invoke_id` 参数即回到 v0.14 行为；已写下的行对旧二进制只是无读取方的空表。

---

## #9: 注入的 event_bus 与内部持久化总线组合

**日期**: 2026-11-03
**触发**: #7 记录为「未决冲突」。persistence 非 noop 时 `Runtime.create` 自建内部总线供落盘，调用方通过 `~event_bus` 注入的服务被整个丢弃——注入的总线收不到任何事件，包括 `Workflow_orphaned` 与 `Invoke_orphaned`。durable 恢复的孤儿通知对外不可见，等于哑巴。

### 决策

1. **组合，不二选一**：事件先发内部总线（落盘），再发调用方总线。顺序固定且内部优先——落盘不因调用方 handler 抛异常而丢失。
2. **`set_session_id` 双写**；`subscribe` / `unsubscribe` / `start_dispatcher` 委派给调用方总线，因为那才是调用方持有的实例。
3. **未注入总线时行为不变**：只使用内部总线。

### §11 R1 标注

**架构正确**。其余选项（拒绝组合、只发调用方、只用内部）都会让可观测性取决于 persistence 配置，是更差的契约。

### Escalation Trigger

- 调用方 handler 抛异常开始影响 invoke 延迟 → 需要异步 fan-out 或隔离。
- 出现跨总线订阅顺序要求 → 需要显式优先级。

### 回退方式

恢复 `(Event_bus.to_service bus, Some bus, Some writer)` 分支并删除组合记录，即回到 v0.14 行为。

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
