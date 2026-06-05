# P-A-R — Programmable Agent Runtime

A modular, type-safe agent runtime for OCaml 5.4+ with multi-provider LLM support, workflow orchestration, and persistent state management.

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen)](https://github.com/jcz2020/par)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Features

- 多provider LLM：OpenAI兼容接口 + Anthropic Messages API，支持通过ZhipuAI等中转调用Anthropic
- SSE流式响应（已验证，OpenAI provider）
- ReAct agent循环，支持工具调用
- 工作流引擎：顺序执行、并行执行、条件分支、map-reduce
- 7个内置中间件：日志、超时、重重试、限速、PII掩码、数据校验、tool output 清洗
- 双重持久化：SQLite（开发）/ PostgreSQL（生产，可选 opam 包）
- 交互式REPL（`par`）
- 安全URL抓取：TLS证书验证、系统CA store、URL scheme校验、10MB容量限制
- MCP stdio 客户端：连接任意 MCP server（filesystem、git、sqlite 等），自动发现工具/资源/提示词
- 类型安全 bash：Safe_command ADT + Policy Functor + 31 条黑名单，shell 注入在类型层不可表示
- C FFI + Python binding：ctypes FFI，线程安全，par_runtime 包
  - 680 个测试用例通过（664 OCaml + 16 Python）

## Architecture

```
+-----------------------------------------------------------+
|                      CLI (par_cli)                        |
|            par / par config / par ask                     |
+-----------------------------------------------------------+
|                       SDK (par)                           |
+----------+----------+----------+----------+--------------+
|  Core    |Providers |Persist   |Event_bus |  Middleware  |
| Types    |OpenAI    |SQLite    |Eio+DLQ   |  Logging     |
| Runtime  |Anthropic |PostgreSQL|          |  Retry       |
| Engine   |          |          |          |  Rate_limit  |
| Workflow |          |          |          |  Timeout     |
| Expr     |          |          |          |  Validation  |
| State_m  |          |          |          |  Pii_mask    |
+----------+----------+----------+----------+------+-------+
|          Tools (20 builtin: 19 + bash in v0.3.1)        |
|       calculator / web_search / fetch_url / ...          |
+----------+-----------------------------------------------+
|  MCP Client (v0.3.1)    |  tools / resources / prompts   |
|  stdio transport only   |  server lifecycle management   |
+-----------------------------------------------------------+
|                    FFI Bridge (par_capi)                  |
|         C API (par_ffi.h) → Python ctypes binding         |
+-----------------------------------------------------------+
```

## Quick Start

```bash
# 一键安装（自动安装系统依赖 + OCaml + 构建 + 安装到 /usr/local/bin）
curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash

# 或手动安装
git clone https://github.com/jcz2020/par.git && cd par
make install

# 配置
par config

# 开聊
par
```

## Usage Example (OCaml SDK)

```ocaml
open Par

let config = {
  persistence = `Sqlite "par.db";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
}

let () = Eio_main.run (fun env ->
  Eio.Switch.run (fun switch ->
    match Runtime.create ~config switch with
    | Error _ -> Printf.eprintf "Failed to create runtime\n"
    | Ok rt ->
      let tool = Runtime.register_tool rt
        ~name:"echo"
        ~description:"Echoes back the input"
        ~input_schema:(`Assoc [("type", `String "object"); ("properties", `Assoc [])])
        ~handler:(fun input _token ->
          Success (`String (Printf.sprintf "Echo: %s" (Yojson.Safe.to_string input))))
        ()
      in
      let agent = {
        id = "my-agent";
        system_prompt = "You are a helpful assistant.";
        model = { provider = `Openai; model_name = "gpt-4"; api_base = None;
                  temperature = 0.7; max_tokens = None; top_p = None;
                  stop_sequences = None };
        tools = [tool];
        max_iterations = 5;
        middleware = [];
        retry_policy = None;
        context_strategy = None;
        resource_quota = None;
      } in
      ignore (Runtime.register_agent rt agent);
      Printf.printf "Agent registered: %s\n" agent.id;
      ignore (Runtime.close rt)
  )
)
```

See `examples/basic_agent.ml` for the complete example.

## MCP Client (v0.3.1)

PAR 可以连接任意 MCP (Model Context Protocol) server，让 AI agent 直接调用外部工具：

```ocaml
open Par

let mcp_config = {
  Mcp_types.name = "filesystem";
  command = "npx";
  args = ["-y"; "@anthropic/mcp-server-filesystem"; "/tmp"];
  env = [];
  cwd = None;
  startup_timeout = 10.0;
}

let () = Eio_main.run (fun env ->
  Eio.Switch.run (fun switch ->
    match Runtime.create
      ~mcp_servers:[mcp_config]
      ~mcp_process_mgr:(Eio.Stdenv.process_mgr env)
      ~mcp_clock:(Eio.Stdenv.clock env)
      ~config switch
    with
    | Error e -> Printf.eprintf "Failed: %s\n" (Runtime.string_of_error_category e)
    | Ok rt ->
      (* MCP server 已自动启动，通过 Runtime.mcp_server 访问 *)
      let result = Runtime.mcp_server rt "filesystem" in
      (match result with
       | Ok server ->
         let tools = Mcp_client.list_tools (Mcp_client.of_server server) in
         (match tools with
          | Ok tool_list ->
            Printf.printf "MCP server has %d tools\n" (List.length tool_list)
          | Error e ->
            Printf.eprintf "list_tools failed: %s\n" (Runtime.string_of_error_category e))
       | Error e ->
         Printf.eprintf "Server not found: %s\n" (Runtime.string_of_error_category e));
      ignore (Runtime.close rt)
  )
)
```

详见 [`docs/sdk/mcp.md`](docs/sdk/mcp.md)。

## Python Binding

```bash
# Build the shared library
dune build lib/ffi/par_capi.so

# Run Python tests
cd bindings/python && python3 -m pytest tests/
```

```python
import json
from par_runtime import Runtime

config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "event_bus": {"max_queue_size": 100, "dlq_enabled": False, "dlq_max_size": 10},
    "default_quota": {"max_tokens": 4096, "max_iterations": 10, "timeout_seconds": 30.0},
    "shutdown": {"grace_period_seconds": 5.0, "force_after_seconds": 10.0},
    "llm_providers": [],
    "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
})

with Runtime(config) as rt:
    rt.register_tool("echo", "Echo tool", '{"type": "object"}')
    # result = rt.invoke("my-agent", "Hello!")  # requires LLM provider
```

See `bindings/python/examples/basic_agent.py` for the full example.

## CLI Reference

| Command | Description |
|---------|-------------|
| `par` | 交互式对话（读取配置文件，零参数） |
| `par config` | 配置 provider / API key / model |
| `par ask "问题"` | 单次问答，直接输出答案 |

所有命令支持可选覆盖参数：`--provider`、`--api-key`、`--model`、`--persistence`、`--db-uri`、`--temperature`

## Documentation

| Doc | Description |
|-----|-------------|
| [`docs/quickstart.md`](docs/quickstart.md) | 30 分钟上手教程：安装 → 配置 provider → 写第一个 agent |
| [`docs/cli.md`](docs/cli.md) | CLI 完整参考：par / par config / par ask 全部命令与参数 |
| [`docs/sdk/overview.md`](docs/sdk/overview.md) | SDK 架构总览与模块组织 |
| [`docs/sdk/agent.md`](docs/sdk/agent.md) | Agent 定义、Runtime API、工具注册 |
| [`docs/sdk/workflow.md`](docs/sdk/workflow.md) | 工作流 JSON 格式与 8 种 step 类型 |
| [`docs/sdk/middleware.md`](docs/sdk/middleware.md) | 7 个内置中间件与自定义中间件 |
| [`docs/sdk/tools.md`](docs/sdk/tools.md) | 20 个内置工具（含 bash 安全工具） |
| [`docs/sdk/mcp.md`](docs/sdk/mcp.md) | MCP stdio 客户端：连接外部工具服务器 |
| [`CHANGES.md`](CHANGES.md) | 变更日志 |

## Built-in Tools

| Tool | Description |
|------|-------------|
| `calculator` | 算术表达式求值 |
| `get_time` | 当前UTC日期/时间 |
| `echo` | 回显输入 |
| `generate_uuid` | UUID v4生成 |
| `hash_text` | MD5/SHA1/SHA256哈希 |
| `generate_password` | 安全随机密码 |
| `string_stats` | 字符/单词/行数统计 |
| `json_format` | JSON验证和格式化 |
| `convert_temperature` | C/F/K温度转换 |
| `url_encode` | URL编码/解码 |
| `fetch_url` | HTTP GET，内容提取（10MB上限） |
| `read_webpage` | 抓取 + HTML解析 + 文本提取（剥离script/style） |
| `web_search` | DuckDuckGo搜索 |

## Module Reference

| Package | Description |
|---------|-------------|
| `par` | SDK: Core types, ReAct engine, runtime, workflow, expression evaluator, state machine, context manager, event bus, OpenAI/Anthropic providers, SQLite persistence (PostgreSQL optional), 20 builtin tools (incl. type-safe bash), MCP stdio client, 7 middleware |
| `par_cli` | CLI tool: `par` (REPL), `par config` (wizard), `par ask` (single-shot) — SDK 验证工具 |

## Project Structure

```
par/
+-- bin/              CLI entry point (par, par config, par ask)
+-- lib/
|   +-- core/          Types, Runtime, Engine, SDK, Expression, State machine, Workflow, Context manager, Cancellation
|   +-- providers/     OpenAI and Anthropic LLM providers
|   +-- persistence/   SQLite backend + Noop fallback
|   +-- postgres/      Optional PostgreSQL backend (separate dune library, par_postgres)
|   +-- event_bus/     Eio-based event bus with DLQ
|   +-- middleware/    Logging, Retry, Rate_limit, Timeout, Validation, Pii_mask, Sanitize_tool_output
|   +-- tools/         20 builtin tools (calculator, web tools, file ops, bash in v0.3.1)
|   +-- mcp/           MCP stdio client (mcp_types, mcp_server, mcp_client, mcp_transport_stdio, mcp_naming, mcp_errors)
|   +-- ffi/           C FFI bridge (par_ffi.h, par_ffi.c, par_capi.ml)
|   +-- par.ml         Facade module (re-exports all sub-modules for `open Par`)
+-- bindings/
|   +-- python/        Python ctypes binding (par_runtime package)
|       +-- par_runtime/     Runtime, errors, FFI declarations
|       +-- tests/           8 pytest tests
|       +-- examples/        basic_agent.py
+-- test/              Unit and integration tests
+-- examples/          Example agents and workflows
+-- schema/            Database schemas
+-- docs/              User documentation (quickstart, CLI ref, SDK ref)
```

## Dependencies

OCaml 5.4+, dune 3.23+, cohttp-eio, lambdasoup, tls-eio, ca-certs, postgresql（PG后端可选）

## Project Size

- 约 10000 行 OCaml + 1200 行 Python
- 680 个测试用例（664 OCaml + 16 Python）

## License

MIT