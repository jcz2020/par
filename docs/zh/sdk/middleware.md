# Middleware API 参考
[English](https://github.com/jcz2020/par/blob/main/sdk/middleware.md) · **简体中文**

本文档描述 P-A-R SDK 的中间件管道，包括 9 个内置中间件（含 v0.8.2 新增 Think_tag_strip）和自定义中间件编写指南。

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
  on_error : (conversation -> error_category -> handler_result option) option;
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

## Output_validation

JSON 输入/输出校验中间件，确保 LLM 响应和工具参数格式正确。

```ocaml
val Output_validation.validation :
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
let validation_hook = Output_validation.validation ()

(* 生产环境用严格模式 *)
let validation_hook = Output_validation.validation ~strict:true ()
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

## Think_tag_strip

剥离 LLM 响应中的 `<think>` 和 `<reasoning>` 标签。推理模型（DeepSeek R1、QwQ）将思维链嵌入这些标签；此中间件可防止它们污染对话历史和用户可见输出。

可选启用 -- 仅影响包含此中间件的 Agent：

```ocaml
let agent = Runtime.make_agent
  ~id:"my-agent"
  ~middleware:[Think_tag_strip.create ()]
  ~model ~tools:[] ()
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
    Output_validation.validation ~strict:true ();     (* 严格校验 *)
    Sanitize_tool_output.sanitize_tool_output ();  (* 输出清洗 *)
    Think_tag_strip.create ();                 (* 可选：清洗 reasoning 模型的 <think>/<reasoning> 标签 *)
  ];
}
```

执行流程：请求 -> Logging -> Pii_mask -> Rate_limit -> Output_validation -> LLM
响应 -> Output_validation -> Sanitize -> Retry -> Rate_limit -> Pii_mask -> Logging

## Cancellation（取消）

上文的 `Timeout` 中间件只是在事后把超时错误归一化。真正的截止时间（deadline）由 cancellation token 实现，它是运行时范围内"立即停止工作"的基础原语。中间件钩子并不直接接收 cancellation token，但每个工具处理器都会收到一个，任何驱动 Engine 的代码都可以在自己创建的 token 上请求取消。

### Cancellation 接口

```ocaml
type cancellation_token

val Cancellation.create_token : Eio.Switch.t -> cancellation_token
val Cancellation.is_cancelled : cancellation_token -> bool
val Cancellation.check_cancel  : cancellation_token -> unit
val Cancellation.request_cancel : cancellation_token -> unit

val Cancellation.with_timeout :
  float ->
  cancellation_token ->
  (cancellation_token -> 'a) ->
  ('a, [> `Timeout | `Cancelled ]) result

val Cancellation.cancellable_handler :
  cancellation_token ->
  float ->
  (Yojson.Safe.t -> Types.handler_result) ->
  (Yojson.Safe.t -> Types.handler_result)
```

token 创建于某个 `Eio.Switch.t` 之上。该 switch 拥有 token 的生命周期：当 switch 退出时，token 会随其上运行的所有 fiber 一起被取消。退出作用域时无需显式调用 `request_cancel` 来清理。

`is_cancelled` 是非抛出式探测。当你只想检查标志位但暂不抛出时使用。`check_cancel` 是抛出式探测：若 token 已被取消则立即抛出 `Eio.Cancel.Cancelled`。长时间运行的代码应在自然边界处（循环迭代之间、批处理项之间）调用 `check_cancel`，使取消请求能及时传播，而不是等到下一次阻塞调用。

`request_cancel` 是另一个 fiber 请求停止工作的方式。它会设置标志位；被取消的 fiber 在下次遇到 `check_cancel`、cancel-aware 的 Eio 操作或 `with_timeout` 边界时观察到该标志。

### Timeout vs Cancellation

`with_timeout` 将一个 deadline 与现有 token 组合。它返回函数的值、`` `Timeout ``（deadline 先到）或`` `Cancelled ``（在 deadline 之前有人对底层 token 调用了 `request_cancel`）。这两种情况是分开的，因为它们对应不同的响应方式：超时通常意味着"用更长的预算或更小的任务重试"，而取消通常意味着"调用方放弃了，完全停止"。

```ocaml
match Cancellation.with_timeout 30.0 token (fun token ->
  Engine.run_agent token agent message llm registry)
with
| Ok result -> (* 继续 *)
| Error `Timeout -> (* 重试或上抛 *)
| Error `Cancelled -> (* 传播，不要重试 *)
```

只有当内部函数在某个时刻观察到 cancellation 时，deadline 才会触发。从不 yield 的纯 CPU 工作会跑过 deadline。PAR 的 Engine 和工具处理器在 LLM 往返之间以及工具分派之前都会检查 cancellation，因此 Agent 调用是 deadline-aware 的。

### 中间件如何与 Cancellation 交互

中间件钩子收到的是 conversation、response、tool call 或 error，但不包含 token。token 在底层流动：Engine 通过 `run_agent` 把它穿起来，每个工具处理器把它作为第二个参数接收。一个中间件如果想在它观察到的某个信号上中止执行，有两个选择：

1. 从相关钩子返回 `None`，让 Engine 继续执行。中间件无法强制 Engine 停止，但可以短路自己的贡献。
2. 修改共享状态，下一个 `check_cancel` 边界会观察到。这会把中间件与处理器的 cancellation 纪律耦合起来，因此在可行时优先使用第一种方式。

`cancellable_handler` 包装器是让工具处理器变为 cancellation-aware 的标准方式，无需重写其函数体。传入 token 和每次调用的超时，包装器会确保 `check_cancel` 在处理器的各步骤之间触发。

```ocaml
let handler input token =
  let wrapped = Cancellation.cancellable_handler token 10.0 real_handler in
  wrapped input
```

这里 `real_handler` 不接收 token。包装器为每次调用设置 10 秒预算，若 token 被取消或预算耗尽则中止并返回 `Error`。适用于包装难以穿过 token 的第三方函数。

### 与 Eio 组合

Cancellation 依托于 Eio 的结构化并发。在某个 switch 上创建的 token 会在该 switch 退出时被取消，因此常见的清理模式是"在 `Eio.Switch.run` 内运行 Agent；如果出错，退出 switch 即可拆掉 Agent 的所有 fiber"。极少需要为清理显式调用 `request_cancel`；它主要用于用户发起的取消（一个"停止"按钮、一个 SIGINT 处理器），此时 switch 并未以其他方式退出。

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
    on_error = Some (fun conv err ->
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
- `on_error` 在 Engine 层被调用（位于 `lib/core/engine.ml:787` 的 `apply_on_error` 中），当工具返回 `Error` 时触发。此钩子可用于重试/自定义错误处理中间件。注意：`conversation` 是失败发生时的实时对话快照
- 返回 `Some` 表示修改/替换值，`None` 表示透传原始值

## 另请参阅

- [Overview](overview.md) -- SDK 架构概览
- [Agent API](agent.md) -- agent_config.middleware 字段说明
- [Workflow API](workflow.md) -- 工作流中的中间件传播
