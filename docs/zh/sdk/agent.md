# Agent API 参考
[English](../sdk/agent.md) · **简体中文**

本文档描述 P-A-R SDK 的 Agent 配置、运行时管理和工具注册 API。

## 运行时配置

### runtime_config

运行时通过 `Par.Runtime.create` 创建，需要以下配置：

```ocaml
type runtime_config = {
  persistence : [ `Sqlite of string ];
  event_bus : event_bus_config;
  default_quota : resource_quota;
  shutdown : shutdown_config;
  llm_providers : (string * llm_provider_config) list;
  eval_limits : eval_limits;
  parallel_tool_execution : bool;
  bash_confirm : bash_confirm_config;
  event_retention_seconds : float;
}
```

`Par.Runtime` 提供三个默认配置值，可以直接使用：

```ocaml
Runtime.default_event_bus_config   (* buffer_capacity=10000, DLQ 开启 *)
Runtime.default_quota             (* max_concurrent_tasks=10 *)
Runtime.default_shutdown_config   (* drain_timeout=30s *)
```

### 创建运行时

```ocaml
val Runtime.create :
  ?persistence:persistence_service ->
  ?event_bus:Types.event_bus_service ->
  ?llm:llm_service ->
  ?embeddings:embedding_service ->
  ?memory:memory_service ->
  ?bash_policy:(module Bash_policy.POLICY) ->
  ?workspace:Workspace.workspace ->
  ?mcp_servers:Mcp_types.server_config list ->
  ?mcp_process_mgr:_ Eio.Process.mgr ->
  ?mcp_net:_ Eio.Net.t ->
  ?mcp_clock:_ Eio.Time.clock ->
  ?mcp_startup_policy:Mcp_types.startup_policy ->
  config:runtime_config ->
  Eio.Switch.t ->
  (runtime, error_category) result
```

所有可选参数默认为 `None`。关键可选参数：

| 参数 | 说明 |
|------|------|
| `?persistence` | 持久化后端（如 `Sqlite` 或 `Noop`）。 |
| `?event_bus` | 自定义事件总线配置。 |
| `?llm` | 主 LLM 服务 provider。 |
| `?embeddings` | 嵌入服务，用于 RAG 管道。见 [RAG API](rag.md)。 |
| `?memory` | 内存服务，用于跨会话 agent 记忆（FTS5）。见 [Memory API](memory.md)。 |
| `?bash_policy` | Bash 信任边界策略模块。默认：`Always`（允许所有）。 |
| `?workspace` | 文件系统沙箱的 Workspace。默认为 CWD。 |
| `?mcp_servers` | 创建时启动的 MCP 服务器配置。 |
| `?mcp_process_mgr` | MCP stdio 服务器的 Eio 进程管理器。 |
| `?mcp_net` | MCP HTTP/SSE 服务器的 Eio 网络能力。 |
| `?mcp_clock` | MCP 启动超时的 Eio 时钟。 |
| `?mcp_startup_policy` | MCP 服务器启动策略（阻塞 vs 延迟）。 |

完整示例：

```ocaml
open Par

let config = {
  persistence = `Sqlite "par.db";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
  parallel_tool_execution = true;
  bash_confirm = Runtime.default_bash_confirm;
  event_retention_seconds = 604800.0;
}

let () = Eio_main.run (fun _env ->
  Eio.Switch.run (fun switch ->
    match Runtime.create ~config switch with
    | Error _ -> Printf.eprintf "Runtime creation failed\n"
    | Ok rt ->
      (* ... 使用运行时 ... *)
      let exit_code = Runtime.close rt in
      exit exit_code
  )
)
```

## Agent 配置

### agent_config

```ocaml
type agent_config = {
  id : string;                            (* Agent 唯一标识 *)
  system_prompt : string;                 (* 系统提示词 *)
  system_prompt_template : system_prompt_template option;  (* 可选模板化提示词（带变量）*)
  model : model_config;                   (* LLM 模型配置 *)
  tools : tool_descriptor list;           (* 可用工具列表 *)
  max_iterations : int;                   (* ReAct 循环最大迭代次数 *)
  middleware : middleware_hook list;       (* 中间件管道 *)
  retry_policy : retry_policy option;     (* 可选重试策略 *)
  context_strategy : context_strategy option;  (* 上下文窗口管理策略 *)
  resource_quota : resource_quota option;  (* 可选资源配额覆盖 *)
  max_execution_time : float option;      (* 可选最大执行时间（秒）*)
  early_stopping_method : early_stopping_method;  (* 达到迭代上限时：Force 或 Generate *)
  on_max_tokens : on_max_tokens_behavior option;  (* None=Auto（默认），或显式 Retry/Continue/Return_partial *)
  max_continuation_chunks : int option;           (* None=Auto（默认），或显式上限 *)
  tool_timeout : float option;            (* 可选单次工具调用超时（秒）*)
  context_compression_threshold : float option;   (* v0.6.3+：按比例自动压缩。None=手动模式，Some 0.8=默认 *)
  compression_cooldown_messages : int option;     (* v0.6.3+：两次自动压缩间最小迭代数。Some 6=默认 *)
  context_window_override : int option;           (* v0.6.3+：覆盖 context window 大小；None=用 provider capability 或静态表 *)
}
```

### 自动上下文压缩（v0.6.3+）

当 `context_compression_threshold` 设置时（默认 `Some 0.8`），引擎在每次 LLM 调用前检查
`估算 tokens / context window` 比例。如果超过阈值且冷却已过，应用配置的 `context_strategy`
（或 `context_strategy = None` 时默认用 `Summarize`）。

Context window 大小通过三层 resolver 解析：
1. `context_window_override`（用户 supplied，优先级最高）
2. `llm_service.context_window_fn`（provider capability 函数）
3. 静态查表（`default_context_window`）：gpt-4o 系列=128K，claude-4 系列=200K，gpt-3.5-turbo=16385，未知=8000（保守默认）

两个可观测事件：
- `Context_compressed { trigger; tokens_before; tokens_after; messages_before; messages_after; strategy_used; elapsed_ms }` 压缩成功时
- `Context_compression_skipped { reason }` 跳过时，带类型化 reason：`` `Below_threshold of float ``、`` `Cooldown_active of int ``、`` `No_window_size ``、`` `No_strategy ``

**默认值变更（0.x 中的 BREAKING）**：`make_agent` 默认 `context_strategy` 从
`Sliding_window { max_messages=100; max_tokens=200000 }` 改为 `Summarize { max_tokens=8000; summary_model=None }`。
业界调研确认所有主流生产 agent 框架的默认值都是 LLM-summarize（Letta、Anthropic、LangChain、CrewAI），
零个用 truncate-drop。要恢复 v0.6.3 前的行为，显式设置 `context_strategy = Some (Sliding_window {...})`。

### model_config

```ocaml
type model_config = {
  provider : [ `Openai | `Anthropic | `Ollama | `Custom of string ];
  model_name : string;
  api_base : string option;          (* 自定义 API 端点 *)
  temperature : float;
  max_tokens : int option;
  top_p : float option;
  stop_sequences : string list option;
}
```

Provider 示例：

```ocaml
(* OpenAI *)
{ provider = `Openai; model_name = "gpt-4"; api_base = None;
  temperature = 0.7; max_tokens = Some 4096; top_p = None;
  stop_sequences = None }

(* 通过 ZhipuAI 中转调用 Anthropic *)
{ provider = `Anthropic; model_name = "claude-sonnet-4-20250514";
  api_base = Some "https://open.bigmodel.cn/api/paas/v4";
  temperature = 0.5; max_tokens = None; top_p = None;
  stop_sequences = None }

(* Ollama 本地模型 *)
{ provider = `Ollama; model_name = "llama3"; api_base = None;
  temperature = 0.8; max_tokens = None; top_p = None;
  stop_sequences = None }

(* 自定义端点 *)
{ provider = `Custom "my-provider"; model_name = "my-model";
  api_base = Some "http://localhost:8000/v1";
  temperature = 0.7; max_tokens = None; top_p = None;
  stop_sequences = None }
```

### LLM Provider 配置

Provider 实例通过 `llm_provider_config` 创建，传递给 `Runtime.create` 的 `llm` 参数：

```ocaml
type llm_provider_config =
  | Openai of { api_key : string; base_url : string option;
                organization : string option }
  | Anthropic of { api_key : string; base_url : string option }
  | Ollama of { base_url : string }
  | Custom of { base_url : string; headers : (string * string) list;
                request_format : [ `Openai_compatible | `Anthropic_compatible ] }
```

## 运行时操作

### 注册 Agent

```ocaml
val Runtime.register_agent : runtime -> agent_config -> (unit, error_category) result
```

```ocaml
let agent = {
  Types.id = "my-agent";
  system_prompt = "You are a helpful assistant.";
  model = { provider = `Openai; model_name = "gpt-4"; api_base = None;
            temperature = 0.7; max_tokens = None; top_p = None;
            stop_sequences = None };
  tools = [ tool.descriptor ];   (* 来自 Runtime.register_tool *)
  max_iterations = 5;
  middleware = [];
  retry_policy = None;
  context_strategy = None;
  resource_quota = None;
  max_execution_time = None;
  early_stopping_method = Types.Force;
  on_max_tokens = None;              (* Auto：Return_partial（此 agent 有工具）*)
  max_continuation_chunks = None;    (* Auto：3（有工具 agent 的默认值）*)
  tool_timeout = None;
} in
ignore (Runtime.register_agent rt agent)
```

### 调用 Agent

```ocaml
val Runtime.invoke :
  runtime ->
  agent_id:string ->
  message:string ->
  ?workspace:Workspace.workspace ->
  ?cancellation_token:cancellation_token ->
  ?conversation:conversation ->
  ?on_tool_event:(event -> unit) ->
  ?on_chunk:(llm_response_chunk -> unit) option ->
  ?enable_handoff:bool ->
  ?system_prompt_appendix:string ->
  ?context:Invoke_context.invoke_context ->
  unit ->
  (invoke_result, error_category * conversation) result
```

所有可选参数：

| 参数 | 类型 | 说明 |
|------|------|------|
| `?workspace` | `Workspace.workspace` | 单次调用 workspace 覆盖。工具使用此 workspace 而非运行时默认值。 |
| `?cancellation_token` | `cancellation_token` | 协作取消令牌。见下方「取消令牌」章节。 |
| `?conversation` | `conversation option` | 恢复的对话历史。传 `None` 开始新对话。 |
| `?on_tool_event` | `event -> unit` | 工具相关事件回调（tool_call_sent、tool_result_received 等）。 |
| `?on_chunk` | `(llm_response_chunk -> unit) option` | LLM 响应块的流式回调。`None` 禁用流式。 |
| `?enable_handoff` | `bool` | 启用 agent 间交接（handoff）工具。默认：`false`。 |
| `?system_prompt_appendix` | `string` | 仅本次调用追加到 system prompt 的文本。见 [invoke_context](invoke_context.md)。 |
| `?context` | `Invoke_context.invoke_context` | 预构建的单次调用隔离上下文。提供时使用此上下文而非创建新的。见 [invoke_context](invoke_context.md)。 |

返回类型为 `invoke_result`（不是 `llm_response`）：

```ocaml
type invoke_result = {
  response : llm_response;
  conversation : conversation;
}
```

错误元组中的 `conversation` 字段携带失败时的对话状态，支持错误恢复或部分结果提取。

```ocaml
match Runtime.invoke rt ~agent_id:"my-agent" ~message:"Hello!" () with
| Ok result ->
  let resp = result.response in
  (match resp.text with Some text -> Printf.printf "Response: %s\n" text
  | None -> Printf.printf "No text response\n")
| Error (err, _conv) ->
  Printf.eprintf "Error: %s\n"
    (Types.error_category_to_yojson err |> Yojson.Safe.to_string)
```

### 流式示例

```ocaml
Runtime.invoke rt ~agent_id:"my-agent" ~message:"Tell me a story"
  ~on_chunk:(fun chunk ->
    Printf.printf "%s%!" chunk.text)
  ()
```

### 异步调用

`Runtime.invoke_async` 在后台 fiber 中运行调用，立即返回一个 `invoke_handle`，可用于等待、取消或轮询结果。完整详情见 [invoke_context](invoke_context.md)。

```ocaml
val Runtime.invoke_async :
  runtime ->
  agent_id:string ->
  message:string ->
  ?workspace:Workspace.workspace ->
  ?cancellation_token:cancellation_token ->
  ?conversation:conversation ->
  ?on_tool_event:(event -> unit) ->
  ?on_chunk:(llm_response_chunk -> unit) option ->
  ?enable_handoff:bool ->
  ?system_prompt_appendix:string ->
  ?context:Invoke_context.invoke_context ->
  unit ->
  Invoke_context.invoke_handle
```

Handle 函数：

```ocaml
val Invoke_context.invoke_handle_await :
  invoke_handle ->
  (invoke_result, error_category * conversation) result

val Invoke_context.invoke_handle_cancel : invoke_handle -> unit
val Invoke_context.invoke_handle_status : invoke_handle -> invoke_status
```

```ocaml
let handle = Runtime.invoke_async rt ~agent_id:"researcher"
  ~message:"Find recent papers on OCaml effects" () in
(* 在 agent 后台运行时做其他事情 ... *)
match Invoke_context.invoke_handle_await handle with
| Ok result ->
  Printf.printf "Done: %s\n" (result.response.text |> Option.value ~default:"")
| Error (err, _) ->
  Printf.eprintf "Failed: %s\n"
    (Types.error_category_to_yojson err |> Yojson.Safe.to_string)
```

### 关闭运行时

```ocaml
val Runtime.close : runtime -> int   (* 返回退出码 *)
```

## 工具注册

### tool_descriptor

```ocaml
type tool_descriptor = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;     (* JSON Schema 格式 *)
  permission : tool_permission;     (* 默认 Allow *)
  timeout : float option;
  concurrency_limit : int option;
}
```

### handler 函数签名

工具 handler 接收 JSON 输入和取消令牌，返回 `handler_result`：

```ocaml
type handler_fn = Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result

type handler_result =
  | Success of Yojson.Safe.t
  | Error of {
      category : error_category;
      message : string;
      retryable : bool;
      metadata : (string * Yojson.Safe.t) list;
    }
```

### Runtime.register_tool

```ocaml
val Runtime.register_tool :
  runtime ->
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  handler:handler_fn ->
  ?permission:tool_permission ->
  ?timeout:float ->
  ?concurrency_limit:int ->
  unit ->
  tool_binding    (* 返回 descriptor + handler *)
```

`tool_binding` 包含 `descriptor`（用于 `agent_config.tools`）和 `handler`（已自动注册到 registry）：

```ocaml
type tool_binding = {
  descriptor : tool_descriptor;
  handler : Yojson.Safe.t -> cancellation_token -> handler_result;
}
```

### 工具注册示例

```ocaml
(* 定义一个计算器工具 *)
let calc_tool = Runtime.register_tool rt
  ~name:"calculator"
  ~description:"Evaluate a math expression"
  ~input_schema:(`Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("expression", `Assoc [
        ("type", `String "string");
        ("description", `String "The math expression to evaluate");
      ])
    ]);
    ("required", `List [`String "expression"]);
  ])
  ~handler:(fun input token ->
    match input with
    | `Assoc fields ->
      (match List.assoc_opt "expression" fields with
       | Some (`String expr) ->
         (try
           let result = float_of_string expr in
           Types.Success (`Float result)
         with _ ->
           Types.Error {
             category = Types.Invalid_input "Invalid expression";
             message = "Could not parse expression";
             retryable = false;
             metadata = [];
           })
       | _ -> Types.Error {
           category = Types.Invalid_input "Missing expression";
           message = "Expression field is required";
           retryable = false;
           metadata = [];
         })
    | _ -> Types.Error {
        category = Types.Invalid_input "Invalid input";
        message = "Input must be a JSON object";
        retryable = false;
        metadata = [];
      })
  ()
```

## ReAct 循环

Agent 执行核心是 `Par.Engine.run_agent`：

1. 构建对话（System prompt + User message）
2. 应用 `context_strategy`（如已配置）管理上下文窗口
3. 通过中间件链发送 `on_before_llm` 钩子
4. 调用 LLM Provider 获取响应
5. 通过中间件链发送 `on_after_llm` 钩子
6. 若响应包含 tool_calls，依次执行每个工具：
   - 查找工具 descriptor
   - 从 Tool_registry 解析 handler
   - 执行工具（经过 `on_before_tool` / `on_after_tool` 钩子）
   - 将工具结果追加到对话
7. 递归调用直到 `finish_reason` 为 `Stop` 或达到 `max_iterations`

### max_iterations 行为

当迭代次数达到 `max_iterations` 时，`run_agent` 返回：
`Result.Error (Internal "Max iterations exceeded")`

### on_max_tokens 行为

**v0.6.x 行为变更**:自 v0.6.x 起,`on_max_tokens` 改为 option 类型。`None`(新默认值)表示 Auto —— 运行时根据 effective tool 集解析策略:无工具 agent 自动选 `Continue`(长输出生成模式),有工具 agent 选 `Return_partial`(向后兼容默认值)。显式 `Some Return_partial` / `Some Retry` / `Some Continue` 总是覆盖 Auto。`max_continuation_chunks` 同样遵循 Auto 逻辑:`None` 表示无工具 agent 无上限,有工具 agent 上限为 3。

当 LLM 返回 `finish_reason=Max_tokens`（截断响应）时，行为取决于 `agent.on_max_tokens`：

- `Return_partial`（默认）：若截断响应包含非空文本，保留并返回 `Ok` 及部分结果。空截断保留错误/重试行为。
- `Retry`：保留截断消息作为上下文，重新进入 ReAct 循环（受 `max_iterations` 约束）。
- `Continue`：注入"从上次中断处继续"的跟进消息，拼接续写块直到 `finish_reason=Stop`。受 `max_continuation_chunks`（默认 3）限制。递减收益保护：若续写块新增少于 500 字符则停止。

每次截断都会发出 `Llm_response_truncated` 事件用于可观测性。

## System Prompt 设计建议

- 明确指定 Agent 的角色和能力边界
- 列出可用工具的用途和使用场景
- 指定输出格式要求（JSON、纯文本等）
- 对需要多步推理的任务，提示 Agent 逐步思考

```ocaml
system_prompt = {|
  You are a data analysis assistant. You have access to a calculator tool.
  When asked to compute something:
  1. Identify the mathematical expression
  2. Use the calculator tool
  3. Present the result clearly

  Always show your reasoning step by step.
|}
```

## 取消令牌

```ocaml
val Cancellation.create_token : Eio.Switch.t -> cancellation_token
val Cancellation.request_cancel : cancellation_token -> unit
val Cancellation.check_cancel : cancellation_token -> unit
  (* 抛出 Eio.Cancel.Cancelled 若已取消 *)
val Cancellation.with_timeout : float -> cancellation_token ->
  (cancellation_token -> 'a) -> ('a, [ `Cancelled | `Timeout ]) result
```

```ocaml
let token = Cancellation.create_token switch in
(* 在另一个 fiber 中可以取消 *)
Cancellation.request_cancel token
```

## See also

- [Overview](overview.md) -- SDK 架构概览
- [invoke_context](invoke_context.md) -- 单次调用隔离、`invoke_async`、动态 system prompt
- [Workflow API](workflow.md) -- 工作流编排
- [Middleware API](middleware.md) -- 中间件管道
- [Memory API](memory.md) -- 跨会话 agent 记忆，FTS5 搜索
- [MCP client](mcp.md) -- `Runtime.mcp_server` 生命周期、`call_tool`、`read_resource`、`get_prompt`
- [examples/basic_agent.ml](../../../examples/basic_agent.ml) -- 完整可运行示例
