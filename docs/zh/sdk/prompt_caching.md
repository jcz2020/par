<!-- language: zh -->
**[English](../sdk/prompt_caching.md)** · 简体中文

# Prompt 缓存

> 在 v0.6.4-beta 中新增。源真相：`lib/core/types.ml`（类型）、`lib/core/cache_breakpoint.ml`（标记 API）、`lib/core/engine.ml`（预算管理器）。

Prompt 缓存让你避免在 LLM 调用之间重复处理前缀。`` `Anthropic `` provider 对 prompt 中的每个 token 收全价，即使相同的系统指令和工具定义在每次请求中逐字出现。使用缓存后，provider 在首次调用后存储前缀，后续调用只收取一小部分费用。对于复用长系统提示或大型工具列表的 agent，节省会快速累积。

PAR 通过类型化 API 暴露此功能：agent 配置上的 `cache_strategy` 用于粗粒度控制，`mark_tool` / `mark_message` 函数用于细粒度的逐块标记。策略在你通过 `Runtime.create` 创建 agent 或通过 FFI 注册时设置在 `agent_config` 上。

## 概览

不同的 provider 以不同方式处理缓存。

**`` `Anthropic ``** 使用显式 `cache_control` 标记。你将 `cache_control` 字段附加到内容块（系统提示段、工具定义、消息块），Anthropic 为指定 TTL 缓存标记的前缀。没有标记则不会缓存任何内容。

**`` `Openai ``** 自动为共享长公共前缀的 prompt 缓存。不需要标记。效果在使用统计中可见：响应中的 `cached_tokens` 字段指示有多少 prompt token 从缓存提供。

**`` `Ollama ``** 不支持 prompt 缓存。

PAR 的缓存 API 针对 `` `Anthropic `` 的标记系统。当你设置 `cache_strategy` 或使用 `mark_tool` / `mark_message` 时，PAR 在发送到 Anthropic 之前将 `cache_control` 附加到适当的内容块。在 `` `Openai `` 上，这些标记被忽略，自动前缀缓存照常工作。在 `` `Ollama `` 上，缓存是空操作。

## 快速开始

启用缓存最简单的方式：在 agent 上设置 `cache_strategy` 并使用稳定的系统提示。

```ocaml
open Par

let agent = {
  Types.id = "my-agent";
  system_prompt = stable_prompt "You are a helpful assistant.";
  cache_strategy = With_cache_of `Five_min;
  model = { provider = `Anthropic; model_name = "claude-sonnet-4-20250514";
            api_base = None; temperature = 0.7; max_tokens = None;
            top_p = None; stop_sequences = None };
  tools = [];
  max_iterations = 5;
  middleware = [];
  retry_policy = None;
  context_strategy = None;
  resource_quota = None;
  max_execution_time = None;
  system_prompt_template = None;
  early_stopping_method = Types.Force;
  on_max_tokens = None;
  max_continuation_chunks = None;
  tool_timeout = None;
  context_compression_threshold = None;
  compression_cooldown_messages = None;
  context_window_override = None;
}
```

通过 FFI 从 Python 使用 `Runtime.register_agent` 注册启用缓存的 agent：

```python
import json
from par_runtime import Runtime

config = {
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "default_quota": {"max_tokens": 4096, "max_iterations": 10, "timeout_seconds": 30.0},
    "llm_providers": [
        ["anthropic", {"api_key": "sk-ant-..."}]
    ],
}

with Runtime(json.dumps(config)) as rt:
    rt.register_tool("echo", "Echo tool", '{"type": "object"}')
    # 通过 JSON 注册 agent
    agent_config = {
        "id": "my-agent",
        "system_prompt": "You are a helpful assistant.",
        "system_prompt_zone": "stable",
        "cache_strategy": ["With_cache_of", "Five_min"],
        "model": {"model_name": "claude-sonnet-4-20250514", "provider": "anthropic"}
    }
    rt.register_agent(json.dumps(agent_config))
```

就这样。PAR 向 Anthropic 发送 `cache_control` 标记，provider 缓存前缀 5 分钟。

## 稳定 vs 易变系统提示

不是每个系统提示都应该被缓存。PAR 通过 `system_prompt` 类型区分两个区域：

```ocaml
type zone_tag = Zone_stable | Zone_volatile

type system_prompt = {
  sp_raw : string;
  sp_zone : zone_tag;
}
```

**`stable_prompt`** 将提示标记为可缓存。文本在调用之间不会改变。当 `cache_strategy` 请求时，PAR 发送 `cache_control` 标记。

**`volatile_prompt`** 将提示标记为不可缓存。文本每次调用都会改变（例如，包含当前日期或用户特定数据）。PAR 对易变提示跳过 `cache_control` 标记，无论 `cache_strategy` 如何。

构造器：

```ocaml
val stable_prompt : string -> system_prompt
val volatile_prompt : string -> system_prompt
```

### 冲突区域硬失败（v0.6.4+）

将 `cache_strategy = With_cache_of _` 与 `volatile_prompt` 一起设置是错误。PAR 从 `make_agent` 返回 `Error (Invalid_input _)`，而不是静默发送会被 Anthropic 拒绝的标记。

这是早期版本的软失败。硬失败防止浪费 API 调用，并在 agent 创建时使配置错误显而易见。

### 模板区域检测

当你使用 `system_prompt_template` 而非普通 `system_prompt` 时，PAR 从模板变量自动检测区域：

```ocaml
val Template.classify_template_zone : template:string -> zone_tag
```

分类逻辑：

| 变量 | 区域 | 原因 |
|------|------|------|
| `{{agent_id}}` | 稳定 | 在 runtime 内的调用间相同 |
| `{{runtime_id}}` | 稳定 | 在 runtime 内的调用间相同 |
| `{{available_tools}}` | 稳定 | 除非工具集变化否则相同 |
| `{{current_time}}` | 易变 | 每秒变化 |
| 任何用户变量 | 稳定（默认） | 未知变量默认为稳定 |

如果模板中的任何变量是易变的，整个模板被分类为易变。规则是：`Zone_volatile` 支配。这意味着 `{{agent_id}} + {{current_time}}` 产生易变模板，而非混合模板。

## cache_strategy

`agent_config` 上的 `cache_strategy` 类型控制 PAR 是否发送 `cache_control` 标记：

```ocaml
type cache_strategy =
  | No_caching
  | With_cache_of of cache_ttl

type cache_ttl = [ `Five_min | `One_hour ]
```

**`No_caching`**（默认）：不发送 `cache_control` 标记。每次调用都从头处理 prompt。当你需要确定性延迟或 provider 不支持缓存时使用。

**`With_cache_of `Five_min`**：附加 5 分钟 TTL 的 `cache_control`。适合大多数工作负载。缓存的前缀在窗口内的任何调用中被复用。

**`With_cache_of `One_hour`**：附加 1 小时 TTL 的 `cache_control`。更适合长时间运行的 agent，其系统提示和工具定义在较长时间内保持稳定。

策略统一应用：设置 `With_cache_of` 时，PAR 标记系统提示、所有工具定义和最后一条用户消息（适当时）用于缓存。要对单个块进行更精细的控制，使用 `mark_tool` 和 `mark_message`。

## mark_tool 和 mark_message

对于你想缓存特定工具或消息而非所有内容的情况，使用 `Cache_breakpoint` 模块：

```ocaml
val Cache_breakpoint.mark_tool : ttl:cache_ttl -> tool_descriptor -> tool_descriptor
val Cache_breakpoint.mark_message : ttl:cache_ttl -> message -> message
```

### mark_tool

将 `cache_control` 附加到通过 `Runtime.register_tool` 创建的工具描述符。当引擎构建请求时，标记的工具将其 `cache_control` 携带到线路格式中。

```ocaml
let my_tool = Runtime.register_tool rt
  ~name:"code_search"
  ~description:"Search the codebase"
  ~input_schema:(`Assoc [("type", `String "object")])
  ~handler:(fun _input _token -> Types.Success (`String "result"))
  ()

(* 标记工具用于缓存 *)
let cached_tool = Cache_breakpoint.mark_tool ~ttl:`Five_min my_tool.descriptor
```

当工具定义很长（复杂 JSON Schema、详细描述）且你想避免每次调用都重新处理时，这很有用。

### mark_message

将 `cache_control` 附加到消息的**最后**一个内容块。这针对 Anthropic 为缓存目的断开前缀的位置。

```ocaml
let msg : Types.message = {
  role = `User;
  content_blocks = [
    Text_block { text = "Please review this code:"; cache_control = None };
    Text_block { text = long_code_snippet; cache_control = None };
  ];
}

let marked = Cache_breakpoint.mark_message ~ttl:`Five_min msg
(* 最后一个 Text_block 现在有 cache_control = Some { type_ = `Ephemeral; ttl = Some `Five_min } *)
```

如果消息没有内容块，`mark_message` 是空操作（消息原样传递）。

### 优先级和预算管理器

Anthropic 将每次请求的 `cache_control` 标记数量上限设为 4。当候选标记超过 provider 允许的数量时，PAR 的预算管理器决定保留哪些。

每个候选断点携带一个优先级：

| 来源 | 优先级 | 出现时机 |
|------|--------|---------|
| 系统提示 | 100 | 每次 `With_cache_of` 调用 |
| 用户标记的工具（`mark_tool`） | 60 | 当你显式标记工具时 |
| 最后一条用户消息 | 10 | 每次 `With_cache_of` 调用 |

预算管理器按优先级排序候选（最高优先），保留前 N 个（N 是 provider 的上限），丢弃其余。被丢弃的断点通过 `Cache_breakpoint_dropped` 事件报告，以便你调整标记策略。

## 预算管理器

预算管理器位于 `Cache_breakpoint.plan_breakpoints`：

```ocaml
val Cache_breakpoint.plan_breakpoints :
  ?max_override:int ->
  Types.llm_service ->
  Types.breakpoint list ->
  Types.breakpoint_plan
```

它分三步工作：

1. **收集候选**：引擎从系统提示、标记的工具和标记的消息中收集所有 `cache_control` 标记。
2. **按优先级排序**：最高优先级优先（系统提示 100，用户工具 60，最后用户消息 10）。
3. **在上限处拆分**：保留前 `max_breakpoints` 个条目（来自 provider 的 `cache_control_capability`），其余标记为 `Over_budget`。

如果 provider 完全不支持缓存（`cache_control_fn` 返回 `None` 或 `max_breakpoints = 0`），每个候选以 `Unsupported_by_provider` 被丢弃。

你可以用 `~max_override:n` 覆盖上限用于测试或强制特定限制。

```ocaml
type breakpoint_plan = {
  used : breakpoint list;                         (* 将被发送的标记 *)
  dropped : (breakpoint * drop_reason) list;       (* 被跳过的标记 *)
}

type drop_reason =
  | Over_budget                          (* 超过 provider 上限，最低优先级被丢弃 *)
  | Unsupported_by_provider              (* provider 不支持缓存 *)
  | Lower_priority_than_dropped          (* （保留供未来使用） *)
```

## 事件

五个事件通过事件总线追踪缓存行为：

### Cache_write

在 LLM 响应指示新缓存条目被写入后触发。

```ocaml
| Cache_write of {
    tokens_written : int;    (* 存储在缓存中的 token *)
    ttl : cache_ttl;         (* 请求的 TTL *)
  }
```

### Cache_read

在 LLM 响应指示缓存 token 被提供时触发。

```ocaml
| Cache_read of {
    tokens_read : int;              (* 从缓存提供的 token *)
    total_prompt_tokens : int;      (* 上下文的总 prompt token *)
  }
```

### Cache_strategy_skipped

在缓存被整个请求跳过时触发。`reason` 告诉你原因：

```ocaml
| Cache_strategy_skipped of {
    reason : [ `Volatile_system              (* 系统提示是易变的 *)
             | `Volatile_builtins of string list  (* 易变的内置工具 *)
             | `Unsupported_provider          (* provider 没有 cache_control_fn *)
             | `No_strategy ];                (* cache_strategy = No_caching *)
  }
```

### Cache_breakpoint_dropped

在预算管理器丢弃超过 provider 上限的断点时触发：

```ocaml
| Cache_breakpoint_dropped of {
    location : [ `System | `Tool of int | `Message of int * int ];
    reason : drop_reason;
  }
```

### Cache_invalidated_by_skill

在 skill 以使缓存前缀失效的方式修改工具列表时触发。事件报告更改了多少工具以及估计浪费的 token：

```ocaml
| Cache_invalidated_by_skill of {
    skill_id : string;
    before_tool_count : int;
    after_tool_count : int;
    estimated_wasted_tokens : int;
  }
```

## Provider 支持

| Provider | 缓存机制 | `cache_control` 标记 | 自动缓存 |
|----------|---------|---------------------|---------|
| `` `Anthropic `` | 内容块上的显式标记 | 完全支持 | 否 |
| `` `Openai `` | 自动前缀缓存 | 被忽略（无效果） | 是，通过 usage 中的 `cached_tokens` 可见 |
| `` `Ollama `` | 无 | 被忽略 | 否 |

对于 `` `Anthropic ``，PAR 的整个缓存 API（策略、`mark_tool`、`mark_message`、预算管理器）控制发送哪些标记。对于 `` `Openai ``，你不需要做任何事情。当 prompt 前缀在调用间稳定时，provider 自动缓存，并在响应的 `usage` 字段中报告节省。

## FFI / Python 配置

从 Python（通过 `par_runtime` FFI 层）配置 agent 时，使用这些 JSON 形状：

### cache_strategy

```json
{"tag": "No_caching"}
```

```json
{"tag": "With_cache_of", "contents": "Five_min"}
```

```json
{"tag": "With_cache_of", "contents": "One_hour"}
```

### system_prompt_zone

agent 配置上的 `system_prompt_zone` 字段控制系统提示如何分类：

```json
"system_prompt_zone": "stable"
```

```json
"system_prompt_zone": "volatile"
```

当 JSON 中省略 `system_prompt_zone` 时，提示默认为稳定。skill 描述符中 `system_prompt_override` 的裸字符串值也默认为 `Stable_prompt`。

### prompt_cache_key

在 `` `Openai `` provider 配置上，可选的 `prompt_cache_key` 字段让你为 OpenAI 的前缀缓存提供缓存键：

```json
{
    "tag": "Openai",
    "contents": {
        "api_key": "sk-...",
        "base_url": null,
        "organization": null,
        "embedding_model": null,
        "prompt_cache_key": "my-agent-cache-v1"
    }
}
```

此字段是 OpenAI 特有的。`` `Anthropic `` 和 `` `Ollama `` provider 忽略它。

### skill_prompt_zone

Skill prompt 覆盖使用 `skill_prompt_zone` ADT。在 JSON 中，接受三种形式：

```json
"system_prompt_override": "static instructions"
```

裸字符串为向后兼容被当作 `Stable_prompt`。

```json
"system_prompt_override": {"zone": "stable", "text": "static instructions"}
```

```json
"system_prompt_override": {"zone": "volatile", "text": "instructions with {{current_time}}"}
```

```json
"system_prompt_override": {"zone": "both", "stable": "core rules", "volatile": "time-sensitive rules"}
```

`both` 变体将提示拆分为稳定和易变两部分。PAR 连接它们（`stable ^ "\n" ^ volatile`）并将结果标记为易变（任何易变组件使整个提示不可缓存）。

## 另请参阅

- [Agent API 参考](agent.md) — `agent_config` 字段，包括 `cache_strategy` 和 `system_prompt`
- [Skills API](skills.md) — skill prompt 区域和 `skill_prompt_zone` ADT
- [中间件 API](middleware.md) — 用于请求/响应钩子的中间件管道
- [可观测性](observability.md) — 缓存事件的事件总线订阅
