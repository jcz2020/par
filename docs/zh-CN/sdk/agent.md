# Agent API 参考
[English](../sdk/agent.md) · **简体中文**

本文档描述 P-A-R SDK 的 Agent 配置、运行时管理和工具注册 API。

## 运行时配置

### runtime_config

运行时通过 `Par.Runtime.create` 创建，需要以下配置：

```ocaml
type runtime_config = {
  persistence : [ `Sqlite of string | `Postgresql of string ];
  event_bus : event_bus_config;
  default_quota : resource_quota;
  shutdown : shutdown_config;
  llm_providers : (string * llm_provider_config) list;
  eval_limits : eval_limits;
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
  ?persistence:Types.persistence_service ->
  ?event_bus:(module Types.EVENT_BUS_SERVICE) ->
  ?llm:Types.llm_service ->
  config:Types.runtime_config ->
  Eio.Switch.t ->
  (runtime, Types.error_category) result
```

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
  model : model_config;                   (* LLM 模型配置 *)
  tools : tool_descriptor list;           (* 可用工具列表 *)
  max_iterations : int;                   (* ReAct 循环最大迭代次数 *)
  middleware : middleware_hook list;       (* 中间件管道 *)
  retry_policy : retry_policy option;     (* 可选重试策略 *)
  context_strategy : context_strategy option;  (* 上下文窗口管理策略 *)
  resource_quota : resource_quota option;  (* 可选资源配额覆盖 *)
}
```

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
} in
ignore (Runtime.register_agent rt agent)
```

### 调用 Agent

```ocaml
val Runtime.invoke :
  runtime ->
  agent_id:string ->
  message:string ->
  ?cancellation_token:Types.cancellation_token ->
  unit ->
  (Types.llm_response, Types.error_category) result
```

```ocaml
match Runtime.invoke rt ~agent_id:"my-agent" ~message:"Hello!" () with
| Ok resp ->
  (match resp.text with Some text -> Printf.printf "Response: %s\n" text
  | None -> Printf.printf "No text response\n")
| Error err -> Printf.eprintf "Error: %s\n" (Types.error_category_to_yojson err |> Yojson.Safe.to_string)
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

对于 `Max_tokens` finish_reason，若尚未达到迭代上限，循环会自动重试。

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
- [Workflow API](workflow.md) -- 工作流编排
- [Middleware API](middleware.md) -- 中间件管道
- [examples/basic_agent.ml](../../../examples/basic_agent.ml) -- 完整可运行示例
