<!-- language: zh -->
**[English](../sdk/skills.md)** · 简体中文

# Skills API

Skill（技能）是系统提示词、工具过滤器和触发条件的可复用包。它们让你将领域专业知识（代码审查、翻译、摘要、RAG）打包成单个文件，PAR 自动发现并在相关时激活。

**状态**: v0.5.2-beta。v1.0 前 API 可能变化。

---

## 什么是 Skill？

PAR 有四个抽象层。Skill 与工具、Agent 和中间件并列：

| 层级 | 打包内容 | 示例 |
|------|----------|------|
| **工具（Tool）** | LLM 可调用的单个函数 | `read`、`web_search`、`bash` |
| **Skill** | 系统提示词 + 工具子集 + 触发条件 | "代码审查员"（审查 prompt + 仅 read/grep 工具） |
| **Agent** | 完整配置：模型、工具、中间件、重试策略 | 使用 GPT-4 + 20 个工具的默认 agent |
| **中间件（Middleware）** | 横切钩子（日志、重试、限流） | 带指数退避的重试 |

**何时创建 Skill** 而非 Agent：
- **Skill**：你想在对话中切换行为而无需重启。Agent 保持不变；Skill 覆盖其提示词和工具过滤器。
- **Agent**：你需要根本不同的模型、工具集或中间件链。

---

## 快速入门

30 秒创建一个 Skill：

```bash
mkdir -p ~/.par/skills/greeter
cat > ~/.par/skills/greeter/skill.md << 'EOF'
---
schema_version: 1
id: greeter
name: Greeter
description: Greet users warmly. Use when the conversation starts or the user says hello.
system_prompt_override: "You are an enthusiastic greeter. Always start with a warm welcome."
tool_filter: All
trigger: Keyword [hello, hi, hey]
---

# Greeter Skill

When activated, greet the user warmly and ask how you can help.
Use their name if provided in the conversation context.
EOF
```

现在启动 PAR 并检查：

```bash
par
> /skills
  greeter              Greet users warmly. Use when the conversation starts...
> /skill greeter
ID:          greeter
Name:        Greeter
Description: Greet users warmly. Use when the conversation starts or the user says hello.
Trigger:     keyword
```

Skill 被自动发现和注册。当用户输入 "hello" 时，keyword 触发器激活该 Skill。

---

## 文件格式

每个 Skill 位于自己的目录中：`~/.par/skills/<id>/skill.md`。

### 目录结构

```
~/.par/skills/greeter/
└── skill.md          ← YAML frontmatter + markdown body
```

### YAML frontmatter 参考

| 字段 | 类型 | 必填 | 默认值 | 描述 |
|------|------|------|--------|------|
| `schema_version` | int | **是** | — | v0.5.2 必须为 `1`。加载器拒绝未知版本。 |
| `id` | string | **是** | — | 小写连字符标识符。必须匹配目录名。 |
| `name` | string | **是** | — | 显示名称。 |
| `description` | string | **是** | — | Skill 的功能 + 何时使用。最多 1024 字符。始终加载（L1 元数据）。 |
| `system_prompt_override` | string \| null | 否 | `null` | Skill 激活时替换 agent 的系统提示词。 |
| `tool_filter` | `All` \| `Only [...]` \| `Except [...]` | 否 | `All` | 限制 LLM 可使用的工具。 |
| `trigger` | `Auto` \| `Manual` \| `Keyword [...]` | 否 | `Auto` | Skill 何时被激活。 |
| `expected_output` | JSON \| null | 否 | `null` | 前瞻性：类型化成功标准（v0.5.2 中为信息性，计划在未来版本中由 LLM 判断）。 |

### Markdown 正文

第二个 `---` 之后的正文是 Skill 的指令。它是**惰性加载**的（L2）——仅在 Skill 激活时读入内存，而非在启动时。这使启动保持快速，即使安装了 50+ 个 Skill。

---

## 触发器类型

`trigger` 字段控制 Skill 何时变为活跃：

### Auto（默认）

Skill 描述被加载到 LLM 的系统提示词中。LLM 自身根据用户消息和描述文本决定是否激活 Skill。

```yaml
trigger: Auto
```

适用于：应该对 LLM "始终可用"的 Skill（摘要器、RAG 助手）。

### Manual

Skill 永远不会自动激活。用户必须显式调用它。

**REPL**（为当前会话激活，应用于后续所有调用）：

```
> /skill use my-skill
Skill activated: my-skill
> hello
[response with my-skill's system_prompt_override applied]
> /skill unuse
Manual skill activation cleared (1 were active).
```

激活在会话内的调用之间是**持久的**，直到用 `/skill unuse` 清除。它与自动触发的 Skill（keyword/auto）组合——`system_prompt_override` 使用后者覆盖前者，`tool_filter` 取交集。用于应在对话一段时间内保持开启的专业工作流。

**独立 CLI**（仅验证——CLI 进程在任何调用之前退出，因此实际上无法应用激活）：

```bash
par skill use my-skill    # validates the skill exists, prints how to activate in REPL
```

适用于：只应在显式请求时触发的 Skill（危险操作、专业工作流）。

### Keyword

一个快速的子字符串预过滤器在 LLM 判断之前运行。只有当用户消息中出现关键词之一时，才会考虑该 Skill：

```yaml
trigger: Keyword [pdf, form, document] confirm
```

- `confirm`（默认）：关键词匹配后，LLM 仍然判断是否激活
- `deterministic`：关键词匹配立即激活，无需 LLM 判断

```yaml
trigger: Keyword [pdf, form] deterministic
```

适用于：有明确领域关键词的 Skill（PDF 提取器、特定语言翻译器）。

### Token 预算

为防止系统提示词爆炸，PAR 将 Skill 描述的总 token 上限设为 **2048**（可通过运行时配置 `skill_token_budget` 配置）。当超出预算时，最低优先级的 Skill 描述会被丢弃并发出警告。

---

## 工具过滤器

限制 Skill 激活时 LLM 可访问的工具：

```yaml
tool_filter: All                    # 所有已注册工具（默认）
tool_filter: Only [read, grep] # 仅这些工具
tool_filter: Except [bash]          # 除这些工具外的所有工具
```

当多个 Skill 同时激活时，过滤器按**交集**组合（最严格的获胜）。这确保没有 Skill 可以放宽另一个 Skill 的限制。

---

## 发现机制

PAR 从三个来源发现 Skill，按以下优先级顺序（首个匹配获胜）：

1. **SDK 注册**（最高）：`Runtime.register_skill(descriptor)` — 显式、编程式
2. **项目级**：`./.par/skills/<id>/skill.md` — 检入仓库
3. **用户级**：`~/.par/skills/<id>/skill.md` — 用户全局默认
4. **内置**（最低）：PAR 附带的 4 个入门 Skill

**热重载**：在每次 `Runtime.invoke` 时，PAR 检查任何 Skill 目录的 mtime 是否变化。如果是，自动重新扫描。你也可以强制重新扫描：

```bash
par skill reload
```

---

## CLI 用法

### REPL 命令

| 命令 | 描述 |
|------|------|
| `/skills` | 列出所有已注册的 Skill 及描述预览 |
| `/skill <id>` | 显示特定 Skill 的完整详情（默认子命令） |
| `/skill use <id>` | 手动激活 Skill（覆盖其触发器；持久直到 `/skill unuse`） |
| `/skill unuse` | 清除手动激活；后续调用仅使用自动触发的 Skill |
| `/skill create <id>` | 交互式向导：在 `~/.par/skills/<id>/skill.md` 创建新 Skill |

**激活语义**：`/skill use <id>` 将 `<id>` 添加到运行时的 `user_activated_skills` 集合。在每次 `invoke` 时，此集合中的 Skill 无论其 `trigger`（Auto/Manual/Keyword）如何都会被解析，并与任何自动触发的 Skill 组合。`system_prompt_override` 使用后者覆盖（顺序是：自动触发在先，用户激活在后）；`tool_filter` 取交集（最严格的获胜）。Manual 触发的 Skill **只能**通过 `/skill use` 激活——否则它们是死的。

### 独立命令

```bash
par skill list                    # 列出所有已发现的 Skill（非交互式）
par skill show <id>               # 显示 Skill 详情（id、name、trigger、tool_filter、override）
par skill use <id>                # 验证 Skill 可用；打印激活提示
par skill create [id]             # 交互式向导（见下文）；id 可选，省略时提示输入
par skill reload                  # 强制文件系统重新扫描（使 mtime 缓存失效）
```

### `/skill create` 向导

向导提示所有 8 个 frontmatter 字段并写入有效的 `skill.md` 到 `~/.par/skills/<id>/skill.md`：

```
$ par skill create my-analyst
Name [my-analyst]:
Description (≤1024 chars): Analyze data and report insights
System prompt override (blank = none, \n for newlines): You are a data analyst.
Tool filter [All|Only|Except] (default: All): Only
Only tools (comma-separated): read, grep, bash
Trigger [Auto|Manual|Keyword] (default: Auto): Keyword
Keywords (comma-separated): data, analyze, report
Expected output JSON schema (blank = none):
Created: /home/user/.par/skills/my-analyst/skill.md
Use /skill use my-analyst to activate it in this session.
```

文件立即可被 `/skills` 和 `par skill list` 发现（向导调用 `Skill_loader.force_reload` 使 mtime 缓存失效）。编辑生成文件中的 `## Instructions` 和 `## Examples` 部分来自定义 L2 正文。

---

## SDK API

### Python

```python
from par_runtime import Runtime
import json

rt = Runtime(config_json)

# 以编程方式注册 Skill
rt.register_skill(json.dumps({
    "schema_version": 1,
    "id": "my-skill",
    "name": "My Skill",
    "description": "Does something useful.",
    "system_prompt_override": "You are a specialist.",
    "tool_filter": "Only [read]",
    "trigger": "Auto"
}))

# 列出所有已注册的 Skill
skills = rt.list_skills()
for s in skills:
    print(f"  {s['id']}: {s['description']}")
```

### OCaml

```ocaml
(* Create a skill descriptor *)
let descriptor =
  Par.Runtime.make_skill
    ~id:"my-skill"
    ~description:"Does something useful."
    ~system_prompt_override:"You are a specialist."
    ~tool_filter:(Par.Types.Only ["read"])
    ~trigger:Par.Types.Auto
    ()
  |> Result.get_ok

(* Register it *)
let _ = Par.Runtime.register_skill rt descriptor

(* List all skills *)
let skills = Par.Runtime.list_skills rt
List.iter (fun s -> Printf.printf "  %s: %s\n" s.Par.Types.id s.Par.Types.description) skills
```

---

## 内置 Skill

PAR 附带 4 个入门 Skill。通过在 `~/.par/skills/` 或 `./.par/skills/` 中创建相同 `id` 的 Skill 来覆盖它们：

| ID | 触发器 | 工具 | 描述 |
|----|--------|------|------|
| `code-reviewer` | Keyword: review, audit | read, grep, find | 审查代码的 bug、安全性和风格 |
| `summarizer` | Auto | All | 将长文本摘要为要点 |
| `translator` | Keyword: translate, 翻译 | All | 在语言之间翻译 |
| `rag-assistant` | Auto | All | 使用检索到的文档上下文回答 |

---

## 示例

### 示例 1：自定义 Skill — Python 数据分析师

```bash
mkdir -p ~/.par/skills/python-analyst
cat > ~/.par/skills/python-analyst/skill.md << 'EOF'
---
schema_version: 1
id: python-analyst
name: Python Data Analyst
description: Analyze Python code for data science patterns. Use when the user asks about pandas, numpy, or data analysis code.
system_prompt_override: "You are a Python data science expert. Focus on pandas/numpy patterns, performance, and correctness."
tool_filter: Only [read, grep, find]
trigger: Keyword [pandas, numpy, dataframe, data analysis]
---

# Python Data Analyst

When analyzing Python code:
1. Check for common pandas anti-patterns (chained indexing, in-place modification)
2. Verify numpy vectorization opportunities
3. Suggest type annotations for data science functions
4. Flag potential memory issues with large DataFrames
EOF
```

### 示例 2：覆盖内置 Skill

要自定义 `summarizer` Skill，创建一个覆盖内置的项目级 Skill：

```bash
mkdir -p .par/skills/summarizer
cat > .par/skills/summarizer/skill.md << 'EOF'
---
schema_version: 1
id: summarizer
name: Tech Summarizer
description: Summarize technical documents. Use when the user asks for a summary or TL;DR.
system_prompt_override: "You are a technical writer. Summarize with structured headers, preserve all technical terms, and include a one-sentence TL;DR at the top."
tool_filter: All
trigger: Auto
---

# Tech Summarizer

Format summaries as:
## TL;DR
[one sentence]

## Key Points
- bullet points

## Technical Details
[code blocks, configs, commands]
```

因为它在 `./.par/skills/`（项目级），它优先于内置的 `summarizer`（最低优先级）。

### 示例 3：确定性关键词 Skill

一个在关键词匹配时立即激活的 Skill，无需 LLM 判断：

```bash
mkdir -p ~/.par/skills/log-parser
cat > ~/.par/skills/log-parser/skill.md << 'EOF'
---
schema_version: 1
id: log-parser
name: Log Parser
description: Parse and analyze log files. Use when the user mentions logs, stack traces, or error output.
system_prompt_override: "You are a log analysis expert. Extract timestamps, error codes, and stack traces. Correlate events across log lines."
tool_filter: Only [read, grep, bash]
trigger: Keyword [log, stack trace, error output, traceback] deterministic
---

# Log Parser

1. Identify the log format (syslog, JSON, plain text)
2. Extract all ERROR/WARN lines
3. Find the root cause (first error in the chain)
4. Suggest fixes based on the error pattern
```

`deterministic` 标志意味着：如果用户的消息包含 "log"、"stack trace"、"error output" 或 "traceback"，此 Skill 立即激活——无需 LLM 往返。

---

## 分层上下文加载

PAR 使用受 Anthropic Agent Skills 启发的 2 级上下文加载模型：

| 层级 | 内容 | 何时加载 | Token 成本 |
|------|------|----------|------------|
| **L1** | `id`、`name`、`description`（仅 frontmatter） | 启动时，始终在内存中 | 每个 Skill 约 100 token |
| **L2** | Markdown 正文（指令） | 仅当 Skill 激活时 | 可变（取决于 Skill） |

这意味着你可以安装 50+ 个 Skill 而不会使每次 LLM 调用膨胀——只有 L1 元数据始终驻留。L2 正文在 Skill 触发时按需加载。

---

## 迁移与版本控制

`schema_version` 字段（当前为 `1`）让 PAR 可以演进 Skill 格式而不破坏现有 Skill：

- **未知版本**在加载时被拒绝并给出明确错误：`"skill targets schema_version 2, current is 1. See MIGRATION.md."`
- **旧版本**可能被自动迁移（未来）或被拒绝并给出升级说明。

当 PAR 在 v0.6+ 中添加新的 frontmatter 字段时，`schema_version: 1` 的 Skill 仍然有效——新字段默认为合理的值。

---

## 另请参阅

- [Agent API](agent.md) — Agent、`Runtime.invoke`、工具处理器
- [工具](tools.md) — 20 个内置工具、自定义注册
- [RAG API](rag.md) — embedding、向量存储、检索（被 `rag-assistant` Skill 使用）
- [架构](../explanation/architecture.md) — PAR 内部工作原理
