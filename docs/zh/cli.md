# par_cli -- CLI 参考
[English](../cli.md) · **简体中文**

par_cli 是 P-A-R (Programmable Agent Runtime) 的命令行工具，用于 SDK 功能验证和交互式调试。它封装了 par SDK，提供 REPL 对话、单次问答和配置管理三种模式。

命令结构：

```
par [全局选项] <子命令> [子命令选项] [参数]
```

子命令列表：

| 子命令 | 用途 |
|--------|------|
| (无) | 启动交互式 REPL（默认） |
| `config` | 运行配置向导 |
| `ask` | 单次问答 |
| `update` | 检查并更新 par 到最新版本 |
| `history <session_id>` | 显示指定会话的事件历史 |
| `stats` | 显示使用统计和最近的会话 |

## 安装

从源码构建：

```bash
git clone https://github.com/jcz2020/par.git && cd par
opam install . --deps-only
dune build @install
dune install
```

安装后 `par` 可执行文件将可用。运行 `par --version` 查看已安装版本（源自 `dune-project`，通过 `Cmdliner.Cmd.info` 的 `~version` 声明）。

如需安装到自定义路径，使用：

```bash
dune install --prefix /path/to/prefix
```

## 全局选项

以下选项同时适用于 `par`（REPL）和 `par ask` 命令，优先级高于配置文件中的对应字段。

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `--provider PROVIDER` | string | `openai`（配置文件默认值） | LLM 提供商：`openai` 或 `anthropic` |
| `--api-key KEY` | string | (配置文件值) | API 密钥，覆盖配置文件中的 `api_key` |
| `--api-base URL` | string | (配置文件值或提供商默认值) | 自定义 API 基础 URL，覆盖配置文件 |
| `--model NAME` | string | `gpt-4`（配置文件默认值） | 模型名称，覆盖配置文件中的 `model` |
| `--persistence BACKEND` | string | `sqlite`（配置文件默认值） | 持久化后端：`sqlite` 或 `postgres` |
| `--db-uri URI` | string | `postgresql://localhost/par`（postgres 时） | PostgreSQL 连接 URI，仅 postgres 后端生效 |
| `--temperature FLOAT` | float | `0.7`（配置文件默认值） | 采样温度，覆盖配置文件 |
| `--system-prompt PROMPT` | string | `You are a helpful assistant.`（配置文件默认值） | Agent 系统提示词，覆盖配置文件 |
| `--max-iterations N` | int | `10` | ReAct 循环最大迭代次数 |
| `--max-tokens N` | int | (配置文件值) | Max tokens per LLM response |
| `--top-p FLOAT` | float | (配置文件值) | Top-p sampling parameter (0.0-1.0) |
| `--no-parallel-tools` | flag | (配置文件值) | Disable parallel tool execution |
| `--retention-days N` | int | `7` | Event retention in days. 0 = never prune |

所有全局选项均为可选（`opt` 类型）。未指定时从 `~/.par/config.json` 读取对应值。

## par (默认: REPL)

启动交互式 ReAct Agent 对话。读取配置文件后进入 readline 循环。

**用法**

```
par [全局选项]
```

**前提条件**

必须先运行 `par config` 创建 `~/.par/config.json`，否则输出：

```
未找到配置文件。请先运行 `par config` 进行配置。
```

**REPL 行为**

启动后显示：

```
输入消息开始对话（Ctrl+D 退出）
```

提示符为 `> `。每行输入作为消息发送给 agent（agent id: `default-agent`），agent 的文本响应直接打印。空行（trim 后为空字符串）会被忽略，不发送。

### REPL 命令

在 REPL 中，以 `/` 开头的输入会被解析为命令：

| 命令 | 说明 |
|------|------|
| `/help` | 显示可用命令 |
| `/steer <消息>` | 注入干预消息（在下一轮对话中生效） |
| `/followup <消息>` | 注入后续指导（在下一轮对话中生效） |
| `/health` | 显示运行时健康状态（JSON） |
| `/metrics` | 显示运行时指标（JSON） |
| `/quit` 或 `/exit` | 退出 REPL |

普通文本输入会作为用户消息发送给 agent。

**退出**

`Ctrl+D`（EOF）退出 REPL，显示 `再见！`。

**输出格式**

- 有文本响应时：直接打印响应文本
- 无文本响应时：输出完整 LLM 响应的 JSON 格式（`Yojson.Safe.pretty_to_string`）

**退出码**

- `0`：正常退出（Ctrl+D）
- `1`：配置文件不存在 / 运行时创建失败 / agent 注册失败 / LLM 调用错误

**示例**

```bash
# 使用配置文件默认设置启动 REPL
par

# 指定 Anthropic 提供商和模型
par --provider anthropic --model claude-3-sonnet-20240229

# 使用自定义系统提示词
par --system-prompt "你是一个 OCaml 专家"
```

## par config

运行交互式配置向导。引导用户设置 LLM 提供商、密钥、模型等参数，结果写入配置文件。

**用法**

```
par config
```

该命令不接受任何额外选项。

**向导流程**

1. 若配置文件已存在，显示当前配置摘要并提示修改；否则显示欢迎信息
2. 依次提示以下字段（每项显示默认值，按回车保留）：

| 字段 | 提示文本 | 默认值 | 说明 |
|------|----------|--------|------|
| Provider | `Provider (openai/anthropic) [openai]:` | `openai` | 选择 LLM 提供商 |
| API Key | `API Key: ` | (无，必须输入) | 提供商对应的 API 密钥 |
| API Base URL | `API Base URL (默认: https://api.openai.com/v1): ` | (无) | 可选自定义 URL。按回车跳过 |
| Model name | `Model name [gpt-4]:` | `gpt-4` | 模型标识 |
| Persistence | `Persistence (sqlite/postgres) [sqlite]:` | `sqlite` | 持久化后端类型 |
| DB URI | `DB URI (留空跳过): ` | (无) | 仅当选择 `postgres` 时出现 |
| Temperature | `Temperature [0.7]:` | `0.7` | 采样温度（浮点数） |
| System prompt | `System prompt [You are a helpful assistant.]:` | `You are a helpful assistant.` | Agent 系统提示词 |

3. 完成后显示 `配置已保存到 ~/.par/config.json`

**配置文件位置**

```
~/.par/config.json
```

目录 `~/.par/` 在首次保存时自动创建（权限 `0o755`）。

**退出码**

- `0`：配置成功保存
- `1`：向导中 stdin 遇到 EOF（使用默认值填充）

## par ask

单次问答模式。向 agent 发送一条消息，打印响应后退出。

**用法**

```
par ask "问题" [全局选项]
```

**位置参数**

| 参数 | 说明 |
|------|------|
| `QUESTION` (必填) | 要提问的问题字符串 |

**前提条件**

同 REPL：需要 `~/.par/config.json` 存在。

**输出格式**

- 有文本响应时：打印响应文本加换行
- 无文本响应时：打印完整 LLM 响应 JSON

**退出码**

- `0`：成功获得响应
- `1`：配置文件不存在 / LLM 调用失败

**示例**

```bash
# 基本问答
par ask "什么是 ReAct 模式？"

# 使用 Anthropic 并指定模型
par ask "解释 OCaml 的 GADT" --provider anthropic --model claude-3-sonnet-20240229

# 覆盖温度和系统提示词
par ask "写一段快速排序" --temperature 0.2 --system-prompt "用 OCaml 回答"
```

## par history

显示指定会话的事件历史。按时间顺序从持久化后端读取事件。

**用法**

```
par history <session_id>
```

**位置参数**

| 参数 | 说明 |
|------|------|
| `SESSION_ID` (必填) | 要查询的会话 ID |

**前提条件**

同 REPL：需要 `~/.par/config.json` 存在。

**退出码**

- `0`：历史显示成功
- `1`：配置文件不存在 / 会话未找到

## par stats

显示使用统计和最近的会话。从持久化后端读取聚合指标。

**用法**

```
par stats
```

该命令不接受任何额外选项。

**前提条件**

同 REPL：需要 `~/.par/config.json` 存在。

**退出码**

- `0`：统计显示成功
- `1`：配置文件不存在 / 持久化错误

## 配置文件格式

配置文件为标准 JSON，位于 `~/.par/config.json`。以下是包含全部字段的完整示例：

```jsonc
{
  // LLM 提供商标识。可选值："openai"（默认）或 "anthropic"
  "provider": "openai",

  // API 密钥。必填，空字符串将导致 API 调用失败
  "api_key": "sk-xxxxxxxxxxxxxxxx",

  // 自定义 API 基础 URL。可选，null 表示使用提供商默认地址
  // OpenAI 默认: https://api.openai.com/v1
  // Anthropic 默认: https://api.anthropic.com
  // ZhipuAI (OpenAI 兼容): https://open.bigmodel.cn/api/paas/v4
  "api_base": null,

  // 模型名称。必须与提供商支持的模型匹配
  // OpenAI 示例: "gpt-4", "gpt-4o", "gpt-3.5-turbo"
  // Anthropic 示例: "claude-3-sonnet-20240229", "claude-3-opus-20240229"
  // ZhipuAI 示例: "glm-4", "glm-4-flash"
  "model": "gpt-4",

  // 持久化后端。可选值："sqlite"（默认）或 "postgres"
  "persistence": "sqlite",

  // PostgreSQL 连接 URI。仅 persistence 为 "postgres" 时有效
  // 默认值: "postgresql://localhost/par"
  "db_uri": null,

  // 采样温度。浮点数，范围通常 0.0 ~ 2.0
  "temperature": 0.7,

  // Agent 系统提示词
  "system_prompt": "You are a helpful assistant.",

  // ReAct 循环最大迭代次数
  "max_iterations": 10,

  // 单次 LLM 响应的 token 上限。null 表示不限制，使用模型默认值
  "max_tokens": null,

  // Top-p（nucleus）采样参数，范围 0.0 ~ 1.0。null 表示使用提供商默认
  "top_p": null,

  // 是否允许并行执行多个工具调用
  "parallel_tool_execution": true,

  // 系统提示词模板变量（role / task 等由 par config 设置）
  "template_variables": {
    "role": "AI助手",
    "task": "回答用户问题并提供帮助"
  },

  // 自定义系统提示词模板。null 时使用内置默认模板
  "system_prompt_template_override": null
}
```

**字段说明**

- `api_base` 和 `db_uri` 为可选字段，JSON 中可设为 `null` 或省略
- `provider` 值不区分大小写（内部使用 `String.lowercase_ascii` 匹配）
- CLI 标志的优先级高于配置文件；未指定 CLI 标志时回退到配置文件值

## 系统提示词模板

CLI 内置默认模板：

```
你是{{role}}，你的任务是{{task}}。
当前可用工具：{{available_tools}}。
当前时间：{{current_time}}。
```

模板变量：
- `role`、`task` — 用户定义，通过 `par config` 设置
- `available_tools` — 自动填充（当前注册的工具列表）
- `current_time` — 自动填充（ISO 8601 格式）

高级用户可在 `~/.par/config.json` 中设置 `system_prompt_template_override` 字段自定义完整模板。

## 环境变量

par_cli 本身不直接读取环境变量。API 密钥通过配置文件或 `--api-key` CLI 标志传入。

如果你使用需要环境变量认证的 OpenAI 兼容提供商，可以通过以下方式间接使用：

| 环境变量 | 说明 |
|----------|------|
| `HOME` | 用于定位配置目录 `~/.par/`。缺失时回退到 `/` |
| `OPENAI_API_KEY` | par_cli 不直接读取此变量，但 OpenAI 官方 SDK 可能使用 |
| `ANTHROPIC_API_KEY` | par_cli 不直接读取此变量，但 Anthropic 官方 SDK 可能使用 |
| `ZAI_API_KEY` | ZhipuAI 的密钥变量，需在 config wizard 的 API Key 字段手动填入 |

**最佳实践**：将密钥直接写入 `~/.par/config.json`（通过 `par config` 向导），或每次使用 `--api-key` 标志传入。

## 示例

以下是 8 个实际使用场景的调用示例：

**1. 首次配置**

```bash
par config
```

启动向导，按提示输入 Provider、API Key、Model 等信息。

**2. 使用 ZhipuAI (OpenAI 兼容)**

```bash
par config
# Provider: openai
# API Key: <你的 ZhipuAI 密钥>
# API Base URL: https://open.bigmodel.cn/api/paas/v4
# Model: glm-4

par ask "你好"
```

**3. 使用 Anthropic**

```bash
par config
# Provider: anthropic
# API Key: <你的 Anthropic 密钥>
# Model: claude-3-sonnet-20240229

par ask "解释 Rust 的所有权系统"
```

**4. 交互式对话**

```bash
par
```

进入 REPL，`> ` 提示符下输入消息，`Ctrl+D` 退出。

**5. 覆盖温度进行精确问答**

```bash
par ask "1+1等于几" --temperature 0.0
```

**6. 使用自定义系统提示词**

```bash
par --system-prompt "你只回答中文，用古文风格" ask "什么是机器学习"
```

**7. 使用 PostgreSQL 后端**

```bash
par --persistence postgres --db-uri "postgresql://user:pass@host/par_db"
```

**8. 脚本中的单次调用**

```bash
result=$(par ask "将以下英文翻译为中文: Hello World" --temperature 0.1)
echo "$result"
```

## 退出码

| 退出码 | 含义 |
|--------|------|
| `0` | 命令成功执行 |
| `1` | 发生错误（配置缺失、运行时创建失败、LLM 调用失败等） |

`par config` 的退出码始终为 `0`（配置文件写入成功）。

`par` 和 `par ask` 在以下情况返回 `1`：

- `~/.par/config.json` 不存在（输出 `未找到配置文件。请先运行 par config 进行配置。`）
- SQLite 数据库打开失败
- 运行时（Runtime）创建失败
- Agent 注册失败
- LLM 调用失败（包括超时、速率限制、权限拒绝等）
- PostgreSQL 后端未安装依赖（输出 `PostgreSQL backend requires 'opam install postgresql' then rebuild`）

## 故障排除

### 未找到配置文件

```
未找到配置文件。请先运行 `par config` 进行配置。
```

**原因**：`~/.par/config.json` 不存在。

**解决**：运行 `par config` 创建配置文件。

### SQLite 数据库错误

```
Error opening SQLite database: ...
```

**原因**：当前工作目录下 `par.db` 文件权限不足或磁盘空间不足。

**解决**：检查当前目录写权限，或删除旧的 `par.db` 文件后重试。

### PostgreSQL 后端不可用

```
PostgreSQL backend requires 'opam install postgresql' then rebuild
```

**原因**：PostgreSQL 持久化后端需要额外的 OCaml 包。

**解决**：

```bash
opam install postgresql
dune clean && dune build
```

### API 调用失败

```
Error: External failure: ...
Error: Rate limited
Error: Permission denied: ...
```

**原因**：API 密钥无效、额度用尽、或网络问题。

**解决**：

1. 检查 `~/.par/config.json` 中的 `api_key` 是否正确
2. 使用 `--api-base` 确认 API 地址是否可达
3. 确认 `provider` 与密钥类型匹配（OpenAI 密钥不能用于 Anthropic 端点）

### OpenAI 兼容提供商连接失败

**原因**：`api_base` URL 格式不正确，或提供商的 API 兼容性有问题。

**解决**：确认 URL 以 `/v1` 结尾（如 ZhipuAI 为 `https://open.bigmodel.cn/api/paas/v4`），且提供商支持 OpenAI Chat Completions API 格式。

### 配置文件 JSON 解析失败

**原因**：手动编辑配置文件时引入了语法错误。

**解决**：运行 `par config` 重新生成，或使用 `python3 -m json.tool ~/.par/config.json` 验证 JSON 格式。

## 另请参阅

- [快速入门](quickstart.md) -- 安装与首次使用指南
- [SDK 概览](sdk/overview.md) -- par SDK 架构与模块说明
- [Agent 文档](sdk/agent.md) -- Agent 注册与配置详解
- [Workflow 文档](sdk/workflow.md) -- 工作流引擎使用指南
- [Middleware 文档](sdk/middleware.md) -- 中间件配置参考
