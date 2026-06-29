# Long-Output Generation Mode — 实施计划

> **状态**: 待执行(2026-06-28 创建)
> **来源**: downstream proposal(附录 §9.1)
> **决策**: 接受 Option A + B + C,合并实施
> **版本号**: 由维护者决定。**本文档不预设版本号,实施 agent 不得自行 bump**
> **范围级影响**: 公开 `agent_config` 类型(on_max_tokens 字段语义变更)、新增公开 API(`Runtime.invoke_generate`)、FFI 暴露、文档同步

---

## 1. 背景与决策依据

### 1.1 downstream feedback summary

a an integrator是 PAR 的 an integrator 下游,嵌入了 3 个长输出 agent:a long-output agent(PRD 生成,~3000-6000 token Markdown)、a long-output agent(HTML mockup)、a long-output agent。

**关键事实**:
- 3 个 agent 当前**全部绕过** `Runtime.invoke`,自己手写了 `llm_chat_raw` 直接调 LLM
- 他们保留 PAR 仅用于 session/event management
- 配置:`max_iter=10`, `max_execution_time=120s`, `on_max_tokens=Return_partial`(默认)
- 症状:3000-6000 token PRD 生成经常超时;truncation "有时" 返回 partial 可用文档,负载下仍然 wall-clock 超时

**战略含义**:STRATEGY.md 承诺 PAR 的核心价值是 runtime(session/event bus/llm_service/skill)。下游在最关键的 long-output 场景**绕开了 runtime**——这正是战略想避免的"用一半"模式。

### 1.2 4-agent 主流做法调研

downstream proposal调研了 4 家主流 coding agent,结论:**没有一个把 `max_tokens` 当 iteration-consuming 失败**。

| Agent | max_tokens 行为 | 来源 |
|---|---|---|
| Claude Code | 9 个 auto-continue 条件之一,partial 喂回让模型完成 | [INTERNALS.md](https://internals.laxmena.com/p/why-claude-codes-agent-loop-is-over) |
| Codex CLI | Loop exit 由 "有工作要做" 驱动(tool/test),不数 token;长 session 走 input-side compaction | [Unrolling Codex agent loop](https://openai.com/index/unrolling-the-codex-agent-loop/) |
| OpenCode | `maxSteps` 数 step(推理+工具);纯生成截断是正常 finish,无 ReAct budget 可烧 | [Inside OpenCode](https://cefboud.com/posts/coding-agents-internals-opencode-deepdive/) |
| a comparable coding agent | 主 agent 永远不总结自己的 in-flight 长输出;走独立 writer subagent + cycle/checkpoint | [a comparable coding agent blog](https://mimo.xiaomi.com/zh/blog/mimo-code-long-horizon) |

**共同不变量**:
> 由 token 限制引起的截断是 transport/format detail。模型完成了它的工作;runtime 的工作是交付完整输出,不是惩罚模型碰到了限制。

**PAR v0.6.0 是这 4 家里唯一仍把 Max_tokens 当 loop-budget 事件的**。本计划要收尾这个转型。

### 1.3 PAR v0.6.0 现状

已实现(`lib/core/engine.ml:738-783`):
- `on_max_tokens_behavior = Retry | Continue | Return_partial` ADT
- 默认 `Return_partial`
- `Continue` 模式有完整子循环(`engine.ml:758-778` 的 `continue_chunks` 递归),含 500-char diminishing-returns guard

未完成:
- `Continue` 必须 per-agent opt-in,默认不开启
- `max_continuation_chunks` 硬 cap 在 3,30k token artifact 会被卡在 `3 × max_tokens`
- tool-less agent 没有特殊处理(明明只能 continue,还要走完整 ReAct)
- 没有"跳过 ReAct"的纯生成入口
- 错误路径仍然混淆(`Max_tokens` 引发的 iter 用尽 报 "Max iterations exceeded")

### 1.4 决策

接受 downstream proposal的 A + B + C,**单次会话内全部实施**。三者可并行推进:
- A 与 C 紧耦合(C 折进 A 的错误消息修正)
- B 独立新建入口,可同步开工,Continue 逻辑可与 A 共享或独立实现

---

## 2. Option A + C 合并实施

### 2.1 Option A — 默认 Continue + 解开 cap(tool-less agent)

#### 2.1.1 类型变更(`lib/core/types.ml`)

当前(`types.ml:350`):
```ocaml
type on_max_tokens_behavior = Retry | Continue | Return_partial
type agent_config = { ... on_max_tokens : on_max_tokens_behavior; ... }
```

改为:
```ocaml
type on_max_tokens_behavior = Retry | Continue | Return_partial
type on_max_tokens_policy =
  | Auto              (* 运行时决定:tool-less → Continue,否则 Return_partial *)
  | Fixed of on_max_tokens_behavior  (* 用户显式覆盖 *)

type agent_config = {
  ...
  on_max_tokens : on_max_tokens_behavior option;
  (* None = Auto 行为;Some x = 显式 Fixed *)
  max_continuation_chunks : int option;
  (* None = Auto:tool-less 无界,否则 3;Some n = 显式 *)
  ...
}
```

**设计依据**:符合 STRATEGY.md §3 差异化 #1(typed rigor)。`option` 表达"运行时决定"语义,比 sentinel 值类型化。

**破坏性**:现有调用点全要适配。0.x 阶段可接受(SemVer §4)。`make_agent` 用可选参数 + 默认 `None`,keyword-arg 调用者无感知。

#### 2.1.2 运行时解析(`lib/core/engine.ml` 入口)

新增辅助函数(放在 `run_agent` 之前):
```ocaml
let resolve_on_max_tokens (agent : agent_config) : on_max_tokens_behavior =
  match agent.on_max_tokens with
  | Some policy -> policy
  | None ->
    let tool_less = (agent.tools = []) in  (* 简化:tools=[] 即 tool-less *)
    if tool_less then Continue else Return_partial

let resolve_max_continuation_chunks (agent : agent_config) : int =
  match agent.max_continuation_chunks with
  | Some n -> n
  | None ->
    let tool_less = (agent.tools = []) in
    if tool_less then max_int else 3
```

替换 `engine.ml:738, 759` 直接读字段的代码:
- L738 `agent.on_max_tokens` → `(resolve_on_max_tokens agent)`
- L759 `agent.max_continuation_chunks` → `(resolve_max_continuation_chunks agent)`

#### 2.1.3 默认值同步(`lib/core/runtime.ml`)

`runtime.ml:92` 当前默认值改为 `None`:
```ocaml
on_max_tokens = None;       (* was Return_partial *)
max_continuation_chunks = None;  (* was 3 *)
```

#### 2.1.4 FFI/JSON 解析(`lib/ffi/par_capi.ml`)

`par_capi.ml:522, 528` 当前是:
```ocaml
on_max_tokens = (match get_string "on_max_tokens" with "retry" -> Retry | "continue" -> Continue | _ -> Return_partial);
max_continuation_chunks = get_int "max_continuation_chunks" 3;
```

改为:
- `"on_max_tokens"` 字段省略 → `None`(Auto)
- 显式 `"retry"`/`"continue"`/`"return_partial"` → `Some (...)`
- `"max_continuation_chunks"` 省略 → `None`
- 显式数字 → `Some n`

**Python 调用者零代码改动**(纯 JSON 透传)。但行为对 tool-less agent 改变(从 Return_partial 自动变 Continue)。

#### 2.1.5 Skill `tool_filter` 解析

skill 可能通过 `tool_filter = Only []` 或 `Except [...]`(全过滤掉)间接让 agent 变 tool-less。`resolve_on_max_tokens` 的 `agent.tools = []` 检查**不够**——需要计算"effective tools after skill overlay"。

**实施时**:在 `run_agent` 入口已经计算过 `tools_for_provider`(engine.ml L419-460 的 effective_mode 计算),把同样的 effective tool 列表传给 `resolve_on_max_tokens`。

修正签名:
```ocaml
let resolve_on_max_tokens ~effective_tools (agent : agent_config) : on_max_tokens_behavior =
  match agent.on_max_tokens with
  | Some policy -> policy
  | None -> if effective_tools = [] then Continue else Return_partial
```

### 2.2 Option C(折进 A)— Max_tokens 不消耗 iteration

#### 2.2.1 错误消息区分(`lib/core/engine.ml:745, 750, 753`)

当前所有 Max_tokens 引发的 iter 用尽都报 `"Max iterations exceeded"`。改为:

| 触发条件 | 错误消息 |
|---|---|
| tool-less agent + Continue 模式 + max_continuation_chunks 用尽 | `"Output incomplete: max_continuation_chunks limit reached"` |
| tool-bearing agent + Retry/Continue 模式 + iter 用尽(混合) | `"Max iterations exceeded with truncated output"` |
| 纯迭代用尽(无 truncation) | `"Max iterations exceeded"`(保持) |

#### 2.2.2 Continue 子循环不消耗主 iteration(`engine.ml:758-778`)

当前 `continue_chunks` 是子递归,本来就不消耗主 `iterations`。验证这一点不变,加测试覆盖。

### 2.3 测试要求

#### 2.3.1 新增测试(`test/test_truncation_config.ml` 扩展)

最少 8 个新用例:

| # | 测试名 | 验证 |
|---|---|---|
| 1 | `tool_less_agent_defaults_to_continue` | `tools=[]` + 默认配置 → effective `Continue` |
| 2 | `tool_bearing_agent_defaults_to_return_partial` | `tools=[...]` + 默认 → effective `Return_partial`(向后兼容) |
| 3 | `explicit_on_max_tokens_overrides_auto` | `Some Return_partial` 在 tool-less 上仍 `Return_partial` |
| 4 | `tool_less_max_continuation_chunks_unbounded` | tool-less + default cap → 实际可继续 > 3 chunks(用 mock 模型) |
| 5 | `tool_bearing_max_continuation_chunks_3` | tool-bearing + default → cap 在 3 |
| 6 | `explicit_max_continuation_chunks_respected` | `Some 5` → 实际 cap 在 5 |
| 7 | `continue_does_not_burn_iterations` | 主 loop iteration 计数在 Continue 子循环期间不增长 |
| 8 | `skill_overlay_makes_agent_tool_less` | skill `tool_filter = Only []` → 触发 Continue 默认 |

#### 2.3.2 现有测试不退化

跑 `dune runtest` 必须 0 退化。特别关注:
- `test/test_truncation_fix.ml`(v0.5.5 的 3 个用例)
- `test/test_truncation_config.ml`(v0.6.0 的 5 个用例)
- `test/test_agent.ml` 所有 `make_agent` 调用点(类型变更可能波及)

### 2.4 兼容性策略

- **OCaml SDK**:`make_agent` 用 `?on_max_tokens:?on_max_tokens_behavior option` + `?max_continuation_chunks:int option`,默认 `None`。Positional 调用会破坏(0.x 可接受);keyword 调用零改动。
- **Python binding**:JSON 透传,行为变化对 tool-less agent 默认变成 Continue。
- **CLI**:配置文件 JSON 同 Python。
- **文档**:`docs/sdk/agent.md` + `docs/zh/sdk/agent.md` 同步更新,标 "v0.6.x behavior change"。

### 2.5 风险

| 风险 | 缓解 |
|---|---|
| R1: 模型陷入 "续写永不收尾" 死循环 | 现有 500-char diminishing-returns guard(`engine.ml:775`)兜底;但如果模型每 chunk 都 >500 chars,guard 不触发。**额外加** wall-clock sub-cap:Continue 子循环总时长不超过 `max_execution_time` 的 50% |
| R2: 类型破坏现有 SDK 用户 | 0.x SemVer §4 允许。CHANGES.md 明确标 "Breaking: on_max_tokens 字段类型变更" |
| R3: Skill tool_filter 解析时机错 | 严格用 `effective_tools`(已经在 effective_mode 计算时得出),不要重新解析 |
| R4: Continue 模式 + tool-less 在某些 provider 上行为异常 | 在 Mock provider 上跑完整 e2e;在 OpenAI/Anthropic 上手动验证一次 |

### 2.6 完成验证(与 §3.3 合并)

- [ ] `dune build bin/main.exe` exit 0
- [ ] `dune runtest` 全绿(含 8 个新测试 + §3 的 6 个新测试 + 现有 1000+ 测试)
- [ ] `make docs-check` clean(EN + ZH 同步)
- [ ] 手动验证:tool-less agent 生成 5000 token 输出不超时(用 Mock provider 模拟)
- [ ] `lsp_diagnostics` 在所有改动文件上 clean

---

## 3. Option B — `invoke_generate` 一等公民 API

> 与 §2 同步推进。可由同一会话同一 agent 实施。Continue 逻辑可与 §2 的 `continue_chunks` 共享,或在 `generate.ml` 内部独立实现(后者解耦性更好,推荐)。

### 3.1 API 设计

#### 3.1.1 类型(`lib/core/types.ml` 或新建 `lib/core/generate.ml`)

```ocaml
(** Generate result — first-class return type for pure generation mode. *)
type generate_result = {
  text : string;
  finish_reason : finish_reason;   (* 复用现有 ADT:Stop | Tool_calls | Max_tokens | Content_filter *)
  continuations : int;              (* 触发的 Continue 子循环次数 *)
  total_tokens : int option;        (* 累积 usage 跨 continuation *)
  session_id : Session.id;
  elapsed : float;
}
[@@deriving yojson]
```

#### 3.1.2 接口(`lib/core/runtime.mli`)

```ocaml
(** Pure generation mode — skips ReAct loop, auto-continues on Max_tokens.

    Use for: long text artifacts (PRDs, HTML mockups, plans, documentation)
    where no tool calls are needed.

    Reuses: session store, event bus, LLM-service abstraction, skill/prompt
    management. Skips: ReAct iteration budget, max_execution_time per-iteration
    check (replaced by optional total timeout).

    @param agent resolves system_prompt / model / skill (must have tools = [])
    @param max_output_tokens per-call cap; continuations accumulate beyond this
    @param total_timeout wall-clock cap on entire generation (default: infinity)
*)
val invoke_generate :
  runtime ->
  ?session_id:Session.id ->
  agent:Types.agent_config ->
  message:string ->
  ?max_output_tokens:int ->
  ?total_timeout:float ->
  unit ->
  (generate_result, Types.error_category) result
```

#### 3.1.3 实现要点

- **不复用** `Engine.run_agent`(那是 ReAct loop)
- **新建** `Engine.run_generate`(或独立 `Generate` 模块),复用:
  - `run_llm_with_optional_streaming`(streaming 累加)
  - `add_assistant_message` / `add_user_feedback`(conversation 管理)
  - Session save/load
  - Event bus publish
- **Continue 子循环**:走 `generate` 自己的递归,不进 ReAct
- **事件发射**:`Llm_request_sent` / `Llm_response_received` / 新增 `Generate_continuation { chunk_index; chars_added }` / `Llm_response_truncated`

#### 3.1.4 FFI / Python

- `lib/ffi/par_capi.ml` 新增 `par_generate` C 函数
- `bindings/python/par_runtime/_ffi.py` 暴露 `Runtime.invoke_generate`
- `bindings/python/par_runtime/__init__.py` 加方法

### 3.2 测试要求

最少 6 个新测试:

| # | 测试名 | 验证 |
|---|---|---|
| 1 | `invoke_generate_basic` | 单次 Stop 完成的简单 case |
| 2 | `invoke_generate_auto_continue` | Max_tokens 触发 Continue,跨 chunk 拼接 |
| 3 | `invoke_generate_total_timeout` | wall-clock cap 触发,返回 partial |
| 4 | `invoke_generate_event_emission` | 事件流正确(含 Generate_continuation) |
| 5 | `invoke_generate_session_persisted` | 生成结果保存到 conversations 表 |
| 6 | `invoke_generate_skill_overlay_applied` | skill 的 system_prompt_override 生效 |

### 3.3 完成验证(与 §2.6 合并)

- [ ] `dune build bin/main.exe` exit 0
- [ ] `dune runtest` 全绿(含 §2.3 的 8 个 + §3.2 的 6 个新测试 + 现有 1000+ 测试)
- [ ] Python e2e 测试:`bindings/python/tests/test_generate.py`(新建)
- [ ] 文档:`docs/sdk/generate.md`(EN)+ `docs/zh/sdk/generate.md`(ZH)
- [ ] `make docs-check` clean
- [ ] `lsp_diagnostics` 在所有改动文件上 clean
- [ ] 手动 e2e:Mock provider 模拟 5000-token 输出验证 invoke_generate
- [ ] CHANGES.md 加 beta 条目(版本号 `[VERSION-TBD]` 占位)

---

## 4. 实施顺序与依赖

单会话内并行推进,推荐 wave-based 顺序:

```
Wave 1(类型基础 — 顺序)
   ├── A.1 types.ml:on_max_tokens_behavior → option
   ├── B.1 types.ml 或新 lib/core/generate.ml:generate_result 类型
   └──(两条改动同文件 types.ml,合并)

Wave 2(并行)
   ├── A.2 engine.ml:resolve_on_max_tokens / resolve_max_continuation_chunks
   ├── A.4 par_capi.ml JSON 解析支持省略字段
   ├── B.3 实现 Engine.run_generate 或独立 Generate 模块
   └── B.4 FFI par_generate + Python binding

Wave 3(并行,依赖 Wave 2)
   ├── A.3 runtime.ml 默认值改 None
   ├── A.5 验证 skill effective_tools 解析时机
   ├── A.6 错误消息修正(Option C 折进)
   ├── B.5 Runtime.invoke_generate 接口暴露
   └── B.6 Python __init__.py 暴露方法

Wave 4(测试 + 文档,并行)
   ├── A 测试 8 个(test_truncation_config.ml 扩展)
   ├── B 测试 6 个(test_generate.ml 新建 + Python e2e)
   ├── 文档 EN (docs/sdk/agent.md + 新建 docs/sdk/generate.md)
   └── 文档 ZH 镜像

Wave 5(验证)
   ├── dune build / dune runtest
   ├── make docs-check
   ├── lsp_diagnostics
   └── 手动 e2e(Mock provider 模拟 5000-token 输出)
```

A 与 B 在 Wave 1 之后完全并行,只在最终验证(Wave 5)合并。

---

## 5. 战略契合度

| STRATEGY.md 维度 | 契合 |
|---|---|
| §3 #1 类型严谨 | ✅ typed `on_max_tokens_policy` ADT + typed `generate_result` 比 4 家竞品都严格 |
| §3 #2 Eio 轻量 | ✅ Continue 复用现有 fiber,无新增 |
| §3 #3 多 provider | ✅ 完全 provider-agnostic |
| §4 优先级 | ✅ 不与任何轴冲突 |
| §7 防呆清单 | ⚠️ "Compaction(LLM 摘要压缩)"在清单上——本计划不要求摘要,只 continue,**不冲突** |
| 目标用户 | ✅ the downstream project represents the LLM backend engineer profile |

**战略收益**:修复"下游在最关键场景绕开 runtime"的偏离。

---

## 6. 文档同步清单

实施完成时**必须**同步:

| 文件 | 改动 |
|---|---|
| `CHANGES.md` | 新增条目(版本号由维护者决定,不预设) |
| `docs/STRATEGY.md` §8 changelog | 加一行 "API-level change: on_max_tokens ADT extended + invoke_generate added" |
| `docs/sdk/agent.md` | 文档化新字段语义 + breaking change 标注 |
| `docs/zh/sdk/agent.md` | 镜像 |
| `docs/sdk/generate.md`(新建) | invoke_generate 完整文档 |
| `docs/zh/sdk/generate.md`(新建) | 镜像 |
| `README.md` | Hero 区如有 invoke 例子,补 invoke_generate 一行 |

---

## 7. 不做的事(明确边界)

- ❌ **不实施 MiMo 的 cycle/checkpoint/writer subagent**——the downstream project's pain point不是 context 满,是 Max_tokens 处理未完成
- ❌ **不实施 MiMo 的 JS 沙箱 Dynamic Workflow**——与 PAR typed ADT 哲学相反
- ❌ **不实施 Max Mode(N 选优 + judge)**——本计划不涉及
- ❌ **不实施 Dream/Distill**——本计划不涉及
- ❌ **不实施 agent-callable history tool**——本计划不涉及(独立 bd issue)

---

## 8. 关键源码位置速查(实施时参考)

| 关注点 | 位置 |
|---|---|
| `on_max_tokens_behavior` ADT | `lib/core/types.ml:350` |
| `max_continuation_chunks` 字段 | `lib/core/types.ml:366` |
| 当前默认值 | `lib/core/runtime.ml:92` |
| `Max_tokens` 分支主逻辑 | `lib/core/engine.ml:729-783` |
| `Continue` 子循环 | `lib/core/engine.ml:758-778` |
| 500-char diminishing-returns guard | `lib/core/engine.ml:775` |
| `early_stopping_method` | `lib/core/types.ml:348`,`engine.ml:481-490` |
| Effective tool mode 计算 | `lib/core/engine.ml:419-460` |
| FFI agent_config 解析 | `lib/ffi/par_capi.ml:498-532` |
| v0.6.0 测试基础 | `test/test_truncation_config.ml`(5 个用例) |
| v0.5.5 测试基础 | `test/test_truncation_fix.ml`(3 个用例) |
| Streaming 累加 | `lib/core/engine.ml:160-195` |
| Session save | `lib/core/runtime.ml:501-507` |
| Event bus publish | `lib/core/event_bus.ml` + `runtime.ml` publish_event_fn |

---

## 9. 附录

### 9.1 downstream original proposal (full text)

```markdown
# Enhancement: Treat `Max_tokens` truncation as a first-class finish, not a ReAct iteration — a proposal from a downstream runtime
 
> Follow-up to the v0.6.0 fix in `par-issue-max-tokens-react-loop.md`.
> Target audience: PAR (Pocket Agent Runtime) maintainers.
> Context: the downstream project, a desktop product-an integrator workbench that embeds PAR as an integrator.
 
## TL;DR
 
PAR v0.6.0 fixed the worst symptom (truncated output no longer *burns* the
iteration budget). But in practice, **every long-output agent we ship ends up
bypassing PAR's ReAct loop entirely** and calling the LLM directly. That is a
strong design signal: for "pure generation" agents, the ReAct loop is not the
right abstraction. We surveyed how Claude Code, Codex CLI, OpenCode, and
a comparable coding agent handle the same situation, and **none of them treats
`finish_reason=max_tokens` as an iteration-consuming failure**. We propose
making "generation mode" a first-class runtime concept so downstream apps stop
having to choose between *using PAR's runtime* and *getting reliable long
output*.
 
---
 
## 1. Background: the v0.6.0 fix and what it left behind
 
[完整提案内容见 upstream proposal;本附录存档关键部分]

## 2. How mainstream coding agents handle this

| Agent | max_tokens 行为 | Source |
|-------|-----------------|--------|
| Claude Code | 9 个 auto-continue 条件之一 | [INTERNALS.md](https://internals.laxmena.com/p/why-claude-codes-agent-loop-is-over) |
| Codex CLI | 数 reasoning step 不数 token;长 session 走 compaction | [OpenAI blog](https://openai.com/index/unrolling-the-codex-agent-loop/) |
| OpenCode | maxSteps 数 step;纯生成截断是正常 finish | [cefboud blog](https://cefboud.com/posts/coding-agents-internals-opencode-deepdive/) |
| a comparable coding agent | writer subagent + cycle/checkpoint;主 agent 永不总结自己 in-flight 长输出 | [MiMo blog](https://mimo.xiaomi.com/zh/blog/mimo-code-long-horizon) |

[完整 4-agent 表格 + 共同不变量论证,见 original proposal]

## 3. Proposal

### (A) Make `Continue` the default for tool-less agents
### (B) First-class "generation mode" that bypasses the ReAct loop
### (C) Distinguish finish reasons in the result and the loop

[完整描述见 original proposal]

## 4. Why this matters for PAR's positioning

PAR's value is the runtime. Today the moment an integrator needs reliable
long text output, the path of least resistance is to bypass all of that and
call the LLM directly. That pushes integrators *off* PAR exactly for the tasks
where output quality matters most.

## 5. Reproduction (downstream project, PAR v0.6.0)

- Environment: PAR 0.6.0, OCaml 5.4.1, macOS, OpenAI-compatible (MiniMax-M3)
- Symptom: PRD generation (~3000-6000 tokens) frequently times out
- Config: max_iter=10, max_execution_time=120s, on_max_tokens=Return_partial
- Workaround: the downstream project calls LLM directly (llm_chat_raw), keeps PAR for sessions only

## 6. What we're asking for

Accept (A) and/or (B) and/or (C). Happy to turn any into a PR.
```

**完整原文**:本会话上下文(用户消息)中保留。如需逐字存档,见本计划文档之前的会话历史。

### 9.2 v0.6.0 相关上下文

- `docs/v0.6.0-ROADMAP.md` — 当前版本 Roadmap
- `CHANGES.md` v0.6.0-beta 条目 — 已实施的 on_max_tokens_behavior ADT
- `docs/react-loop-fixes-competitive-analysis.md` — ReAct 循环 retry/timeout 竞品分析(注意:status 字段过期,实际 Fix 1-5 已实施)
- `docs/STRATEGY.md` L182 — a comparable coding agent 作为 v0.6.0 三家对比基准之一的历史记录

### 9.3 实施约束(强制)

实施 agent **必须**遵守:

1. **不自行 bump 版本号**(AGENTS.md 强制规则)。所有 `make release-*` 操作一律请求维护者明确指示
2. **不打 git tag**(除非维护者明确要求)
3. **不触发 release workflow**(GH Actions release 只在维护者明确说"发布正式版"时启动)
4. **CHANGES.md 可以加 beta 条目**,但版本号字段写 `[VERSION-TBD]` 占位,等维护者填
5. **`docs/STRATEGY.md` §8 changelog 由维护者写**(战略级决策记录,不属于实施层)
6. **按 AGENTS.md**:`dune build bin/main.exe` + `dune runtest` + `make docs-check` 必须 clean 才算完成
7. **测试不能退化**:现有 1000+ 测试 0 失败
8. **类型严谨**:不引入 `as any` / `Obj.magic` / 字符串 sentinel;`on_max_tokens` 改 option 是 typed 方案,sentinel 值方案禁止

---

**最后更新**: 2026-06-28
**文档版本**: 1.0
