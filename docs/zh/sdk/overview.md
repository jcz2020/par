# P-A-R SDK 概览

> **v0.6.7 提示：** 本仓库的 CLI（`par_cli` / `par ask` / `par config` / `par`）已移除；SDK（OCaml）与 Python 绑定是受支持的界面。新用户请安装 Python 绑定（`pip install par-runtime`）或 OCaml SDK（`opam install par`），交互式编码体验请使用 [par-code](https://github.com/jcz2020/par-code)。
[English](https://github.com/jcz2020/par/blob/main/sdk/overview.md) · **简体中文**

P-A-R (Programmable Agent Runtime) 是一个基于 OCaml 5.4+ 的模块化 Agent 运行时，
提供 ReAct 推理循环、多 Provider LLM 抽象、类型安全的 Shell 执行、MCP 客户端集成（stdio + HTTP/SSE）以及 9 层中间件管道。本概览是深入文档；README 是入口页面。

## 核心能力

| 能力 | 说明 |
|------|------|
| ReAct Agent 循环 | 思考-行动-观察循环，支持工具调用，可配置最大迭代次数 |
| 工作流引擎 | 顺序、并行、条件分支、Map-Reduce、人工审批、子工作流 |
| 多 Provider 支持 | OpenAI 兼容接口、Anthropic Messages API、Ollama、自定义端点 |
| MCP 客户端 | 连接任意 MCP server（stdio / HTTP/SSE），自动发现工具/资源/提示词 |
| 中间件管道 | 日志、重试、限速、超时、输入校验、PII 掩码、输出清洗、Think_tag_strip (9 个内置) |
| 持久化 | SQLite（唯一的持久化后端），事件溯源 + 任务状态持久化；Noop 用于测试 |
| FFI / Python 绑定 | C ABI (`par_capi.so`) + ctypes Python 包 (`par_runtime`) |

## 架构

```
+-----------------------------------------------------------+
|                       SDK (par)                           |
+----------+----------+----------+----------+--------------+
|  Core    |Providers |Persist   |Event_bus |  Middleware  |
| Types    |OpenAI    |SQLite    |Eio+DLQ   |  Logging     |
| Runtime  |Anthropic |SQLite    |          |  Retry       |
| Engine   |          |          |          |  Rate_limit  |
| Workflow |          |          |          |  Timeout     |
| Expr     |          |          |          |  Validation  |
| State_m  |          |          |          |  Pii_mask    |
+----------+----------+----------+----------+------+-------+
|                   Tools (23 builtin)                     |
|       calculator / web_search / fetch_url / bash ...     |
+----------+-----------------------------------------------+
|  MCP Client (v0.3.1)    |  tools / resources / prompts   |
|  stdio + HTTP/SSE transport  |  server lifecycle management   |
+-----------------------------------------------------------+
|                    FFI Bridge (par_capi)                  |
|         C API (par_ffi.h) -> Python ctypes binding         |
+-----------------------------------------------------------+
```

门面模块 `Par` 是唯一的导入入口：`open Par` 将上述所有子模块引入作用域，调用处只有在需要与本地 `Runtime` 名称消歧时才写 `Par.Runtime.invoke`。虚线表示横切关注点：取消从 `Eio.Switch.t` 流入每个工具处理器，事件总线将可观测性反馈回运行时，Provider 流式响应驱动 `Engine.run_agent` 中的 ReAct 循环。

## 五分钟 SDK 导览

五个独立示例，每个对应一个子系统。每个示例都基于已发布的 `par` opam 包编译。

### 1. Runtime + tool

创建运行时、注册工具、注册 Agent。处理器接收 JSON 输入和取消令牌，返回类型化的 `handler_result`。

```ocaml
open Par

let config = {
  Types.persistence = `Sqlite "par.db";
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
    let rt = Runtime.create ~config switch |> Result.get_ok in
    let tool = Runtime.register_tool rt ~name:"echo"
      ~description:"Echoes back the input"
      ~input_schema:(`Assoc ["type", `String "object";
                              "properties", `Assoc []])
      ~handler:(fun input _token ->
        Types.Success (`String (Printf.sprintf "Echo: %s"
          (Yojson.Safe.to_string input))))
      () |> Result.get_ok in
    ignore (Runtime.register_agent rt
      { id = "echo-agent"; system_prompt = Types.stable_prompt "You are an echo assistant.";
        system_prompt_template = None;
        model = { provider = `Openai; model_name = "gpt-4"; api_base = None;
                  temperature = 0.7; max_tokens = None; top_p = None;
                  stop_sequences = None };
        tools = [tool.descriptor]; max_iterations = 5;
        middleware = []; retry_policy = None; context_strategy = None;
        resource_quota = None; tool_timeout = None }))
```

### 2. LLM invoke

Agent 注册后，`Runtime.invoke` 运行 ReAct 循环，直到 LLM 发出 `Stop` 信号、所有工具调用返回，或达到 `max_iterations`。

```ocaml
match Runtime.invoke ~agent_id:"echo-agent" ~message:"Hello!" rt with
| Ok resp -> Printf.printf "Response: %s\n"
    (Option.value resp.Types.text ~default:"(no text)")
| Error err -> Printf.eprintf "Error: %s\n"
    (Yojson.Safe.to_string (Types.error_category_to_yojson err))
```

传入 `?cancellation_token:` 可中止长时间运行的调用；取消通过 Eio switch 传播到所有工具处理器。完整签名和 `error_category` 变体详见 [`agent.md`](agent.md)。

### 3. Event subscription

订阅事件总线并模式匹配生命周期事件。MCP server 事件与任务和工具事件在同一条总线上，一个订阅者即可覆盖整个运行时。

```ocaml
(* Event subscription: pass ?on_tool_event:(event -> unit) callback to Runtime.create *)
Event_bus.subscribe bus (fun ev ->
  match ev with
  | Mcp_tool_completed { server_id; tool_name; duration_ms } ->
    Printf.printf "[mcp] %s/%s done in %.1fms\n"
      server_id tool_name duration_ms
  | Bash_invoked { argv; risk; _ } ->
    Printf.printf "[bash] risk=%s argv=%s\n"
      risk (String.concat " " argv)
  | _ -> ())

ignore (Runtime.invoke ~agent_id:"echo-agent" ~message:"hi" rt)
```

### 4. Workflow

工作流是一棵步骤树：Agent 调用、工具调用、并行、顺序、条件分支、Map-Reduce、人工审批和子工作流。运行时提交工作流定义，返回 `Workflow_run_id.t` 用于状态查询。

```ocaml
let wf = {
  Types.id = "research"; Types.name = "Research and Summarize";
  Types.version = 1;
  Types.steps = Sequential [
    Agent_call { agent_id = "researcher";
                 prompt_template = "Research: {{topic}}";
                 response_schema = None };
    Human_approval { prompt_template = "Approve summary of {{topic}}?";
                     timeout = 60.0; allowed_roles = ["admin"] };
    Agent_call { agent_id = "summarizer";
                 prompt_template = "Summarize: {{topic}}";
                 response_schema = None } ];
  Types.variables = [("topic", `String "OCaml 5 effects")];
  Types.failure_policy = Fail_fast;
  Types.parallel_limit = 3; Types.timeout = 600.0;
  Types.on_complete = None;
} in
ignore (Runtime.register_workflow rt wf);
let run_id = Runtime.submit_workflow rt wf |> Result.get_ok in
ignore (Runtime.approve_workflow rt run_id ~approver:"alice")
```

参考：[`workflow.md`](workflow.md) 涵盖检查点、恢复和完整的步骤分类。

### 5. MCP client

将 MCP server 配置传入 `Runtime.create`；运行时启动每个子进程，完成初始化握手，返回的 `Runtime` 的 `mcp_server` 访问器提供类型化的客户端句柄。

```ocaml
let mcp_fs : Mcp_types.server_config = {
  name = "fs"; command = "npx";
  args = [ "-y"; "@modelcontextprotocol/server-filesystem"; "/tmp" ];
  env = []; cwd = None; startup_timeout = 10.0;
}

let () = Eio_main.run (fun env ->
  Eio.Switch.run (fun sw ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clock = Eio.Stdenv.clock env in
    let rt = Runtime.create
      ~mcp_servers:[mcp_fs] ~mcp_process_mgr:mgr ~mcp_clock:clock
      ~config sw |> Result.get_ok in
    let sid = Mcp_types.server_id_of_string "fs" |> Result.get_ok in
    let client = Mcp_client.of_server
      (Runtime.mcp_server rt sid |> Result.get_ok) in
    match Mcp_client.list_tools client with
    | Ok tools -> List.iter (fun t ->
        Printf.printf "- %s\n" t.Mcp_types.name) tools
    | Error _ -> ())
```

七种 MCP 事件类型（started、failed、stopped、tool invoked、tool completed、resource read、prompt rendered）都流经步骤 3 中展示的同一条事件总线。参考：[`mcp.md`](mcp.md)。

## 何时使用 SDK

SDK 是 PAR 的生产界面，所有功能均可通过 `Par.Runtime.*` 函数调用。对于交互式编码体验，使用 [par-code](https://github.com/jcz2020/par-code)。

| 用例 | SDK | 交互式替代 |
|---|---|---|
| 生产环境 Agent 服务 | 推荐 | — |
| 终端临时提问 | 可以但较冗长 | [par-code](https://github.com/jcz2020/par-code) |
| 可复现的批处理任务 | 脚本中调用 `Runtime.invoke` | — |
| 自定义 UI（Web、Slack、IDE 插件）| 嵌入 SDK | — |
| 首次体验 PAR | 可以但配置较重 | [par-code](https://github.com/jcz2020/par-code) |
| 多 Agent 工作流编排 | 注册并 `submit_workflow` | — |
| 应用中集成 MCP server | `Runtime.create` 传入 `~mcp_servers` | — |
| 长时间事件监控 | 进程内订阅 `Event_bus` | — |

（CLI 曾作为独立 opam 包 `par_cli` 发布，使 `par` 的消费者不会引入 `cmdliner` 和 REPL 依赖；该包已在 v0.6.7 移除。交互式编码体验由 [par-code](https://github.com/jcz2020/par-code) 提供。）

## 模块组织

每个公共模块都位于以下 9 个子库之一，外加 `lib/par.ml` 中的门面模块。`open Par` 重新导出标记的模块；未标记的模块仍可通过 `Par.<Module>` 访问。

| 层 | 模块 | 职责 |
|----|------|------|
| Core | `Par.Types` | 所有核心类型定义：`agent_config`、`model_config`、`workflow_step`、`event` 等 |
| Core | `Par.Runtime` | 运行时创建、Agent 注册/调用、工具注册、工作流提交 |
| Core | `Par.Engine` | ReAct 循环实现、中间件链组合、工具执行管道 |
| Core | `Par.Workflow_engine` | 工作流执行器：顺序/并行/条件/Map-Reduce/审批/子工作流 |
| Core | `Par.Expression` | 表达式求值器（用于条件分支），支持变量引用和比较运算 |
| Core | `Par.State_machine` | 任务状态机：9 种状态 + 合法转换校验 |
| Core | `Par.Context_manager` | 上下文窗口管理：截断、摘要、滑动窗口 |
| Core | `Par.Cancellation` | 取消令牌：协作式取消、超时包装 |
| Core | `Par.Tool_registry` | 工具处理器注册表（名称 -> handler 映射） |
| Core | `Par.Template` | 系统提示词模板引擎 |
| Core | `Par.Steering_queue` | Agent 指令队列 |
| Core | `Par.Hook` | 生命周期钩子 |
| Core | `Par.Metrics` | 指标收集 |
| Core | `Par.Capability` | 运行时能力检测：平台相关功能的单一检测点 |
| Core | `Par.Invoke_context` | 每次调用隔离：通过 `Eio.Fiber.with_binding` 实现的 per-call 上下文 |
| Core | `Par.Deprecation` | 弃用框架：`warn_once` + 事件总线信号 + 迁移指南 |
| Providers | `Par.Openai_provider` | OpenAI Chat Completions API + SSE 流式响应 |
| Providers | `Par.Anthropic_provider` | Anthropic Messages API |
| Providers | `Par.Mock_provider` | 测试用 mock provider |
| Persistence | `Par.Sqlite_persistence` | SQLite 后端（事件 + 任务状态 + 工作流状态） |
| Persistence | `Par.Noop_persistence` | 空操作持久化（用于测试和快速原型） |
| Event_bus | `Par.Event_bus` | Eio 异步事件总线 + 死信队列 |
| Middleware | `Par.Logging`, `Par.Retry`, `Par.Rate_limit`, `Par.Timeout`, `Par.Arg_validation`, `Par.Output_validation`, `Par.Pii_mask`, `Par.Sanitize_tool_output`, `Par.Think_tag_strip` | 9 个内置中间件 |
| Tools | `Par.Builtin_tools`, `Par.Bash_safe_command`, `Par.Bash_policy`, `Par.Bash_blacklist` | 23 个内置工具（含类型安全 bash 和 3 个记忆工具） |
| Documents | `Par.Document`, `Par.Text_loader`, `Par.Markdown_loader`, `Par.Html_loader`, `Par.Csv_loader`, `Par.Pdf_loader`, `Par.Directory_loader` | RAG 文档加载器（文本、Markdown、HTML、CSV、PDF） |
| Memory | `Par.Memory_service`, `Par.Sqlite_memory`, `Par.Memory_error`, `Par.Memory_object` | Agent 记忆，FTS5 关键词搜索 |
| Skills | `Par.Skill_loader`, `Par.Builtin_skills` | 技能系统（自动加载的指令包，支持触发条件） |
| MCP | `Par.Mcp_types`, `Par.Mcp_server`, `Par.Mcp_client`, `Par.Mcp_transport_stdio`, `Par.Mcp_transport_http`, `Par.Mcp_naming`, `Par.Mcp_errors` | MCP 客户端（stdio v0.3.1，HTTP/SSE v0.4.3） |
| FFI | `Par_capi`（构建产物） | Python 绑定的 C ABI |
| `lib/par.ml` | （门面模块，重新导出上述模块） | `open Par` 入口 |
| `bindings/python/` | `par_runtime` PyPI 包 | Python ctypes 绑定 |

门面模块 `Par` 由 `lib/par.ml` 生成。所有代码直接链接 `par`（`bin/` CLI 目录已在 v0.6.7 移除；交互式编码产品位于 [par-code](https://github.com/jcz2020/par-code)）。

## 关键不变量

类型系统强制执行五项保证，在不够严格的语言中这些会是运行时检查。每一项都把一类 bug 从"发布后发现"移到了"无法编译"。

- `Par.State_machine` 中的 8 状态机在编译时拒绝非法任务转换（可在类型本身中配置）。
- `Bash_safe_command.command` ADT 没有 `Exec_raw_shell` 构造器；shell 注入不可表达。
- `error_category` 和类型强制每条错误路径显式处理；公共 API 中无未类型化异常。
- `Eio.Switch.t` 取消通过 `Cancellation_token.t` 传播到所有工具处理器；`Runtime.close` 触发整棵树取消。
- 工具注册返回 `Error (\`Duplicate_tool)` 而非静默覆盖；工具名称在构造时唯一。

这些保证共同使 SDK 成为一个在边界处大声失败的库（编译错误、类型化 `Error` 变体、`Cancelled` 异常），而非在运行时静默失败。

## 平台支持

PAR 支持 Linux、macOS 和 Windows。核心运行时（agent、LLM 调用、持久化、记忆、工作流、HTTP/SSE MCP）在三个平台上均可运行。部分能力依赖操作系统，PAR 在运行时检测。

| 平台 | 核心运行时 | 进程生成 | Pipe I/O | 基于信号的终止 |
|------|-----------|---------|----------|---------------|
| Linux | 完整支持 | 可用 | 可用 | 可用 |
| macOS | 完整支持 | 可用 | 可用 | 可用 |
| Windows | 完整支持 | 不可用 | 不可用 | 不可用 |

**Windows 注意事项：**
- Agent、LLM 调用（OpenAI、Anthropic、Ollama）、SQLite 持久化、记忆（`Memory_service` FTS5）、工作流和 HTTP/SSE MCP 在 Windows 上均可工作。
- 进程生成（`bash` 工具、MCP stdio 传输）通过 `Capability.detect` 返回类型化的 `Unavailable` 错误，不会崩溃。Agent 循环优雅处理此情况。
- `sqlite-vec` 向量存储在 Windows 上可用（构建中内嵌了 `vec0.dll`）。
- Windows 上推荐使用 HTTP/SSE 传输连接 MCP，因为 stdio 依赖进程生成。

### 能力检测 API

`Capability` 模块为平台相关功能提供单一检测点：

```ocaml
open Par

let status = Capability.detect () `Process_spawning
(* Linux/macOS: `Available
   Windows:      `Unavailable "Process spawning requires Eio.Process, ..." *)

let is_win = Capability.is_windows ()   (* Win32 上为 true，其他为 false *)
let platform = Capability.platform_name ()  (* "Linux"、"macOS"、"Windows" 等 *)
```

工具处理器和运行时内部逻辑通过 `Capability.detect` 查询能力，而不是在代码库中散落 `Sys.os_type` 检查。这使得平台门控集中化且可测试。

## 下一步

- [`docs/sdk/agent.md`](agent.md)：主要参考，涵盖 `Runtime.create`、`register_agent`、`register_tool`、ReAct 循环
- [`docs/sdk/workflow.md`](workflow.md)：步骤分类、检查点、人工审批、JSON 工作流格式
- [`docs/sdk/mcp.md`](mcp.md)：MCP 客户端生命周期、事件类型、server 命名和隔离
- [`docs/sdk/middleware.md`](middleware.md)：全部 9 个内置中间件和 `middleware_hook` 结构
- [`docs/sdk/tools.md`](tools.md)：全部 23 个内置工具及输入/输出 schema
- [`docs/sdk/persistence.md`](persistence.md)：持久化服务、SQLite 后端、scope 维度
- [`docs/quickstart.md`](https://github.com/jcz2020/par/blob/main/quickstart.md)：30 分钟新手实践教程
- [`docs/explanation/architecture.md`](https://github.com/jcz2020/par/blob/main/explanation/architecture.md)：数据流、Eio 模型和事件载荷 schema 深入解析
- [`CHANGES.md`](https://github.com/jcz2020/par/blob/main/../CHANGES.md)：发布说明
