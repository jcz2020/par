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
  system_prompt : system_prompt;          (* 类型化记录：{ sp_raw : string; sp_zone : zone_tag } *)
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
  cache_strategy : cache_strategy;        (* 提示词缓存策略：No_caching | With_cache_of of cache_ttl *)
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
                organization : string option;
                embedding_model : string option;
                prompt_cache_key : string option }
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
  system_prompt = Types.stable_prompt "You are a helpful assistant.";
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

### 结构化输出

`Runtime.invoke_structured` 返回通过 schema 校验的 JSON，而非自由文本。函数签名：

```ocaml
val Runtime.invoke_structured :
  runtime ->
  agent_id:string ->
  message:string ->
  response_schema:Yojson.Safe.t ->
  ?max_repair_attempts:int ->
  ?cancellation_token:cancellation_token ->
  ?conversation:conversation ->
  ?system_prompt_appendix:string ->
  ?on_tool_event:(event -> unit) ->
  ?on_repair_attempt:(int -> error_category -> conversation -> unit) ->
  unit ->
  (structured_invoke_result, error_category * conversation) result
```

返回类型 `structured_invoke_result` 携带校验后的 JSON、原始 LLM 响应、完整对话历史和 repair-loop 重试次数：

```ocaml
type structured_invoke_result = {
  value : Yojson.Safe.t;          (* 通过 schema 校验的 JSON *)
  raw_response : llm_response;   (* 原始 LLM 响应（调试 / token 核算） *)
  conversation : conversation;   (* 包含所有 repair 轮的完整对话历史 *)
  attempts : int;                (* 1 = 一次性成功；>1 = repair-loop 触发 *)
}
```

当 `Json_extract.extract_json_from_text` 无法从 LLM 文本解析出有效 JSON，或解析后的 JSON 无法通过 `Validation.validate_tool_input_result` 的 schema 校验时，repair loop 会触发。最多重试 `max_repair_attempts`（默认 3）次，每次都会在对话中追加 user-feedback 消息。每次迭代顶部的 cancellation token 检查防止无限制的 LLM 调用。

**工具执行 + 结构化输出（v0.7.4+）**：当 agent 注册了工具且你需要校验后的 JSON 时，runtime 会自动路由到 `Engine.run_agent_structured` —— 一种两阶段模式：

1. **阶段一**：完整 ReAct 循环运行 agent 与工具（bash、http、自定义）交互，直到 LLM 产出最终文本响应。
2. **阶段二**：完整对话历史（包括所有工具调用结果）传给一个独立的结构化 LLM 调用，提取并对照 `response_schema` 校验 JSON。

此模式对齐 LangGraph 的 `create_react_agent(response_format=)` 方案。它能跨所有 LLM provider（OpenAI、Anthropic、Ollama、自定义）工作，不依赖 provider 原生支持同时传 `tools + response_format`（在非 OpenAI provider 上不可靠 —— 见 CrewAI issue #5472）。

**原生结构化输出（v0.7.5+）**：OpenAI 和 Anthropic provider 现在使用原生结构化输出模式，而非之前的文本注入回退。OpenAI 发送 `response_format: {type: json_schema, json_schema: {name, schema, strict: true}}` 以实现严格的 JSON schema 校验。Anthropic 发送 `output_config: {format: {type: json_schema, schema}}`。Ollama 和 Custom provider 继续使用文本注入回退（基于 prompt 的 JSON 提取 + schema 校验），因为它们可能不支持严格的 JSON schema 模式。

```ocaml
match Runtime.invoke_structured rt
    ~agent_id:"env-detector"
    ~message:"检查项目并报告运行时环境"
    ~response_schema:(`Assoc [
      ("language", `String "OCaml");
      ("ocaml_version", `String "5.x.x");
      ("dune_version", `String "3.x.x");
    ]) () with
| Ok { value; _ } -> Yojson.Safe.to_string value
| Error (err, _conv) -> Printf.eprintf "Error: %s" (Types.error_category_to_string err)
```

如果 agent 没有工具（`config.tools = []`），`invoke_structured` 直接走轻量级 `run_structured` 路径 —— 无 ReAct 循环，单次 LLM 调用。设置 `?on_tool_event` 可在 ReAct 阶段观察工具调用。

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
  output_schema : Yojson.Safe.t option;  (* 可选的工具输出 JSON Schema *)
  permission : tool_permission;     (* 默认 Allow *)
  timeout : float option;
  concurrency_limit : int option;
  on_update : (string -> unit) option;  (* 可选的进度回调 *)
  cache_control : cache_control option;  (* 可选的提示词缓存断点 *)
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
  | Handoff of {
      target_agent_id : string;
      carry_context : bool;
      task : string option;
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
  ?output_schema:Yojson.Safe.t ->
  ?permission:tool_permission ->
  ?timeout:float ->
  ?concurrency_limit:int ->
  ?on_update:(string -> unit) option ->
  ?cache_control:cache_control option ->
  unit ->
  (tool_binding, error_category) result
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

## System Prompt 模板

当系统提示词需要在每次调用时变化（注入 agent id、运行时 id、可用工具列表或用户提供的变量），可以使用 `system_prompt_template` 代替普通 `system_prompt`。作为 `agent_config.system_prompt_template` 字段添加，它提供 mustache 风格的 `{{variable}}` 替换，无需引入额外的模板依赖。

### 模板类型

```ocaml
type system_prompt_template = {
  template : string;        (* 带 {{var}} 占位符的正文 *)
  variables : string list;  (* 模板可能使用的所有占位符名 *)
  required : string list;   (* 必须提供的 `variables` 子集 *)
}
```

`variables` 是渲染器识别的所有变量名集合。`required` 是渲染时必须存在的子集；缺少 required 变量会返回 `Error` 而非静默替换为空字符串。将两个列表分开让模板可以声明可选的辅助变量（用户的 locale、session 标签）和硬性要求（agent id）。

### render_context

渲染器从 `render_context` 记录中提取值。运行时内部构建它；如果你手动调用 `Template.render`，则需要自己构造。

```ocaml
type render_context = {
  agent_id : string;
  runtime_id : string;
  user_variables : (string * Yojson.Safe.t) list;
  available_tools : string list;
}
```

`agent_id` 和 `runtime_id` 始终可用。`available_tools` 是 agent 上注册的工具名列表。`user_variables` 是调用方提供的值。渲染器在解析 `{{name}}` 时查阅这四个字段。

### 渲染

```ocaml
val Template.render :
  template:string ->
  variables:(string * Yojson.Safe.t) list ->
  required:string list ->
  context:render_context ->
  (string, Types.error_category) result

val Template.effective_system_prompt :
  Types.agent_config ->
  runtime_id:string ->
  (string, Types.error_category) result
```

`Template.render` 是低级入口。`effective_system_prompt` 是便捷包装：传入 `agent_config` 和 `runtime_id`，返回引擎将发送给 LLM 的最终字符串。如果 `system_prompt_template` 为 `None`，则回退到普通 `system_prompt` 字段，所以现有 agent 无需改动即可继续工作。

### 何时使用模板

当以下任一条件满足时使用模板：

- 提示词需要引用 agent id 或运行时 id，且你不想手动插值。
- 提示词需要每次调用时的变量（用户 locale、session 元数据、动态示例），由调用方提供。
- 你希望渲染器在启动时强制检查 required 变量，而非在对话中途才发现缺失值。

当文本是静态的时，使用普通 `system_prompt`。`variables` 为空列表的模板没有收益，只会增加渲染步骤。

### 示例

```ocaml
let agent = {
  Types.id = "support";
  system_prompt = Types.stable_prompt "You are a helpful assistant.";   (* 回退值 *)
  system_prompt_template = Some {
    template = {|
      You are {{role}}, assisting agent {{agent_id}} on runtime {{runtime_id}}.
      Available tools: {{available_tools}}.
      User context: {{user_locale}}.
    |};
    variables = ["role"; "agent_id"; "runtime_id";
                 "available_tools"; "user_locale"];
    required = ["role"; "user_locale"];
  };
  model = (* ... *);
  tools = [];
  max_iterations = 5;
  middleware = [];
  retry_policy = None;
  context_strategy = None;
  resource_quota = None;
  max_execution_time = None;
  early_stopping_method = Types.Force;
  on_max_tokens = None;              (* Auto：Continue（此 agent 无工具）*)
  max_continuation_chunks = None;    (* Auto：无上限（无工具长输出模式）*)
  tool_timeout = None;
}
```

在调用时，渲染器从运行时替换 `agent_id`、`runtime_id` 和 `available_tools`，从每次调用的 `user_variables` 中提取 `role` 和 `user_locale`。因为两者都是 `required`，忘记 `user_locale` 的调用方会在第一次 LLM 往返之前收到 `Error`，而不是一个乱码的提示词。

## 上下文策略

长时间对话会超出模型的上下文窗口。`agent_config.context_strategy` 字段决定 PAR 在每次 LLM 调用前如何裁剪对话。保持为 `None` 时运行时应用默认值；显式设置可覆盖。

### 策略变体

```ocaml
type context_strategy =
  | Truncate_oldest of { keep_system : bool; min_messages : int }
  | Summarize of { max_tokens : int; summary_model : model_config option }
  | Sliding_window of { max_messages : int; max_tokens : int }
```

`Truncate_oldest` 丢弃最旧的非系统消息直到对话适合。`keep_system`（默认 true）将系统消息固定在前面；`min_messages` 是下限，即使 token 估算超预算也不会丢弃更多消息。当近期对话轮次携带主要信号、旧轮次是噪声时使用此策略。

`Summarize` 使用第二次 LLM 调用将早期轮次压缩为摘要消息。`max_tokens` 限定摘要长度。`summary_model` 可选地将摘要调用路由到比 agent 主模型更便宜或更快的模型；`None` 复用 agent 自身的 `model_config`。当早期上下文确实重要但 token 预算紧张时选择此策略，代价是每次摘要多一次 LLM 往返。

`Sliding_window` 保留最近的 `max_messages` 条消息，丢弃所有更旧的内容，受 `max_tokens` 上限约束。它是最便宜的策略，因为从不调用其他模型，并且逐字保留对话尾部。v0.6.3 之前这是默认值；从 v0.6.3 开始默认是 `Summarize`（见上方"自动上下文压缩"）。

### 引擎如何应用策略

每次 LLM 往返前，引擎在当前对话上调用 `Context_manager.apply_strategy`。函数返回（可能缩减的）对话，或在策略无法满足约束时返回 `Error`（例如 `Truncate_oldest` 达到 `min_messages` 但仍超 `max_tokens`）。

```ocaml
val Context_manager.apply_strategy :
  Types.context_strategy -> Types.conversation ->
  Types.llm_service option ->
  on_event:(Types.event -> unit) option ->
  (Types.conversation, Types.error_category) result

val Context_manager.estimate_tokens : Types.conversation -> int
```

`estimate_tokens` 是粗略的字符数除以四的启发式方法。它不是分词器。在推理预算时将数字视为参考值。

### v0.5.1 默认值

从 v0.5.1 开始，没有显式 `context_strategy` 的运行时获得：

```ocaml
Some (Sliding_window { max_messages = 100; max_tokens = 200000 })
```

这是对早期 beta 版本的刻意变更，之前策略未设置让对话无限增长直到 provider 拒绝。200K token 上限匹配当前最大的生产模型，100 条消息上限防止对话在单条消息很短时依然膨胀。如果你之前依赖无限增长（例如在运行时外部自行摘要），显式设置 `context_strategy = None` 可恢复旧行为。

对于使用较小窗口的模型，同时降低两个数字。4K token 模型配合 `max_messages = 100` 仍会触发 provider 限制，因为 `max_messages` 在 token 估算之前检查。

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
