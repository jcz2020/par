# PAR 快速入门

[English](https://github.com/jcz2020/par/blob/main/docs/quickstart.md) · **简体中文**

> 从零开始，30 分钟内用 OCaml 跑起一个带工具调用的 LLM Agent。

## 什么是 PAR？

PAR（Programmable Agent Runtime）是一个模块化、类型安全的 Agent 运行时，面向 OCaml 5.4+。
它内置 ReAct 推理引擎，支持 OpenAI 和 Anthropic 两个 LLM 供应商（以及任何 OpenAI 兼容接口，如智谱 GLM-4），
提供 23 个内置工具（含类型安全 bash 和 3 个记忆工具）、MCP 客户端（stdio + HTTP/SSE）、工作流编排和 SQLite 持久化。

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

**Python 绑定**（Linux x86_64 + macOS arm64）：

```bash
pip install par-runtime
```

**OCaml SDK**：

```bash
opam pin add par https://github.com/jcz2020/par.git
```

**交互式 SDK 向导**（自动检测系统，选择 Python 或 OCaml）：

```bash
curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
```

**从源码构建**：

```bash
git clone https://github.com/jcz2020/par.git
cd par
opam install --deps-only .    # 安装依赖
dune build                     # 编译
dune install                   # 安装到 opam 环境
```

安装后会得到一个 opam 包和一个 PyPI 包：
- `par` — SDK 库（OCaml）
- `par-runtime` — Python 绑定（PyPI）

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

PAR 通过 SDK 进行配置。你需要两样东西：API Key 和持久化后端。

### API Key

将 API Key 设置为环境变量：

```bash
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
```

### 持久化

创建 `runtime_config` 时，使用对象形式指定持久化后端：

```json
{"persistence": {"tag": "sqlite", "contents": ":memory:"}}
```

`":memory:"` 表示使用内存数据库（适合测试）。如需持久存储，替换为文件路径如 `"par.db"`。

### OCaml SDK

直接在 `runtime_config` 记录中配置供应商。类型化的记录提供编译期安全检查：

```ocaml
let config = {
  Types.persistence = `Sqlite ":memory:";  (* 或 `Sqlite "par.db"` 用于文件存储 *)
  (* ... 其他字段使用默认值 ... *)
} in
```

### Python 绑定

创建 runtime 时传入 JSON 配置字符串：

```python
from par_runtime import Runtime
import json

config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "default_quota": {"max_tokens": 4096, "max_iterations": 10, "timeout_seconds": 30.0},
})

with Runtime(config) as rt:
    agent = rt.make_agent(id="assistant", model="openai/gpt-4o-mini")
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
    parallel_tool_execution = true;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = 604800.0;
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
          system_prompt = Types.stable_prompt "You are an echo assistant. Use the echo tool.";
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
    parallel_tool_execution = true;
    bash_confirm = Runtime.default_bash_confirm;
    event_retention_seconds = 604800.0;
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
          system_prompt = Types.stable_prompt "You are a math assistant. Use the calculator tool.";
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
`convert_temperature`、`url_encode`、`fetch_url`、`read_webpage`、`web_search`、
`read`、`ls`、`find`、`grep`、`write`、`edit`、`bash`、
`recall_memory`、`remember_memory`、`search_history`。

## 持久化：SQLite

PAR 默认使用 SQLite 持久化。在 `runtime_config` 中配置：

```ocaml
let config = {
  Types.persistence = `Sqlite "par.db";  (* 文件路径 *)
  (* ... 其他字段 ... *)
} in
```

数据库文件会在运行时自动创建（如果不存在），存储任务状态、事件日志和工作流检查点。

SQLite 是唯一的持久化后端，无需额外配置。

## 故障排查

| 症状 | 原因 | 解决方案 |
|------|------|---------|
| `Unbound module Types` | 缺少 `open Par` | 在文件顶部添加 `open Par` |
| `Unbound module Par` | 未找到 par 库 | 确认 `dune-project` 中 `(libraries par ...)` 已声明 |
| `Connection refused` | API Key 缺失或网络不通 | 检查环境变量（`OPENAI_API_KEY` / `ANTHROPIC_API_KEY`）是否正确设置 |
| `LLM not initialized` | 未配置 LLM 供应商 | 确保 `runtime_config` 中设置了 `llm_providers`，或在调用 `Runtime.invoke` 时传入 `~llm` |
| `Error creating OpenAI provider` | API Key 格式错误 | 确认以 `sk-` 开头（OpenAI）或 `sk-ant-`（Anthropic） |
| `dune build` 编译失败 | 依赖未安装 | 运行 `opam install --deps-only .` |
| `ppx_deriving_yojson` 报错 | 缺少预处理器 | 在 dune 文件中添加 `(preprocess (pps ppx_deriving_yojson))` |

## v0.8.x 新特性

PAR 自 v0.7 以来新增了多项能力，简要介绍如下。

**HITL 审批**（v0.8.0）让 Agent 在执行过程中暂停等待人工审批。审批状态持久化到 SQLite，即使进程重启也不会丢失。外部系统可通过 webhook 完成审批。详见 [HITL API](sdk/hitl.md)。

**并行多 Agent 调度**（v0.8.0）通过 `Runtime.invoke_parallel` 并发运行 N 个 Agent，支持类型化合并、每 Agent 独立工作区隔离和每 Agent 审批处理器覆盖。详见 [Parallel Dispatch](sdk/parallel.md)。

**记忆服务**（v0.7.1，v0.8.1 增强）提供跨会话的 Agent 记忆，支持 FTS5 关键词搜索。3 个内置工具（`recall_memory`、`remember_memory`、`search_history`）让 Agent 直接访问记忆。通过 `invoke_context` 按会话隔离。详见 [Memory API](sdk/memory.md)。

**Skills 系统**（v0.8.1）支持在 `~/.par/skills/<id>/` 放置 `skill.md` 文件，在 `Runtime.invoke` 时根据触发条件（Auto / Manual / Keyword）自动激活。通过 `?skills` 参数支持按调用切换模式。详见 [Skills API](sdk/skills.md)。

**Think_tag_strip 中间件**（v0.8.2）自动清理推理模型输出中的标签（如 `<think>` 块）。适用于使用推理标记的模型。详见 [Middleware](sdk/middleware.md)。

## 下一步

- [HITL API](sdk/hitl.md) — 暂停-恢复审批、跨进程持久化
- [Parallel Dispatch](sdk/parallel.md) — 并行多 Agent 调度、类型化合并
- [Memory API](sdk/memory.md) — 跨会话 Agent 记忆，FTS5 搜索
- [Skills API](sdk/skills.md) — 可复用的提示词 + 工具包，带触发条件
- [Streaming API](sdk/streaming.md) — 令牌流式输出、工具调用事件
- [Agent API](sdk/agent.md) — `agent_config`、`Runtime.invoke`、工具处理器详解
- [Workflow API](sdk/workflow.md) — 顺序、并行、条件分支、map-reduce
- [Middleware](sdk/middleware.md) — 日志、重试、限流、超时、PII 掩码、Think_tag_strip
- [Tutorial 01: RAG 问答机器人](tutorials/01-rag-qa-bot.md) — 为 Agent 添加知识库
- [Tutorial 02: 流式 UI](tutorials/02-streaming-ui.md) — 在 TTY UI 中实时查看令牌流
- [examples/](https://github.com/jcz2020/par/blob/main/examples/) — 完整示例代码
