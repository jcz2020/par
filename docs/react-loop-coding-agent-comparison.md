# ReAct 循环竞品对比：Coding Agent + 通用框架

> **Date**: 2026-06-23
> **Status**: Research complete
> **Trigger**: 用户反馈"总觉得我们的设计可能不符合实际场景"

---

## 1. 核心数据：各家默认循环轮次

| 框架 | 默认循环上限 | 到上限行为 | 壁钟超时 | 成本预算 | 来源 |
|---|---|---|---|---|---|
| **Cursor (标准)** | **25** tool calls | 检查点 + "Continue" 按钮 | 无 | 无 | [forum.cursor.com](https://forum.cursor.com/t/how-to-continue-when-25-tool-call-limit-is-reached/62836) |
| **Cursor (Max)** | **200** tool calls | 同上 | 无 | 按 token 计费 | 同上 |
| **Claude Code** | **无限制**（默认）/ `--max-turns N`（print mode）| `error_max_turns` | 无 | **✅ `max_budget_usd`** | [code.claude.com/docs](https://code.claude.com/docs/en/agent-sdk/agent-loop) |
| **Claude Code 子 agent** | **20**（硬编码 `cjz=20`）| 同上 | 无 | 继承父级 | [GitHub issue #41143](https://github.com/anthropics/claude-code/issues/41143) |
| **OpenAI Agents SDK** | **10** turns | `MaxTurnsExceeded` 异常 | 无 | 无 | [run_config.py:30](https://github.com/openai/openai-agents-python/blob/main/src/agents/run_config.py#L30) |
| **LangGraph v1** | **10007**（框架默认）/ 实际应用通常 25-200 | `GraphRecursionError` | 无 | 无 | [_config.py:26](https://github.com/langchain-ai/langgraph/blob/main/libs/langgraph/langgraph/_internal/_config.py#L26) |
| **LangChain (legacy)** | **15** | `"force"` 停止 / `"generate"` 再答一次 | **✅ `max_execution_time`** | 无 | [agent.py:1023](https://github.com/langchain-ai/langchain/blob/master/libs/langchain/langchain_classic/agents/agent.py#L1023) |
| **CrewAI** | **25** | 强制生成最终答案 | 无 | 无 | [agent_executor.py:182](https://github.com/crewAIInc/crewAI/blob/main/lib/crewai/src/crewai/experimental/agent_executor.py#L182) |
| **OpenHands** | 可配置（resolver 默认 **50**）| 任务失败 | 无 | **✅ `max_budget_per_task`** | [resolve_issue.py:183](https://github.com/All-Hands-AI/openhands-resolver/blob/main/openhands_resolver/resolve_issue.py#L183) |
| **PAR（当前）** | **10** | `Error`（或 Generate 尝试） | **✅ `max_execution_time`**（刚加） | **❌ 无** | engine.ml:400 |

---

## 2. 关键发现

### 发现 1：PAR 的 max_iterations=10 对 Coding Agent 场景太低

一个简单的多文件重构（读 3 个文件 + 改 2 个 + 跑测试 + 修复 + 再跑测试）至少需要 8-10 次工具调用。如果中间有任何重试，10 次根本不够。

**竞品对比**：
- Cursor 标准：25（用户还在抱怨不够）
- CrewAI：25
- LangChain：15
- OpenHands resolver：50
- Claude Code：无限制

**建议**：将默认从 10 提高到 **25**。这与 Cursor 标准模式和 CrewAI 一致，是 Coding Agent 的"最低可用"值。

### 发现 2：Claude Code 的双层限制设计值得借鉴

Claude Code 有两个独立维度：

| 维度 | 含义 | 默认 |
|---|---|---|
| `max_turns` | 整个会话最多几轮 ReAct | 无限制 |
| **per-turn tool calls** | 单轮内最多调几次工具（服务端硬限） | ~20 |

PAR 目前只有 `max_iterations`（≈ max_turns），没有"单轮工具调用上限"。如果 LLM 一次返回 10 个 tool_calls，PAR 会全部执行——这在大多数场景下是对的（并行工具调用），但如果 LLM 陷入循环（反复调用同一个工具），没有保护。

**建议**：暂不添加（并行多工具是 PAR 的设计优势），但可以加一个"循环检测"——如果连续 3 轮调用了完全相同的工具+参数，提前终止。

### 发现 3：成本预算是生产级 Agent 的刚需

Claude Code 的 `max_budget_usd` 和 OpenHands 的 `max_budget_per_task` 解决了一个真实问题：**Agent 失控时的成本爆炸**。

一个 max_iter=25 的 Agent 如果每次调用 GPT-4（~$0.06/次），最坏情况 $1.5/session。但如果 Agent 陷入循环（虽然 Fix 2 现在让重试消耗迭代了），加上长上下文（每次 100K tokens），成本可以到 $10+/session。

**建议**：在 v0.6 添加 `max_cost_usd : float option`。实现方式：LLM 返回的 `usage.total_tokens` × 模型单价 > 预算时终止。

### 发现 4：Cursor 的"检查点 + 继续"模式是最佳 UX

Cursor 在到达 25 次工具调用时**不是报错**，而是暂停并给用户一个 "Continue" 按钮。这让用户可以：
1. 检查中间结果
2. 决定是否继续
3. 调整方向后再继续

PAR 目前到达上限是直接返回 Error（或 Generate 模式下尽力答一次）。没有"暂停 → 用户确认 → 继续"的交互模式。

**建议**：考虑在 v0.6+ 添加 `interrupt_at_limit : bool` 选项。到达上限时不返回 Error，而是返回一个"暂停状态"，用户可以 `rt.resume()` 继续。这需要 checkpoint 支持。

### 发现 5：LangGraph 的 10007 默认是刻意的

LangGraph 框架默认 `recursion_limit=10007`（极高），让**应用层**自己决定上限。这和 LangChain legacy 的 `max_iterations=15` 形成鲜明对比。

设计哲学差异：
- **LangChain legacy**：框架替你决定安全默认值（15）
- **LangGraph v1**：框架不设限，应用自己管（10007 = 实际无限）
- **PAR 当前**：框架替你决定（10），偏低

**建议**：PAR 应该走 LangChain legacy 的路线（框架提供安全默认），但默认值需要调高到 25。

### 发现 6：壁钟超时和迭代上限是互补的——PAR 已经对了

LangChain 同时有 `max_iterations=15` 和 `max_execution_time=None`。PAR 刚加了 `max_execution_time`。两者互补：
- 迭代上限防逻辑死循环
- 壁钟超时防单次 LLM 调用卡死

**PAR 在这方面已经领先于** OpenAI SDK、CrewAI、Cursor（它们都没有壁钟超时）。

---

## 3. 优化建议清单

| # | 建议 | 优先级 | 工作量 | 版本 |
|---|---|---|---|---|
| **A** | **max_iterations 默认从 10 改为 25** | P0 | 1 行代码 | 立即 |
| **B** | 添加循环检测（连续相同工具调用 → 终止） | P2 | ~50 行 | v0.6 |
| **C** | 添加 `max_cost_usd : float option` | P1 | ~100 行 | v0.6 |
| **D** | 添加 checkpoint + resume（暂停/继续） | P3 | 大型 | v0.7+ |
| **E** | 添加 `interrupt_at_limit` 交互暂停 | P3 | 中型 | v0.7+ |

---

## 4. PAR 当前 ReAct 机制 vs Coding Agent 的结构差异

| 特性 | Coding Agent（Cursor/Claude Code） | PAR |
|---|---|---|
| 推理方式 | 隐式（LLM 内部推理，不暴露） | 显式 ReAct 循环（工具调用可见） |
| 工具调用 | 每次 1-N 个（服务端限 ~20） | 每次 1-N 个（并行执行，无单轮上限） |
| 文件操作 | 内置（Read/Edit/Write） | 内置（20 个工具含 Bash_safe） |
| 上下文管理 | 隐式（服务端管） | 显式（Truncate/Summarize/Sliding_window） |
| 错误恢复 | 用户手动 Continue | 自动重试（消耗迭代）+ Generate 降级 |
| 会话持久化 | 有（session_id） | 有（SQLite/PostgreSQL） |
| 检查点/恢复 | 有（Cursor Continue, Claude session） | ❌ 无 |
| 成本控制 | 有（Claude max_budget_usd） | ❌ 无 |

**PAR 的独特优势**：
- 编译时类型安全（ADT 工具调用，shell 注入不可表示）
- 结构化并发（Eio，无 orphan fiber）
- 中间件管道（7 个内置，可组合）
- Handoff（Agent 间委托）
- 工作流引擎（顺序/并行/条件/map-reduce）

**PAR 的主要差距**：
- 默认迭代数偏低（10 vs 竞品 25-50）
- 无成本预算
- 无检查点/恢复
- 无循环检测
