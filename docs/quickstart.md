# PAR 快速入门

> 从零开始，30 分钟内用 OCaml 跑起一个带工具调用的 LLM Agent。

## 什么是 PAR？

PAR（Programmable Agent Runtime）是一个模块化、类型安全的 Agent 运行时，面向 OCaml 5.4+。
它内置 ReAct 推理引擎，支持 OpenAI 和 Anthropic 两个 LLM 供应商（以及任何 OpenAI 兼容接口，如智谱 GLM-4），
提供 20 个内置工具（含类型安全 bash）、MCP stdio 客户端、工作流编排和 SQLite/PostgreSQL 持久化。

## 前置条件

| 依赖 | 最低版本 | 检查命令 |
|------|---------|---------|
| OCaml | 5.4+ | `ocaml --version` |
| opam | 2.1+ | `opam --version` |
| dune | 3.16+ | `dune --version` |
| API Key | OpenAI 或 Anthropic | -- |

如果没有 OCaml 环境，推荐使用 opam 安装：

```bash
bash -c "sh <(curl -fsSL https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh)"
opam init --disable-sandboxing --bare
opam switch create 5.4.0
eval $(opam env)
```

## 安装

从源码构建（推荐）：

```bash
git clone https://github.com/jcz2020/par.git
cd par
opam install --deps-only .    # 安装依赖
dune build                     # 编译
dune install                   # 安装到 opam 环境
```

或一键安装脚本（自动处理所有依赖）：

```bash
curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
```

安装后会得到两个包：
- `par` -- SDK 库
- `par_cli` -- 命令行工具（`par`、`par config`、`par ask`）

## 项目初始化

创建一个新的 OCaml 项目，最少需要三个文件。

**dune-project**：

```
(lang dune 3.16)
(name my_par_app)

(executable
 (name main)
 (libraries par eio eio_main)
 (preprocess (pps ppx_deriving_yojson)))
```

**dune**：

```
(executable
 (name main)
 (libraries par eio eio_main)
 (preprocess (pps ppx_deriving_yojson)))
```

**main.ml** -- 先放一个空壳，后面逐步填充：

```ocaml
let () = print_endline "Hello PAR"
```

运行验证环境：

```bash
dune exec ./main.exe   # 输出: Hello PAR
```

## 配置 LLM 供应商

PAR 的 CLI 使用 JSON 配置文件，存储在 `~/.par/config.json`。
最简单的方式是通过向导生成：

```bash
par config
```

向导会依次询问 provider、API key、model name 等字段。
手动编辑配置文件时，格式如下：

**OpenAI（含智谱 GLM-4 等 OpenAI 兼容接口）**：

```json
{
  "provider": "openai",
  "api_key": "sk-...",
  "api_base": null,
  "model": "gpt-4",
  "persistence": "sqlite",
  "db_uri": null,
  "temperature": 0.7,
  "system_prompt": "You are a helpful assistant."
}
```

**智谱 GLM-4（OpenAI 兼容模式）**：

```json
{
  "provider": "openai",
  "api_key": "your-zhipuai-key",
  "api_base": "https://open.bigmodel.cn/api/paas/v4",
  "model": "glm-4",
  "persistence": "sqlite",
  "db_uri": null,
  "temperature": 0.7,
  "system_prompt": "You are a helpful assistant."
}
```

**Anthropic**：

```json
{
  "provider": "anthropic",
  "api_key": "sk-ant-...",
  "api_base": null,
  "model": "claude-sonnet-4-20250514",
  "persistence": "sqlite",
  "db_uri": null,
  "temperature": 0.7,
  "system_prompt": "You are a helpful assistant."
}
```

也可以通过环境变量传递 API Key（适用于 SDK 编程）：

```bash
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
```

## 编写第一个 Agent

下面用 SDK 编写一个完整的 Agent。将 `main.ml` 替换为以下内容：

```ocaml
open Par

let () =
  (* 1. 运行时配置 *)
  let config = {
    Types.persistence = `Sqlite "par.db";
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
  } in

  (* 2. 启动 Eio 事件循环 *)
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun switch ->
      (* 3. 创建运行时 *)
      match Runtime.create ~config switch with
      | Error _err ->
        Printf.eprintf "Failed to create runtime\n"
      | Ok rt ->
        (* 4. 注册一个 echo 工具 *)
        let tool = Runtime.register_tool rt
          ~name:"echo"
          ~description:"Echoes back the input"
          ~input_schema:(`Assoc [
            ("type", `String "object");
            ("properties", `Assoc []);
          ])
          ~handler:(fun input _token ->
            Types.Success
              (`String (Printf.sprintf "Echo: %s"
                (Yojson.Safe.to_string input))))
          ()
        in
        (* 5. 定义 Agent 配置 *)
        let agent = {
          Types.id = "echo-agent";
          system_prompt = "You are an echo assistant. Use the echo tool.";
          model = {
            provider = `Openai;
            model_name = "gpt-4";
            api_base = None;
            temperature = 0.7;
            max_tokens = None;
            top_p = None;
            stop_sequences = None;
          };
          tools = [ tool.descriptor ];
          max_iterations = 5;
          middleware = [];
          retry_policy = None;
          context_strategy = None;
          resource_quota = None;
        } in
        (* 6. 注册并确认 *)
        ignore (Runtime.register_agent rt agent);
        Printf.printf "Agent registered: %s\n" agent.id;
        ignore (Runtime.close rt)
    )
  )
```

逐行说明关键步骤：

1. **运行时配置** -- `runtime_config` 持久化用 SQLite，事件总线和配额用默认值即可。
2. **Eio 事件循环** -- PAR 基于 Eio 的结构化并发，所有代码在 `Eio_main.run` 中执行。
3. **创建运行时** -- `Runtime.create` 返回 `Result.t`，需要处理错误分支。
4. **注册工具** -- `register_tool` 接受名称、描述、JSON Schema 和处理函数，返回 `tool_binding`。
5. **Agent 配置** -- `agent_config` 指定 system prompt、模型参数、工具列表、最大迭代次数等。
6. **注册 Agent** -- `register_agent` 将配置加入运行时的 agent 表。

## 运行 Agent

```bash
dune exec ./main.exe
# 输出: Agent registered: echo-agent
```

要真正与 Agent 对话，需要配置 LLM 供应商并调用 `Runtime.invoke`：

```ocaml
(* 在 Runtime.register_agent rt agent 之后添加 *)
match Runtime.invoke rt ~agent_id:"echo-agent"
  ~message:"Hello, echo!" ()
with
| Ok resp ->
  (match resp.Types.text with
   | Some txt -> Printf.printf "Response: %s\n" txt
   | None -> Printf.printf "No text response\n")
| Error e -> Printf.eprintf "Error: %s\n" (Printexc.to_string (Failure ""))
```

## 使用 CLI

PAR 自带交互式 REPL，零代码即可体验。

**配置**：

```bash
par config
# 按提示输入 provider、API key、model 等
```

**交互对话**：

```bash
par
# > What is 2 + 3?
# Agent: 2 + 3 = 5
# > ^D (Ctrl+D 退出)
```

**单次问答**：

```bash
par ask "What is the capital of France?"
# Agent: The capital of France is Paris.
```

CLI 自动注册所有 13 个内置工具，支持命令行覆盖参数：

```bash
par ask --provider anthropic --model claude-sonnet-4-20250514 "Hello"
par ask --temperature 0.3 "Explain quantum computing"
```

## 使用内置工具

SDK 中通过 `Par.Builtin_tools` 获取所有内置工具的绑定：

```ocaml
open Par

let () =
  let config = {
    Types.persistence = `Sqlite "par.db";
    event_bus = Runtime.default_event_bus_config;
    default_quota = Runtime.default_quota;
    shutdown = Runtime.default_shutdown_config;
    llm_providers = [];
    eval_limits = { max_depth = 10; max_node_visits = 1000 };
  } in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun switch ->
      match Runtime.create ~config switch with
      | Error _ -> Printf.eprintf "Failed to create runtime\n"
      | Ok rt ->
        (* 获取所有内置工具 *)
        let net = Eio.Stdenv.net env in
        let tools = Builtin_tools.builtin_tools ~switch ~net in
        List.iter (fun (tb : Types.tool_binding) ->
          Tool_registry.register
            (Runtime.tool_registry rt) tb.descriptor tb.handler
        ) tools;
        let descriptors =
          List.map (fun (tb : Types.tool_binding) -> tb.descriptor) tools
        in
        (* 创建带 calculator 的 Agent *)
        let agent = {
          Types.id = "math-agent";
          system_prompt = "You are a math assistant. Use the calculator tool.";
          model = {
            provider = `Openai;
            model_name = "gpt-4";
            api_base = None;
            temperature = 0.7;
            max_tokens = None;
            top_p = None;
            stop_sequences = None;
          };
          tools = descriptors;  (* 所有内置工具 *)
          max_iterations = 10;
          middleware = [];
          retry_policy = None;
          context_strategy = None;
          resource_quota = None;
        } in
        ignore (Runtime.register_agent rt agent);
        Printf.printf "Agent registered with %d tools\n"
          (List.length descriptors);
        ignore (Runtime.close rt)
    )
  )
```

内置工具包括：`calculator`、`get_time`、`echo`、`generate_uuid`、
`hash_text`、`generate_password`、`string_stats`、`json_format`、
`convert_temperature`、`url_encode`、`fetch_url`、`read_webpage`、`web_search`。

## 持久化：SQLite

PAR 默认使用 SQLite 持久化。在 `runtime_config` 中配置：

```ocaml
let config = {
  Types.persistence = `Sqlite "par.db";  (* 文件路径 *)
  (* ... 其他字段 ... *)
} in
```

数据库文件会在运行时自动创建（如果不存在），存储任务状态、事件日志和工作流检查点。

切换到 PostgreSQL（生产环境推荐）：

```ocaml
let config = {
  Types.persistence = `Postgresql "postgresql://localhost/par";
  (* ... 其他字段 ... *)
} in
```

注意：PostgreSQL 后端需要额外安装 `opam install postgresql` 并重新编译。

## 故障排查

| 症状 | 原因 | 解决方案 |
|------|------|---------|
| `Unbound module Types` | 缺少 `open Par` | 在文件顶部添加 `open Par` |
| `Unbound module Par` | 未找到 par 库 | 确认 `dune-project` 中 `(libraries par ...)` 已声明 |
| `Connection refused` | API Key 缺失或网络不通 | 检查 `~/.par/config.json` 或环境变量 |
| `LLM not initialized` | SDK 模式下未传入 `~llm` 参数 | 用 CLI 模式（`par ask`）自动处理 LLM 初始化 |
| `Error creating OpenAI provider` | API Key 格式错误 | 确认以 `sk-` 开头（OpenAI）或 `sk-ant-`（Anthropic） |
| `dune build` 编译失败 | 依赖未安装 | 运行 `opam install --deps-only .` |
| `ppx_deriving_yojson` 报错 | 缺少预处理器 | 在 dune 文件中添加 `(preprocess (pps ppx_deriving_yojson))` |

## 下一步

- [agent.md](agent.md) -- Agent 配置详解：model_config 字段、context_strategy、retry_policy
- [workflow.md](workflow.md) -- 工作流编排：顺序、并行、条件分支、map-reduce
- [middleware.md](middleware.md) -- 中间件：日志、超时、重试、限速、PII 掩码、数据校验
- [examples/](../examples/) -- 更多完整示例（basic_agent.ml、otel_tracing.ml）
