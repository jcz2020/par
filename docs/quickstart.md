<!-- language: en -->

**English** · [简体中文](zh/quickstart.md)

> Translated to English for v0.3.2. Source-of-truth: the OCaml modules in lib/ and the README.

# PAR Quickstart

> From scratch to a working LLM agent with tool calls in 30 minutes using OCaml.

## What is PAR?

PAR (Programmable Agent Runtime) is a modular, type-safe agent runtime for OCaml 5.4+.
It includes a ReAct reasoning engine, OpenAI and Anthropic LLM providers (plus any OpenAI-compatible endpoint),
20 built-in tools (including a type-safe bash tool), an MCP client (stdio + HTTP/SSE), workflow orchestration, and SQLite/PostgreSQL persistence.

## Prerequisites

| Dependency | Minimum version | Check command |
|------------|----------------|---------------|
| OCaml | 5.4+ | `ocaml --version` |
| opam | 2.1+ | `opam --version` |
| dune | 3.16+ | `dune --version` |
| API Key | OpenAI or Anthropic | — |

If you don't have an OCaml environment, install it via opam:

```bash
bash -c "sh <(curl -fsSL https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh)"
opam init --disable-sandboxing --bare
opam switch create 5.4.0
eval $(opam env)
```

## Install

Build from source (recommended):

```bash
git clone https://github.com/jcz2020/par.git
cd par
opam install --deps-only .    # install dependencies
dune build                     # compile
dune install                   # install into opam environment
```

After installation you get two packages:
- `par` — the SDK library
- `par_cli` — the CLI tool (`par`, `par config`, `par ask`)

## Project setup

Create a new OCaml project. You need at least three files.

**dune-project**:

```
(lang dune 3.16)
(name my_par_app)

(executable
 (name main)
 (libraries par eio eio_main)
 (preprocess (pps ppx_deriving_yojson)))
```

**dune**:

```
(executable
 (name main)
 (libraries par eio eio_main)
 (preprocess (pps ppx_deriving_yojson)))
```

**main.ml** — start with a skeleton, we'll fill it in later:

```ocaml
let () = print_endline "Hello PAR"
```

Run it to verify the environment:

```bash
dune exec ./main.exe   # output: Hello PAR
```

## Configure an LLM provider

PAR's CLI uses a JSON configuration file stored at `~/.par/config.json`.
The easiest way to create it is through the guided wizard:

```bash
par config
```

The wizard prompts for provider, API key, model name, and other fields.
If you edit the config file manually, the format is:

**OpenAI (including any OpenAI-compatible endpoint)**:

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

**OpenAI-compatible endpoint (e.g. local vLLM, llama.cpp server)**:

```json
{
  "provider": "openai",
  "api_key": "your-api-key",
  "api_base": "http://localhost:8000/v1",
  "model": "my-model",
  "persistence": "sqlite",
  "db_uri": null,
  "temperature": 0.7,
  "system_prompt": "You are a helpful assistant."
}
```

**Anthropic**:

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

You can also pass the API key via environment variables (useful for SDK usage):

```bash
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
```

## Write your first agent

Here is a complete agent using the SDK. Replace `main.ml` with:

```ocaml
open Par

let () =
  (* 1. Runtime configuration *)
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

  (* 2. Start the Eio event loop *)
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun switch ->
      (* 3. Create the runtime *)
      match Runtime.create ~config switch with
      | Error _err ->
        Printf.eprintf "Failed to create runtime\n"
      | Ok rt ->
        (* 4. Register an echo tool *)
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
        (* 5. Define the agent configuration *)
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
        (* 6. Register and confirm *)
        ignore (Runtime.register_agent rt agent);
        Printf.printf "Agent registered: %s\n" agent.id;
        ignore (Runtime.close rt)
    )
  )
```

Key steps explained:

1. **Runtime configuration** — `runtime_config` uses SQLite for persistence; event bus and quotas use defaults.
2. **Eio event loop** — PAR is built on Eio's structured concurrency; all code runs inside `Eio_main.run`.
3. **Create runtime** — `Runtime.create` returns `Result.t`; you must handle the error branch.
4. **Register tool** — `register_tool` takes a name, description, JSON Schema, and handler function; returns a `tool_binding`.
5. **Agent configuration** — `agent_config` specifies the system prompt, model parameters, tool list, max iterations, and more.
6. **Register agent** — `register_agent` adds the configuration to the runtime's agent table.

## Run the agent

```bash
dune exec ./main.exe
# output: Agent registered: echo-agent
```

To actually converse with the agent, configure an LLM provider and call `Runtime.invoke`:

```ocaml
(* Add after Runtime.register_agent rt agent *)
match Runtime.invoke rt ~agent_id:"echo-agent"
  ~message:"Hello, echo!" ()
with
| Ok resp ->
  (match resp.Types.text with
   | Some txt -> Printf.printf "Response: %s\n" txt
   | None -> Printf.printf "No text response\n")
| Error e -> Printf.eprintf "Error: %s\n" (Printexc.to_string (Failure ""))
```

## Using the CLI

PAR ships an interactive REPL for zero-code experimentation.

**Configuration**:

```bash
par config
# follow the prompts for provider, API key, model, etc.
```

**Interactive conversation**:

```bash
par
# > What is 2 + 3?
# Agent: 2 + 3 = 5
# > ^D (Ctrl+D to exit)
```

**Single-shot query**:

```bash
par ask "What is the capital of France?"
# Agent: The capital of France is Paris.
```

The CLI automatically registers all 20 built-in tools and supports command-line overrides:

```bash
par ask --provider anthropic --model claude-sonnet-4-20250514 "Hello"
par ask --temperature 0.3 "Explain quantum computing"
```

## Using built-in tools

In the SDK, access all built-in tool bindings via `Par.Builtin_tools`:

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
        (* Get all built-in tools *)
        let net = Eio.Stdenv.net env in
        let tools = Builtin_tools.builtin_tools ~switch ~net in
        List.iter (fun (tb : Types.tool_binding) ->
          Tool_registry.register
            (Runtime.tool_registry rt) tb.descriptor tb.handler
        ) tools;
        let descriptors =
          List.map (fun (tb : Types.tool_binding) -> tb.descriptor) tools
        in
        (* Create an agent with the calculator tool *)
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
          tools = descriptors;  (* all built-in tools *)
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

Built-in tools include: `calculator`, `get_time`, `echo`, `generate_uuid`,
`hash_text`, `generate_password`, `string_stats`, `json_format`,
`convert_temperature`, `url_encode`, `fetch_url`, `read_webpage`, `web_search`,
`read`, `ls`, `find`, `grep`, `write`, `edit`, `bash`.

## Persistence: SQLite

PAR uses SQLite persistence by default. Configure it in `runtime_config`:

```ocaml
let config = {
  Types.persistence = `Sqlite "par.db";  (* file path *)
  (* ... other fields ... *)
} in
```

The database file is created automatically at runtime if it doesn't exist. It stores task state, event logs, and workflow checkpoints.

Switch to PostgreSQL (recommended for production):

```ocaml
let config = {
  Types.persistence = `Postgresql "postgresql://localhost/par";
  (* ... other fields ... *)
} in
```

Note: the PostgreSQL backend requires installing the `par_postgres` opam package separately and recompiling.

## Troubleshooting

| Symptom | Cause | Solution |
|---------|-------|----------|
| `Unbound module Types` | Missing `open Par` | Add `open Par` at the top of the file |
| `Unbound module Par` | par library not found | Confirm `(libraries par ...)` is declared in dune-project |
| `Connection refused` | Missing API key or network issue | Check `~/.par/config.json` or environment variables |
| `LLM not initialized` | SDK mode without `~llm` parameter | Use CLI mode (`par ask`) which handles LLM init automatically |
| `Error creating OpenAI provider` | API key format error | Confirm key starts with `sk-` (OpenAI) or `sk-ant-` (Anthropic) |
| `dune build` fails | Dependencies not installed | Run `opam install --deps-only .` |
| `ppx_deriving_yojson` error | Missing preprocessor | Add `(preprocess (pps ppx_deriving_yojson))` to the dune file |

## Next steps

- [agent.md](sdk/agent.md) — Agent configuration deep dive: `model_config` fields, `context_strategy`, `retry_policy`
- [workflow.md](sdk/workflow.md) — Workflow orchestration: sequential, parallel, conditional branching, map-reduce
- [middleware.md](sdk/middleware.md) — Middleware: logging, timeout, retry, rate limiting, PII masking, data validation
- [examples/](../examples/) — More complete examples (basic_agent.ml, otel_tracing.ml)
