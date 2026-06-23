<!-- language: en -->

**English** · [简体中文](../zh/sdk/middleware.md)

> Translated to English for v0.3.2. Source-of-truth: the OCaml types in lib/middleware/.

# Middleware API Reference

This document describes the middleware pipeline of a runtime created with `Runtime.create`, including the 7 built-in middleware and a guide for writing custom middleware.

## Middleware concepts

Middleware is defined through the `middleware_hook` type, which inserts interceptors for cross-cutting concerns into the agent execution pipeline. The Engine composes the middleware chain using a "Russian Doll" pattern, with `List.fold_right` guaranteeing that middleware earlier in the list wraps middleware later in the list.

### middleware_hook

```ocaml
type middleware_hook = {
  name : string;
  on_before_llm : (conversation -> conversation option) option;
  on_after_llm : (llm_response -> llm_response option) option;
  on_before_tool : (tool_call -> tool_call option) option;
  on_after_tool : (tool_call * handler_result -> handler_result option) option;
  on_error : (error_category -> handler_result option) option;
}
```

Each hook returns `Some modified_value` to indicate the value was modified, or `None` to pass it through.

Middleware is declared in the `agent_config.middleware` list, wrapping from outer to inner in list order.

## Logging

Logs every LLM and tool call. Zero configuration, works out of the box.

```ocaml
val Logging.logging : Types.middleware_hook
```

### Log contents

| Hook | Level | Content |
|------|------|------|
| `on_before_llm` | info | message count |
| `on_after_llm` | info | finish_reason, model name |
| `on_before_tool` | info | tool name and arguments |
| `on_after_tool` | info/warn | info on success, warn on failure (with error message) |
| `on_error` | err | error information |

### Usage

```ocaml
let agent = {
  agent with
  middleware = [ Logging.logging ];
}
```

## Retry

Configurable exponential backoff retry middleware that handles transient errors in LLM and tool calls.

```ocaml
type retry_config = {
  max_attempts : int;     (* Maximum retry attempts, default 3 *)
  base_delay : float;    (* Base delay in seconds, default 2.0 *)
  max_delay : float;     (* Maximum delay in seconds, default 30.0 *)
}

val Retry.default_retry_config : retry_config

val Retry.retry :
  ?config:retry_config ->
  ?policy:Types.retry_policy ->
  unit -> Types.middleware_hook
```

### retry_policy type

```ocaml
type retry_policy = {
  max_attempts : int;
  initial_delay : float;
  backoff : backoff_strategy;         (* Exponential / Fixed / Linear *)
  retry_on : retryable_condition list; (* Timeout / Rate_limited / External_failure / ... *)
  jitter : float option;               (* Random jitter factor *)
}

type backoff_strategy =
  | Exponential of { base : float; max_delay : float }
  | Fixed of float
  | Linear of { increment : float; max_delay : float }

type retryable_condition =
  | Timeout | Rate_limited | External_failure
  | Connection_error | Any_retryable
```

### Usage example

```ocaml
(* Use default configuration *)
let retry_hook = Retry.retry ()

(* Custom configuration *)
let retry_hook = Retry.retry ~config:{
  max_attempts = 5;
  base_delay = 1.0;
  max_delay = 60.0;
} ()

(* Use the full retry_policy for finer control *)
let retry_hook = Retry.retry ~policy:{
  max_attempts = 4;
  initial_delay = 1.0;
  backoff = Exponential { base = 2.0; max_delay = 30.0 };
  retry_on = [ Types.Timeout; Types.Rate_limited ];
  jitter = Some 0.1;
} ()
```

The default `retry_config` produces an exponential backoff strategy: `delay = min(base^attempt, max_delay)`.

## Rate_limit

Sliding window rate limit middleware that controls LLM request frequency.

```ocaml
type rate_limit_config = {
  max_requests : int;    (* Max requests per window, default 60 *)
  window : float;       (* Window duration in seconds, default 60.0 *)
}

val Rate_limit.default_rate_limit_config : rate_limit_config

val Rate_limit.rate_limit :
  ?config:rate_limit_config ->
  unit -> Types.middleware_hook
```

### Behavior

- `on_before_llm`: checks the current window's request count, flags the conversation metadata with `("rate_limited", true)` when the limit is exceeded
- `on_error`: when a `Rate_limited` error is received, computes `retry_after` and attaches it to the error metadata

### Usage example

```ocaml
(* Limit to 30 requests per minute *)
let rate_hook = Rate_limit.rate_limit ~config:{
  max_requests = 30;
  window = 60.0;
} ()
```

## Timeout

Unifies timeout errors into a standard format.

```ocaml
val Timeout.timeout_middleware : default_timeout:float -> Types.middleware_hook
```

### Behavior

- `on_before_tool`: pass-through (placeholder)
- `on_error`: converts `Timeout` errors into `Error` results with a standard message

Use with `Cancellation.with_timeout` for actual timeout control:

```ocaml
Cancellation.with_timeout 30.0 token (fun token ->
  Engine.run_agent token agent message llm registry)
```

## Validation

JSON input/output validation middleware that ensures LLM responses and tool arguments have the correct format.

```ocaml
val Validation.validation :
  ?strict:bool ->   (* Default false: lenient mode *)
  unit -> Types.middleware_hook
```

### Behavior

| Mode | on_after_llm | on_before_tool | on_after_tool |
|------|-------------|----------------|---------------|
| Lenient (`strict=false`) | warn and supply an empty string when text and tool_calls are missing | non-object arguments are auto-replaced with `{}` | -- |
| Strict (`strict=true`) | same as above, but with err level | non-object arguments are flagged as invalid, `on_after_tool` returns an error | returns an error result when arguments were flagged invalid |

### Usage example

```ocaml
(* Lenient mode for development *)
let validation_hook = Validation.validation ()

(* Strict mode for production *)
let validation_hook = Validation.validation ~strict:true ()
```

## Pii_mask

Automatically detects and redacts personally identifiable information (PII) in LLM requests, responses, and tool calls.

```ocaml
val Pii_mask.pii_mask :
  ?patterns:string list ->         (* Custom detection patterns, default 4 built-in categories *)
  ?replacement:string ->           (* Replacement text, default "[REDACTED]" *)
  unit -> Types.middleware_hook
```

### Default detection patterns

| Category | Pattern |
|------|------|
| Email | `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z][a-zA-Z]+` |
| Phone | `XXX-XXX-XXXX` / `XXX.XXX.XXXX` / 10 consecutive digits |
| SSN | `XXX-XX-XXXX` |
| Credit card | `XXXX-XXXX-XXXX-XXXX` / `XXXX XXXX XXXX XXXX` |

### Behavior

- `on_before_llm`: scans all message content, replaces matched PII
- `on_after_llm`: scans LLM response text (prevents the LLM from echoing PII)
- `on_before_tool`: recursively scans every string value in the tool arguments JSON
- `on_after_tool`: recursively scans tool result JSON and error messages

### Usage example

```ocaml
(* Use default patterns *)
let pii_hook = Pii_mask.pii_mask ()

(* Custom patterns and replacement text *)
let pii_hook = Pii_mask.pii_mask
  ~patterns:["my-custom-pattern"]
  ~replacement:"[DATA REMOVED]"
  ()
```

## Sanitize_tool_output (v0.2.0)

Detects and sanitizes prompt injection patterns in tool output to keep a malicious tool response from hijacking the agent.

```ocaml
type sanitize_action =
  [ `Replace of string    (* Replace matched content *)
  | `Tag                  (* Wrap output with markers *)
  | `Block ]              (* Block the output entirely *)

type sanitize_config = {
  patterns : string list;
  action : sanitize_action;
}

val Sanitize_tool_output.default_config : sanitize_config

val Sanitize_tool_output.sanitize_tool_output :
  ?config:sanitize_config ->
  unit -> Types.middleware_hook
```

### Default detection patterns

```
"ignore previous", "ignore all previous", "you are now",
"system:", "new instructions", "disregard"
```

### Three handling strategies

| Strategy | Behavior |
|------|------|
| `Replace text` | replaces matched text with the given string (default `[SANITIZED]`) |
| `Tag` | keeps the output but prepends a `[SANITIZED-OUTPUT: ...]` marker |
| `Block` | rejects the entire output, replaces it with `[SANITIZED: blocked ...]` |

### Behavior

- only fires in the `on_after_tool` hook
- recursively scans every string value in the tool result JSON
- also scans error messages

### Usage example

```ocaml
(* Use default configuration *)
let sanitize_hook = Sanitize_tool_output.sanitize_tool_output ()

(* Strict mode: block any output containing injections *)
let sanitize_hook = Sanitize_tool_output.sanitize_tool_output
  ~config:{
    patterns = [
      "ignore previous"; "ignore all previous";
      "you are now"; "system:"; "new instructions";
      "disregard"; "forget everything";
    ];
    action = `Block;
  }
  ()
```

## Composing middleware

Middleware is ordered in the list, with earlier entries wrapping later ones. A typical production configuration:

```ocaml
let agent = {
  agent with
  middleware = [
    Logging.logging;                           (* Outermost: log every request *)
    Pii_mask.pii_mask ();                      (* Redact user input *)
    Rate_limit.rate_limit ~config:{
      max_requests = 30; window = 60.0;
    } ();                                     (* Rate limit *)
    Retry.retry ~config:{
      max_attempts = 3; base_delay = 2.0; max_delay = 30.0;
    } ();                                     (* Retry *)
    Validation.validation ~strict:true ();     (* Strict validation *)
    Sanitize_tool_output.sanitize_tool_output ();  (* Output sanitization *)
  ];
}
```

Execution flow: request -> Logging -> Pii_mask -> Rate_limit -> Validation -> LLM
Response -> Validation -> Sanitize -> Retry -> Rate_limit -> Pii_mask -> Logging

## Cancellation

The `Timeout` middleware above normalizes timeout errors after the fact. The actual deadline enforcement happens through cancellation tokens, which are the runtime-wide primitive for "stop this work, now." Middleware hooks do not see cancellation tokens directly, but every tool handler receives one, and any code that drives the Engine can request cancellation on a token it created.

### The cancellation surface

```ocaml
type cancellation_token

val Cancellation.create_token : Eio.Switch.t -> cancellation_token
val Cancellation.is_cancelled : cancellation_token -> bool
val Cancellation.check_cancel  : cancellation_token -> unit
val Cancellation.request_cancel : cancellation_token -> unit

val Cancellation.with_timeout :
  float ->
  cancellation_token ->
  (cancellation_token -> 'a) ->
  ('a, [> `Timeout | `Cancelled ]) result

val Cancellation.cancellable_handler :
  cancellation_token ->
  float ->
  (Yojson.Safe.t -> Types.handler_result) ->
  (Yojson.Safe.t -> Types.handler_result)
```

A token is created on an `Eio.Switch.t`. That switch owns the token's lifetime: when the switch exits, the token is cancelled along with every fiber running on it. You do not need to call `request_cancel` to clean up at scope exit.

`is_cancelled` is the non-throwing probe. Use it when you want to check the flag without committing to raising. `check_cancel` is the throwing probe: it raises `Eio.Cancel.Cancelled` immediately if the token is already cancelled. Long-running code should call `check_cancel` at natural boundaries (between loop iterations, between batch items) so a cancel request propagates promptly instead of waiting for the next blocking call.

`request_cancel` is how another fiber asks the work to stop. It sets the flag; the cancelled fiber observes it the next time it hits `check_cancel`, a cancel-aware Eio operation, or the `with_timeout` boundary.

### Timeout vs cancellation

`with_timeout` composes a deadline with an existing token. It returns either the function's value, `` `Timeout `` if the deadline elapsed first, or `` `Cancelled `` if someone called `request_cancel` on the underlying token before the deadline. The two cases are separate because they call for different responses: a timeout usually means "retry with a longer budget or a smaller task," while a cancellation usually means "the caller gave up, stop entirely."

```ocaml
match Cancellation.with_timeout 30.0 token (fun token ->
  Engine.run_agent token agent message llm registry)
with
| Ok result -> (* proceed *)
| Error `Timeout -> (* retry or surface *)
| Error `Cancelled -> (* propagate, do not retry *)
```

The deadline only triggers if the inner function observes cancellation at some point. Pure CPU work that never yields will run past the deadline. PAR's Engine and tool handlers are written to check cancellation between LLM round trips and before tool dispatch, so agent invocations are deadline-aware.

### How middleware interacts with cancellation

Middleware hooks receive the conversation, response, tool call, or error, but not the token. The token flows underneath: the Engine threads it through `run_agent`, and every tool handler gets it as its second argument. A middleware that wants to abort based on a signal it observes has two options:

1. Return `None` from the relevant hook and let the Engine continue. The middleware cannot force the Engine to stop, but it can short-circuit its own contribution.
2. Mutate shared state that the next `check_cancel` boundary will observe. This couples the middleware to the handler's cancellation discipline, so prefer the first option when it fits.

The `cancellable_handler` wrapper is the standard way to make a tool handler cancellation-aware without rewriting its body. Pass the token and a per-call timeout, and the wrapper ensures `check_cancel` fires between the handler's steps.

```ocaml
let handler input token =
  let wrapped = Cancellation.cancellable_handler token 10.0 real_handler in
  wrapped input
```

Here `real_handler` does not take a token. The wrapper gives it a 10-second budget per invocation and aborts with `Error` if the token is cancelled or the budget elapses. Use this when wrapping a third-party function you cannot easily thread a token through.

### Composition with Eio

Cancellation rides on Eio's structured concurrency. A token created on a switch is cancelled when the switch exits, so the common cleanup pattern is "run the agent inside `Eio.Switch.run`; if anything goes wrong, exit the switch and the agent's fibers are torn down." You rarely need to call `request_cancel` explicitly for cleanup; you need it for user-initiated cancellation (a "stop" button, a SIGINT handler) where the switch is not otherwise exiting.

## Custom middleware

Writing a custom middleware only requires constructing a `middleware_hook` record. The example below counts LLM calls:

```ocaml
let counter_middleware () =
  let count = ref 0 in
  {
    Types.name = "call_counter";
    on_before_llm = Some (fun _conv ->
      incr count;
      Printf.printf "LLM call #%d\n" !count;
      None);
    on_after_llm = None;
    on_before_tool = None;
    on_after_tool = None;
    on_error = None;
  }
```

### Error handling middleware example

Convert specific errors into retryable alternative results:

```ocaml
let fallback_middleware ~fallback_text () =
  {
    Types.name = "fallback";
    on_before_llm = None;
    on_after_llm = None;
    on_before_tool = None;
    on_after_tool = None;
    on_error = Some (fun err ->
      match err with
      | Types.External_failure _ ->
        (* Convert an external failure into a success result with fallback text *)
        Some (Types.Success (`String fallback_text))
      | _ -> None  (* Pass through other errors *)
    );
  }
```

### Caveats

- Middleware instances are shared within the same agent configuration, so mind concurrent state isolation
- `on_error` is currently dead code in the Engine layer (the Engine does not call `apply_on_error`); it will be wired up in a future release
- Returning `Some` means the value was modified or replaced, `None` means pass through the original

## See also

- [Overview](overview.md): SDK architecture overview
- [Agent API](agent.md): description of the `agent_config.middleware` field
- [Workflow API](workflow.md): middleware propagation in workflows
