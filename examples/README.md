<!-- language: en -->
# Examples

Standalone programs and workflow definitions that demonstrate PAR's SDK.

> **v0.6.7:** This repo's CLI was removed; workflow examples are loaded programmatically via the SDK below. For an interactive Agent, see [par-code](https://github.com/jcz2020/par-code).

## OCaml Programs

### basic_agent.ml

A minimal agent that registers an `echo` tool and an agent, then confirms registration.
Shows the core `Runtime.create` → `register_tool` → `register_agent` → `Runtime.close` lifecycle.

```bash
dune exec examples/basic_agent.exe
```

### otel_tracing.ml

OpenTelemetry tracing integration. Wraps tool calls and agent invocations in spans so you can pipe traces into Jaeger, Zipkin, or any OTLP-compatible backend.

```bash
dune exec examples/otel_tracing.exe
```

## Workflow Definitions

### sequential_workflow.json

A sequential workflow: steps execute one after another, each receiving the output of the previous step.
Use it as a template for multi-step pipelines.

**Load via SDK (OCaml):**
```ocaml
open Par
let () = Eio_main.run (fun _ ->
  Eio.Switch.run (fun sw ->
    let config = ... in
    match Runtime.create ~config sw with
    | Ok rt -> ignore (Runtime.close rt)
    | Error e -> ...))
```

See [`bindings/python/examples/basic_agent.py`](../bindings/python/examples/basic_agent.py) for the Python equivalent.

### test_workflow.json

A lightweight test workflow used in the CI suite. Demonstrates the minimal JSON shape the workflow engine accepts. Load it the same way as `sequential_workflow.json` above.

---

For the full walkthrough, see [docs/quickstart.md](../docs/quickstart.md).
