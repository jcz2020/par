# How-to: 错误处理模式

PAR 的所有错误最终是 `Types.error_category` 之一：

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

每种错误的语义和处理方式不同。

## 模式 1: tool 错误——重试 vs 上报

工具 handler 返回 `handler_result`：

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

**判断重试**：看 `retryable` 字段或 `category`：

| 错误类型 | retryable? | 推荐处理 |
|---------|-----------|---------|
| `Timeout` | true | 重试（如果是网络超时）|
| `Rate_limited` | true | 退避后重试 |
| `External_failure` | true | 立即重试 1-2 次 |
| `Invalid_input` | **false** | **不重试**——schema 错，再试也是错 |
| `Permission_denied` | **false** | **不重试**——policy 拒绝，重试也是拒绝 |
| `Internal` | 看情况 | 看 `message`；如果是 transient 可重试 |

## 模式 2: LLM 错误——退避

OpenAI / Anthropic 在高峰时段会 429。`lib/middleware/rate_limit.ml` 自动处理（per-token 限流）。HTTP 5xx 错误推荐用 `retry_policy` middleware（`lib/middleware/retry.ml`）：

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

3 次重试，指数退避 1s → 2s → 4s，最长 30s。**注意 `retry_on` 列表**——不要 retry `Invalid_input`（没意义）或 `Internal`（可能是 bug，越 retry 越糟）。

## 模式 3: 取消传播

PAR 整个栈用 `Eio.Switch.t` 做协作式取消。`Runtime.close` 触发整个 switch cancel：

```ocaml
Eio.Switch.run (fun sw ->
  let rt = Runtime.create ~config ... sw in
  (* ... 启动长跑 task ... *)
  let cancel_switch = Eio.Switch.empty () in  (* 嵌套 switch *)
  Eio.Fiber.fork ~sw:cancel_switch (fun () ->
    ignore (Runtime.invoke rt "agent-1" "long task" : _));
  Eio.Time.sleep (Time.Span.of_sec 30.0);
  Eio.Switch.turn_off cancel_switch;  (* 中断 agent-1 *)
  (* ... 继续做别的 ... *)
)
```

tool handler 内部如果用 `Cancellation.with_timeout` 包裹，会自动响应 cancel。

## 模式 4: 自定义错误元数据

`Error { ...; metadata = [...] }` 的 `metadata` 字段是 `[("key", json)]` 列表，挂在 event bus 持久化上，便于 debug：

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

下游监控可以 `event.metadata[0]` 拿到 `request_id` 去 OpenAI dashboard 查。

## 模式 5: 不要 swallow 错误

```ocaml
(* 错误：吞掉所有错误 *)
match Runtime.invoke rt "agent" input with
| Ok result -> process result
| Error _ -> ()  (* 😱 静默失败 *)

(* 正确：区分错误 *)
match Runtime.invoke rt "agent" input with
| Ok result -> process result
| Error e ->
  match e with
  | Timeout -> retry_with_backoff ()
  | Rate_limited -> sleep 60.0; retry ()
  | Invalid_input msg -> log_input_error msg; fail ()
  | _ -> failwith (Printf.sprintf "unhandled: %s" (error_to_string e))
```

`lib/core/types.ml` 的 6 个 error_category 变体是**穷尽**的——match 漏一个会 OCaml warning。**用 exhaustiveness 做兜底**：

```ocaml
| _ -> failwith "unreachable"  (* 但加个 [ WARNING ] log 帮你 debug *)
```

## 模式 6: 用事件总线做可观测性

不要靠日志。订阅 `Bash_invoked` / `Bash_completed` / `Tool_failed` 这些事件，自动 metric 化：

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

[v0.3.0+ 健康检查 API](https://...) `Runtime.metrics_snapshot` 也可用——不用自己订阅事件。
