<!-- language: en -->
# Examples

Standalone programs and workflow definitions that demonstrate PAR's SDK.

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

```bash
par ask --workflow examples/sequential_workflow.json
```

### test_workflow.json

A lightweight test workflow used in the CI suite. Demonstrates the minimal JSON shape the workflow engine accepts.

```bash
par ask --workflow examples/test_workflow.json
```

---

For the full walkthrough, see [docs/quickstart.md](../docs/quickstart.md).
