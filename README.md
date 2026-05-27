# P-A-R — Programmable Agent Runtime

A modular, type-safe agent runtime for OCaml 5.4+ with multi-provider LLM support, workflow orchestration, and persistent state management.

[![Build Status](https://img.shields.io/badge/build-placeholder-yellow)](https://github.com/username/par)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Features

- Multi-provider LLM: OpenAI, Anthropic, Ollama, and custom providers via a unified interface
- ReAct agent loop with configurable middleware pipeline
- Workflow engine supporting Sequential, Parallel, Conditional, and Map-reduce steps
- 6 built-in middleware: logging, timeout, retry, rate limiting, PII masking, validation
- Context management: Truncate, Summarize, and Sliding window strategies
- Dual persistence backends: SQLite for development, PostgreSQL for production
- Cooperative cancellation via Eio fibers
- CLI tool with run, invoke, task, and workflow subcommands
- Safe expression evaluator for conditional routing

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
```

## Quick Start

```bash
# Prerequisites: OCaml 5.4+, opam 2.1+
opam switch create . 5.4.1
eval $(opam env)
opam install . --deps-only

# Build
dune build

# Run tests
dune runtest

# Run the example
dune exec examples/basic_agent.exe

# Use the CLI
dune exec par -- run --config runtime_config.json
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
| `par run --config <path>` | Start an interactive REPL with the runtime |
| `par invoke --agent <id> --input <json>` | Single-shot agent invocation |
| `par task submit --agent <id> --input <json>` | Submit a task to the queue |
| `par task status --task-id <id>` | Check task status |
| `par task cancel --task-id <id>` | Cancel a running task |
| `par workflow submit --definition <file>` | Submit a workflow definition |
| `par workflow status --run-id <id>` | Check workflow run status |
| `par workflow cancel --run-id <id>` | Cancel a workflow run |

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

## Configuration

```json
{
  "persistence": "sqlite",
  "db_path": "par.db",
  "event_bus": {
    "queue_size": 1000,
    "retry_attempts": 3,
    "dead_letter_queue": true
  },
  "default_quota": {
    "max_steps": 50,
    "max_time_seconds": 300
  },
  "shutdown": {
    "grace_period_seconds": 10,
    "force_timeout_seconds": 30
  },
  "llm_providers": [
    {
      "name": "openai",
      "provider": "openai",
      "model": "gpt-4",
      "api_key_env": "OPENAI_API_KEY"
    },
    {
      "name": "anthropic",
      "provider": "anthropic",
      "model": "claude-3-sonnet-20240229",
      "api_key_env": "ANTHROPIC_API_KEY"
    }
  ],
  "middleware": ["logging", "timeout", "retry"],
  "context_strategy": {
    "type": "sliding_window",
    "max_tokens": 8192
  }
}
```

## License

MIT