# P-A-R — Programmable Agent Runtime

A modular, type-safe agent runtime for OCaml 5.4+ with multi-provider LLM support, workflow orchestration, and persistent state management.

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen)](https://github.com/par-runtime/par)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Features

- 多provider LLM：OpenAI兼容接口 + Anthropic Messages API，支持通过ZhipuAI等中转调用Anthropic
- SSE流式响应（已验证，OpenAI provider）
- ReAct agent循环，支持工具调用
- 工作流引擎：顺序执行、并行执行、条件分支、map-reduce
- 6个内置中间件：日志、超时、重试、限速、PII掩码、数据校验
- 双重持久化：SQLite（开发）/ PostgreSQL（生产）
- 交互式REPL（`par run`）
- 安全URL抓取：TLS证书验证、系统CA store、URL scheme校验、10MB容量限制
- 111个测试用例通过

## Architecture

```
+-------------------------------------------------------------+
|                         CLI (par)                            |
+-------------------------------------------------------------+
|                     SDK (Runtime API)                        |
+------------+--------+-----------+--------------------------+
|   Engine   |Workflow|  Context  |       Middleware          |
|  (ReAct)   |Engine  |  Manager  |     (6 built-in)          |
+------------+--------+-----------+--------------------------+
|                     Core Types (par_core)                   |
+------------+----------+-----------+--------------------------+
|  par_eio   |par_sqlite|par_pgsql |        LLM Providers      |
| (Event Bus)|(Persist )|(Persist )|  OpenAI / Anthropic      |
|    +DLQ    |          |          |                          |
+------------+----------+-----------+--------------------------+
|                      Web Tools (cohttp-eio + lambdasoup)    |
+-------------------------------------------------------------+
```

## Quick Start

```bash
# 依赖：OCaml 5.4+, dune 3.23+
opam switch create . 5.4.1
eval $(opam env)
opam install . --deps-only

# 构建
dune build

# 运行测试
dune runtest

# CLI交互式REPL
dune exec par -- run --provider openai --api-key $OPENAI_API_KEY --model gpt-4
```

## Usage Example (OCaml SDK)

```ocaml
open Par_core

let config = {
  Types.persistence = `Sqlite "par.db";
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
          Types.Success (`String (Printf.sprintf "Echo: %s" (Yojson.Safe.to_string input))))
        ()
      in
      let agent = {
        Types.id = "my-agent";
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

## CLI Reference

| Command | Description |
|---------|-------------|
| `par run --provider <openai\|anthropic> --api-key <key> --api-base <url> --model <model>` | 交互式REPL |
| `par invoke --agent-id <id> --input <json>` | 单次调用 |
| `par task submit/status/cancel --task-id <id>` | 异步任务管理 |
| `par workflow submit/status/cancel --run-id <id>` | 工作流执行 |

所有命令支持 `--persistence sqlite\|postgres` 和 `--db-uri <uri>` 配置持久化后端。

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
| `par_core` | Core types, ReAct engine, runtime, SDK, expression evaluator, state machine, workflow engine, context manager |
| `par_eio` | Eio-based event bus with dead-letter queue (DLQ) support |
| `par_sqlite` | SQLite persistence backend for development |
| `par_postgres` | PostgreSQL persistence backend for production |
| `par_openai` | OpenAI and OpenAI-compatible LLM provider |
| `par_anthropic` | Anthropic Messages API provider |
| `par_middleware` | Retry, rate limiting, PII masking, validation, logging, timeout middleware |
| `par_cli` | Command-line interface (`par`) |

## Project Structure

```
par/
+-- bin/              CLI entry point
+-- lib/
|   +-- par_core/      Core types, engine, runtime, SDK
|   +-- par_eio/       Event bus (Eio-based)
|   +-- par_sqlite/    SQLite persistence
|   +-- par_postgres/  PostgreSQL persistence
|   +-- par_openai/    OpenAI LLM provider
|   +-- par_anthropic/ Anthropic LLM provider
|   +-- par_middleware/ Built-in middleware
|   +-- par_cli/       CLI implementation
+-- test/              Unit and integration tests
+-- examples/          Example agents and workflows
+-- schema/            Database schemas
```

## Dependencies

OCaml 5.4+, dune 3.23+, cohttp-eio, lambdasoup, tls-eio, ca-certs, postgresql（PG后端可选）

## Project Size

- 约6000行代码
- 111个测试用例

## License

MIT