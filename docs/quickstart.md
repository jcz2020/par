<!-- language: en -->

**English** · [简体中文](https://github.com/jcz2020/par/blob/main/docs/zh/quickstart.md)

# PAR Quickstart

> From scratch to a working LLM agent with tool calls in 30 minutes using OCaml.

## What is PAR?

PAR (Programmable Agent Runtime) is a modular, type-safe agent runtime for OCaml 5.4+.
It includes a ReAct reasoning engine, OpenAI and Anthropic LLM providers (plus any OpenAI-compatible endpoint),
23 built-in tools (including a type-safe bash tool and 3 memory tools), an MCP client (stdio + HTTP/SSE), workflow orchestration, and SQLite persistence.

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

**Python binding** (Linux x86_64 + macOS arm64):

```bash
pip install par-runtime
```

**OCaml SDK**:

```bash
opam pin add par https://github.com/jcz2020/par.git
```

**Interactive SDK wizard** (detects system, picks Python or OCaml):

```bash
curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
```

**Build from source**:

```bash
git clone https://github.com/jcz2020/par.git
cd par
opam install --deps-only .    # install dependencies
dune build                     # compile
dune install                   # install into opam environment
```

After installation you get one opam package and one PyPI package:
- `par` — the SDK library (OCaml)
- `par-runtime` — the Python binding (PyPI)

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

PAR is configured through the SDK. You need an API key and a persistence backend.

### API key

Set your API key as an environment variable:

```bash
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
```

### Persistence

When creating a `runtime_config`, specify the persistence backend using the object form:

```json
{"persistence": {"tag": "sqlite", "contents": ":memory:"}}
```

The `":memory:"` value uses an in-memory database (handy for testing). For persistent storage, swap in a file path like `"par.db"`.

### OCaml SDK

Configure providers directly in the `runtime_config` record. The typed record gives you compile-time safety on every field:

```ocaml
let config = {
  Types.persistence = `Sqlite ":memory:";  (* or `Sqlite "par.db"` for file-based *)
  (* ... other fields use defaults ... *)
} in
```

### Python binding

Pass a JSON configuration string when creating the runtime:

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
`read`, `ls`, `find`, `grep`, `write`, `edit`, `bash`,
`recall_memory`, `remember_memory`, `search_history`.

## Persistence: SQLite

PAR uses SQLite persistence by default. Configure it in `runtime_config`:

```ocaml
let config = {
  Types.persistence = `Sqlite "par.db";  (* file path *)
  (* ... other fields ... *)
} in
```

The database file is created automatically at runtime if it doesn't exist. It stores task state, event logs, and workflow checkpoints. SQLite is the only persistence backend; no separate configuration is needed.

## Troubleshooting

| Symptom | Cause | Solution |
|---------|-------|----------|
| `Unbound module Types` | Missing `open Par` | Add `open Par` at the top of the file |
| `Unbound module Par` | par library not found | Confirm `(libraries par ...)` is declared in dune-project |
| `Connection refused` | Missing API key or network issue | Verify environment variables (`OPENAI_API_KEY` / `ANTHROPIC_API_KEY`) are set correctly |
| `LLM not initialized` | No LLM provider configured | Ensure `llm_providers` is set in `runtime_config`, or pass `~llm` when calling `Runtime.invoke` |
| `Error creating OpenAI provider` | API key format error | Confirm key starts with `sk-` (OpenAI) or `sk-ant-` (Anthropic) |
| `dune build` fails | Dependencies not installed | Run `opam install --deps-only .` |
| `ppx_deriving_yojson` error | Missing preprocessor | Add `(preprocess (pps ppx_deriving_yojson))` to the dune file |

## What's new in v0.8.x

PAR has added several capabilities since v0.7. Here's a quick tour.

**HITL approval** (v0.8.0) lets agents pause mid-execution for human approval. Approval state persists to SQLite, so it survives process restarts. External systems can resolve approvals via webhook. See [HITL API](sdk/hitl.md).

**Parallel multi-agent dispatch** (v0.8.0) runs N agents concurrently with typed merge, per-agent workspace isolation, and per-agent approval handler overrides. Call `Runtime.invoke_parallel` to fan out work and collect merged results. See [Parallel Dispatch](sdk/parallel.md).

**Memory service** (v0.7.1, enhanced v0.8.1) provides cross-session agent memory with FTS5 keyword search. Three builtin tools (`recall_memory`, `remember_memory`, `search_history`) give agents direct access. Scoped per-session via `invoke_context`. See [Memory API](sdk/memory.md).

**Skills system** (v0.8.1) lets you drop a `skill.md` in `~/.par/skills/<id>/` and have it auto-activate during `Runtime.invoke` based on trigger conditions (Auto / Manual / Keyword). Per-call mode switching via the `?skills` parameter. See [Skills API](sdk/skills.md).

**Think_tag_strip middleware** (v0.8.2) automatically cleans reasoning model tags from LLM output. Useful with models that emit `<think>` blocks or similar thinking markers. See [Middleware](sdk/middleware.md).

## Next steps

- [HITL API](sdk/hitl.md) — suspend-resume approval, cross-process persistence
- [Parallel Dispatch](sdk/parallel.md) — parallel multi-agent dispatch, typed merge
- [Memory API](sdk/memory.md) — cross-session agent memory with FTS5 search
- [Skills API](sdk/skills.md) — reusable prompt + tool bundles with triggers
- [Streaming API](sdk/streaming.md) — token streaming, tool call events
- [Agent API](sdk/agent.md) — `agent_config`, `Runtime.invoke`, tool handlers deep dive
- [Workflow API](sdk/workflow.md) — sequential, parallel, conditional, map-reduce
- [Middleware](sdk/middleware.md) — Logging, Retry, Rate_limit, Timeout, PII_mask, Think_tag_strip
- [Tutorial 01: RAG Q&A Bot](tutorials/01-rag-qa-bot.md) — add a knowledge base to your agent
- [Tutorial 02: Streaming UI](tutorials/02-streaming-ui.md) — see tokens stream live into a TTY UI
- [examples/](https://github.com/jcz2020/par/blob/main/examples/) — complete example code
