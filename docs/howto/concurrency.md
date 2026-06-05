<!-- language: en -->

> Translated to English for v0.3.2.

# How-to: Concurrency Patterns

PAR has three concurrency layers, from the outside in:

## 1. Multiple agents in parallel

The outermost layer — independent agent tasks running simultaneously:

```ocaml
Eio.Switch.run (fun sw ->
  let rt = Runtime.create ~config ... sw in
  (* Launch 3 independent agents *)
  let results = Eio.Fiber.all [
    fun () -> Runtime.invoke rt "agent-a" "task 1";
    fun () -> Runtime.invoke rt "agent-b" "task 2";
    fun () -> Runtime.invoke rt "agent-c" "task 3";
  ] in
  (* results is [(result_a, error_b, result_c) ...] *)
  List.iter (function
    | Ok r -> Printf.printf "OK: %s\n" r
    | Error e -> Printf.printf "FAIL: %s\n" (error_to_string e)) results
)
```

**Note**: `Eio.Fiber.all` is structured concurrency — if one fiber fails, the switch cancels all of them. If you want fire-and-forget isolation, use `Eio.Fiber.fork` and manage each lifecycle independently.

## 2. Multiple invokes on the same agent

If the same agent receives multiple independent questions (e.g. batch processing):

```ocaml
let inputs = ["question 1"; "question 2"; ...; "question N"] in
let tasks = List.map (fun input ->
  fun () -> Runtime.invoke rt agent_id input
) inputs in
let results = Eio.Fiber.all tasks in
```

`Runtime` has an internal `task_semaphore` (`runtime_config.default_quota.max_concurrent_tasks`) that automatically throttles to prevent overload.

## 3. Parallel tool calls (v0.3.0+)

When the LLM returns multiple `tool_call`s in a single response (e.g. "search then fetch"), PAR executes them **in parallel** by default:

```ocaml
(* runtime_config.parallel_tool_execution = true (default) *)
(* One LLM response triggers concurrent tool calls, then results are collected serially *)
```

**Disable it** (if tool calls in the LLM response have dependencies):

```ocaml
let config = {
  ...
  parallel_tool_execution = false;  (* serial tool execution *)
  ...
}
```

**Fine-grained control** — set `concurrency_limit` per tool:

```ocaml
let my_tool = { descriptor = {
  name = "expensive_db_query";
  ...
  concurrency_limit = Some 2;  (* max 2 concurrent invocations *)
}; handler = ... } in
Runtime.register_tool rt my_tool;
```

## 4. Bash tool concurrency (v0.3.1)

The bash tool defaults to `concurrency_limit = Some 4` (max 4 concurrent bash calls per agent). This is intentional in v0.3.1 — bash subprocesses are heavy, and 4 is enough for typical LLM workflow parallelism.

**Added in v0.3.1**: the `sandboxed_path` abstraction ensures different bash calls do not conflict on `cwd`.

## 5. Rate limiting

`lib/middleware/rate_limit.ml` provides token-bucket rate limiting:

```ocaml
(* Global: max 60 LLM calls per second *)
let config = {
  ...
  middleware = [Par_middleware.rate_limit ~max_requests:60 ~window_seconds:1.0 ()];
}
```

Or per-agent:

```ocaml
let agent = {
  ...
  middleware = [Par_middleware.rate_limit ~max_requests:10 ~window_seconds:1.0 ()];
}
```

## 6. Concurrency inside workflows

`lib/core/workflow.ml` supports sequential / parallel / map-reduce steps:

```ocaml
let workflow = {
  id = "fan-out-fan-in";
  steps = [
    Parallel [
      Tool_call { tool_name = "fetch_url"; input = `Assoc [...url_a...] };
      Tool_call { tool_name = "fetch_url"; input = `Assoc [...url_b...] };
      Tool_call { tool_name = "fetch_url"; input = `Assoc [...url_c...] };
    ];
    Map_reduce {
      over = Expression.Variable "results";
      step = Tool_call { tool_name = "summarize"; input = ... };
      reduce = Expression.Call (Variable "concat", [Variable "acc"; Variable "item"]);
    };
  ];
}
```

`Parallel` runs concurrently, `Map_reduce` reduces serially. See [docs/sdk/workflow.md](sdk/workflow.md) for details.

## Anti-patterns

- **Do not** use `Thread.create` inside tool handlers — it escapes Eio switch cancellation
- **Do not** use `Lwt` or `Async` — PAR's entire stack is Eio; mixing in Lwt will deadlock
- **Do not** set `concurrency_limit = None` (unless you are 100% sure there is no risk) — OOM hazard
