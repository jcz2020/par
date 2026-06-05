<!-- language: en -->

**English** · [简体中文](../zh-CN/howto/error-handling.md)

> Translated to English for v0.3.2.

# How-to: Error Handling Patterns

Every error in PAR is ultimately one of the `Types.error_category` variants:

```ocaml
type error_category =
  | Timeout
  | Invalid_input of string
  | External_failure of string
  | Rate_limited
  | Permission_denied of string
  | Internal of string
[@@deriving yojson]
```

Each category has different semantics and requires a different handling strategy.

## Pattern 1: Tool errors — retry vs. escalate

Tool handlers return a `handler_result`:

```ocaml
type handler_result =
  | Success of Yojson.Safe.t
  | Error of {
      category : error_category;
      message : string;
      retryable : bool;
      metadata : (string * Yojson.Safe.t) list;
    }
```

**Decide whether to retry** based on the `retryable` field or `category`:

| Error category | Retryable? | Recommended handling |
|---------------|------------|---------------------|
| `Timeout` | true | Retry (if it is a network timeout) |
| `Rate_limited` | true | Retry with backoff |
| `External_failure` | true | Immediate retry 1-2 times |
| `Invalid_input` | **false** | **Do not retry** — the schema is wrong, retrying won't help |
| `Permission_denied` | **false** | **Do not retry** — policy rejection, retrying is still rejection |
| `Internal` | depends | Check `message`; retry if transient |

## Pattern 2: LLM errors — backoff

OpenAI / Anthropic return 429 during peak traffic. `lib/middleware/rate_limit.ml` handles this automatically (per-token throttling). For HTTP 5xx errors, use the `retry_policy` middleware (`lib/middleware/retry.ml`):

```ocaml
let config = {
  ...
  llm_providers = [...];
  retry_policy = Some {
    max_attempts = 3;
    initial_delay = 1.0;
    backoff = Exponential { base = 2.0; max_delay = 30.0 };
    retry_on = [Timeout; Rate_limited; External_failure];
    jitter = Some 0.1;
  };
  ...
}
```

3 retries, exponential backoff 1s → 2s → 4s, max 30s. **Note the `retry_on` list** — do not retry `Invalid_input` (pointless) or `Internal` (could be a bug; more retries makes it worse).

## Pattern 3: Cancellation propagation

PAR's entire stack uses `Eio.Switch.t` for cooperative cancellation. `Runtime.close` triggers the entire switch to cancel:

```ocaml
Eio.Switch.run (fun sw ->
  let rt = Runtime.create ~config ... sw in
  (* ... start a long-running task ... *)
  let cancel_switch = Eio.Switch.empty () in  (* nested switch *)
  Eio.Fiber.fork ~sw:cancel_switch (fun () ->
    ignore (Runtime.invoke rt "agent-1" "long task" : _));
  Eio.Time.sleep (Time.Span.of_sec 30.0);
  Eio.Switch.turn_off cancel_switch;  (* interrupt agent-1 *)
  (* ... continue with other work ... *)
)
```

If a tool handler wraps its work with `Cancellation.with_timeout`, it automatically responds to cancellation.

## Pattern 4: Custom error metadata

The `metadata` field on `Error { ...; metadata = [...] }` is a `[("key", json)]` association list. It gets persisted on the event bus for debugging:

```ocaml
Error {
  category = External_failure "API timeout";
  message = "openai call timed out after 30s";
  retryable = true;
  metadata = [
    ("http_status", `Int 504);
    ("request_id", `String "req_abc123");
    ("endpoint", `String "/v1/chat/completions");
  ];
}
```

Downstream monitoring can read `event.metadata[0]` to get the `request_id` and look it up in the provider dashboard.

## Pattern 5: Do not swallow errors

```ocaml
(* Wrong: silently discard all errors *)
match Runtime.invoke rt "agent" input with
| Ok result -> process result
| Error _ -> ()  (* silent failure *)

(* Right: distinguish error categories *)
match Runtime.invoke rt "agent" input with
| Ok result -> process result
| Error e ->
  match e with
  | Timeout -> retry_with_backoff ()
  | Rate_limited -> sleep 60.0; retry ()
  | Invalid_input msg -> log_input_error msg; fail ()
  | _ -> failwith (Printf.sprintf "unhandled: %s" (error_to_string e))
```

The 6 `error_category` variants in `lib/core/types.ml` are **exhaustive** — missing one produces an OCaml warning. **Use exhaustiveness as a safety net**:

```ocaml
| _ -> failwith "unreachable"  (* but add a [WARNING] log to help debug *)
```

## Pattern 6: Use the event bus for observability

Do not rely on logs alone. Subscribe to `Bash_invoked` / `Bash_completed` / `Tool_failed` events and automatically export metrics:

```ocaml
Event_bus.subscribe rt.event_bus (function
  | Bash_invoked { argv; risk; _ } ->
    Metrics.increment_tool_call "bash" ~tags:["risk", risk]
  | Bash_completed { exit_code; duration; _ } ->
    Metrics.record_tool_latency "bash" duration;
    if exit_code <> 0 then Metrics.increment_tool_error "bash"
  | _ -> ()
);
```

The `Runtime.metrics_snapshot` API (v0.3.0+) is also available — you don't have to subscribe to events manually.
