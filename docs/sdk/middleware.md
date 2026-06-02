# Middleware API 参考

本文档描述 P-A-R SDK 的中间件管道，包括 7 个内置中间件和自定义中间件编写指南。

## 中间件概念

中间件通过 `middleware_hook` 类型定义，作为横切关注点的拦截器插入 Agent 执行管道。
Engine 使用"俄罗斯套娃"（Russian Doll）模式组合中间件链 -- `List.fold_right` 保证
列表中靠前的中间件包裹靠后的中间件。

### middleware_hook

```ocaml
type middleware_hook = {
  name : string;
  on_before_llm : (conversation -> conversation option) option;
  on_after_llm : (llm_response -> llm_response option) option;
  on_before_tool : (tool_call -> tool_call option) option;
  on_after_tool : (tool_call * handler_result -> handler_result option) option;
  on_error : (error_category -> handler_result option) option;
}
```

每个钩子返回 `Some modified_value` 表示修改了值，`None` 表示透传。

中间件在 `agent_config.middleware` 列表中声明，按列表顺序从外到内包裹。

## Logging

记录所有 LLM 和工具调用的日志。零配置，开箱即用。

```ocaml
val Logging.logging : Types.middleware_hook
```

### 日志内容

| 钩子 | 级别 | 内容 |
|------|------|------|
| `on_before_llm` | info | 消息数量 |
| `on_after_llm` | info | finish_reason, model 名称 |
| `on_before_tool` | info | 工具名 + 参数 |
| `on_after_tool` | info/warn | 成功时 info，失败时 warn（含错误消息） |
| `on_error` | err | 错误信息 |

### 使用

```ocaml
let agent = {
  agent with
  middleware = [ Logging.logging ];
}
```

## Retry

可配置的指数退避重试中间件，处理 LLM 和工具调用的瞬态错误。

```ocaml
type retry_config = {
  max_attempts : int;     (* 最大重试次数，默认 3 *)
  base_delay : float;    (* 基础延迟（秒），默认 2.0 *)
  max_delay : float;     (* 最大延迟（秒），默认 30.0 *)
}

val Retry.default_retry_config : retry_config

val Retry.retry :
  ?config:retry_config ->
  ?policy:Types.retry_policy ->
  unit -> Types.middleware_hook
```

### retry_policy 类型

```ocaml
type retry_policy = {
  max_attempts : int;
  initial_delay : float;
  backoff : backoff_strategy;         (* Exponential / Fixed / Linear *)
  retry_on : retryable_condition list; (* Timeout / Rate_limited / External_failure / ... *)
  jitter : float option;               (* 随机抖动因子 *)
}

type backoff_strategy =
  | Exponential of { base : float; max_delay : float }
  | Fixed of float
  | Linear of { increment : float; max_delay : float }

type retryable_condition =
  | Timeout | Rate_limited | External_failure
  | Connection_error | Any_retryable
```

### 使用示例

```ocaml
(* 使用默认配置 *)
let retry_hook = Retry.retry ()

(* 自定义配置 *)
let retry_hook = Retry.retry ~config:{
  max_attempts = 5;
  base_delay = 1.0;
  max_delay = 60.0;
} ()

(* 使用完整 retry_policy 控制更多参数 *)
let retry_hook = Retry.retry ~policy:{
  max_attempts = 4;
  initial_delay = 1.0;
  backoff = Exponential { base = 2.0; max_delay = 30.0 };
  retry_on = [ Types.Timeout; Types.Rate_limited ];
  jitter = Some 0.1;
} ()
```

默认 `retry_config` 生成指数退避策略：`delay = min(base^attempt, max_delay)`。

## Rate_limit

滑动窗口限速中间件，控制 LLM 请求频率。

```ocaml
type rate_limit_config = {
  max_requests : int;    (* 窗口内最大请求数，默认 60 *)
  window : float;       (* 窗口时长（秒），默认 60.0 *)
}

val Rate_limit.default_rate_limit_config : rate_limit_config

val Rate_limit.rate_limit :
  ?config:rate_limit_config ->
  unit -> Types.middleware_hook
```

### 行为

- `on_before_llm`：检查当前窗口内的请求数，超限时在对话 metadata 中标记
  `("rate_limited", true)`
- `on_error`：收到 `Rate_limited` 错误时，计算 `retry_after` 时间并附加到
  错误 metadata 中

### 使用示例

```ocaml
(* 限制每分钟 30 次请求 *)
let rate_hook = Rate_limit.rate_limit ~config:{
  max_requests = 30;
  window = 60.0;
} ()
```

## Timeout

将超时错误统一转换为标准格式。

```ocaml
val Timeout.timeout_middleware : default_timeout:float -> Types.middleware_hook
```

### 行为

- `on_before_tool`：透传（占位）
- `on_error`：将 `Timeout` 错误转换为带标准消息的 `Error` 结果

配合 `Cancellation.with_timeout` 使用实现真正的超时控制：

```ocaml
Cancellation.with_timeout 30.0 token (fun token ->
  Engine.run_agent token agent message llm registry)
```

## Validation

JSON 输入/输出校验中间件，确保 LLM 响应和工具参数格式正确。

```ocaml
val Validation.validation :
  ?strict:bool ->   (* 默认 false：宽松模式 *)
  unit -> Types.middleware_hook
```

### 行为

| 模式 | on_after_llm | on_before_tool | on_after_tool |
|------|-------------|----------------|---------------|
| 宽松 (`strict=false`) | 缺少 text 和 tool_calls 时 warn 并补充空字符串 | 非 object 参数自动替换为 `{}` | -- |
| 严格 (`strict=true`) | 同上，但使用 err 级别 | 非 object 参数标记为无效，`on_after_tool` 返回错误 | 若参数已标记无效，返回错误结果 |

### 使用示例

```ocaml
(* 开发环境用宽松模式 *)
let validation_hook = Validation.validation ()

(* 生产环境用严格模式 *)
let validation_hook = Validation.validation ~strict:true ()
```

## Pii_mask

在 LLM 请求/响应和工具调用中自动检测和脱敏个人身份信息（PII）。

```ocaml
val Pii_mask.pii_mask :
  ?patterns:string list ->         (* 自定义检测模式，默认内置 4 类 *)
  ?replacement:string ->           (* 替换文本，默认 "[REDACTED]" *)
  unit -> Types.middleware_hook
```

### 默认检测模式

| 类别 | 模式 |
|------|------|
| 邮箱 | `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z][a-zA-Z]+` |
| 电话 | `XXX-XXX-XXXX` / `XXX.XXX.XXXX` / 10 位连续数字 |
| SSN | `XXX-XX-XXXX` |
| 信用卡 | `XXXX-XXXX-XXXX-XXXX` / `XXXX XXXX XXXX XXXX` |

### 行为

- `on_before_llm`：扫描所有消息 content，替换匹配的 PII
- `on_after_llm`：扫描 LLM 响应 text（防止 LLM 回显 PII）
- `on_before_tool`：递归扫描工具参数 JSON 中所有字符串值
- `on_after_tool`：递归扫描工具结果 JSON 和错误消息

### 使用示例

```ocaml
(* 使用默认模式 *)
let pii_hook = Pii_mask.pii_mask ()

(* 自定义模式和替换文本 *)
let pii_hook = Pii_mask.pii_mask
  ~patterns:["my-custom-pattern"]
  ~replacement:"[DATA REMOVED]"
  ()
```

## Sanitize_tool_output (v0.2.0)

检测并清洗工具输出中的 prompt injection 模式，防止 Agent 被恶意工具输出劫持。

```ocaml
type sanitize_action =
  [ `Replace of string    (* 替换匹配内容 *)
  | `Tag                  (* 在输出前后添加标签 *)
  | `Block ]              (* 完全阻断输出 *)

type sanitize_config = {
  patterns : string list;
  action : sanitize_action;
}

val Sanitize_tool_output.default_config : sanitize_config

val Sanitize_tool_output.sanitize_tool_output :
  ?config:sanitize_config ->
  unit -> Types.middleware_hook
```

### 默认检测模式

```
"ignore previous", "ignore all previous", "you are now",
"system:", "new instructions", "disregard"
```

### 三种处理策略

| 策略 | 行为 |
|------|------|
| `Replace text` | 将匹配文本替换为指定字符串（默认 `[SANITIZED]`） |
| `Tag` | 保留输出但在开头添加 `[SANITIZED-OUTPUT: ...]` 标记 |
| `Block` | 拒绝整个输出，替换为 `[SANITIZED: blocked ...]` |

### 行为

- 仅在 `on_after_tool` 钩子中生效
- 递归扫描工具结果 JSON 中所有字符串值
- 同时扫描错误消息

### 使用示例

```ocaml
(* 使用默认配置 *)
let sanitize_hook = Sanitize_tool_output.sanitize_tool_output ()

(* 严格模式：阻断含注入的输出 *)
let sanitize_hook = Sanitize_tool_output.sanitize_tool_output
  ~config:{
    patterns = [
      "ignore previous"; "ignore all previous";
      "you are now"; "system:"; "new instructions";
      "disregard"; "forget everything";
    ];
    action = `Block;
  }
  ()
```

## 组合中间件

中间件按列表顺序排列，靠前的在外层包裹靠后的。典型生产环境配置：

```ocaml
let agent = {
  agent with
  middleware = [
    Logging.logging;                           (* 最外层：记录所有请求 *)
    Pii_mask.pii_mask ();                      (* 脱敏用户输入 *)
    Rate_limit.rate_limit ~config:{
      max_requests = 30; window = 60.0;
    } ();                                     (* 限速 *)
    Retry.retry ~config:{
      max_attempts = 3; base_delay = 2.0; max_delay = 30.0;
    } ();                                     (* 重试 *)
    Validation.validation ~strict:true ();     (* 严格校验 *)
    Sanitize_tool_output.sanitize_tool_output ();  (* 输出清洗 *)
  ];
}
```

执行流程：请求 -> Logging -> Pii_mask -> Rate_limit -> Validation -> LLM
响应 -> Validation -> Sanitize -> Retry -> Rate_limit -> Pii_mask -> Logging

## 自定义中间件

编写自定义中间件只需构造一个 `middleware_hook` record。以下示例统计 LLM 调用次数：

```ocaml
let counter_middleware () =
  let count = ref 0 in
  {
    Types.name = "call_counter";
    on_before_llm = Some (fun _conv ->
      incr count;
      Printf.printf "LLM call #%d\n" !count;
      None);
    on_after_llm = None;
    on_before_tool = None;
    on_after_tool = None;
    on_error = None;
  }
```

### 错误处理中间件示例

将特定错误转换为可重试的替代结果：

```ocaml
let fallback_middleware ~fallback_text () =
  {
    Types.name = "fallback";
    on_before_llm = None;
    on_after_llm = None;
    on_before_tool = None;
    on_after_tool = None;
    on_error = Some (fun err ->
      match err with
      | Types.External_failure _ ->
        (* 将外部失败转换为带有兜底文本的成功结果 *)
        Some (Types.Success (`String fallback_text))
      | _ -> None  (* 其他错误透传 *)
    );
  }
```

### 注意事项

- 中间件实例在同一 Agent 配置中共享，注意并发状态隔离
- `on_error` 目前是 Engine 层的死代码（Engine 未调用 `apply_on_error`），
  未来版本将接入
- 返回 `Some` 表示修改/替换值，`None` 表示透传原始值

## See also

- [Overview](overview.md) -- SDK 架构概览
- [Agent API](agent.md) -- agent_config.middleware 字段说明
- [Workflow API](workflow.md) -- 工作流中的中间件传播
