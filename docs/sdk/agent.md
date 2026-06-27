<!-- language: en -->

**English** · [简体中文](../zh/sdk/agent.md)

# Agent API Reference

> Translated to English for v0.3.2. Source-of-truth: the OCaml types in `lib/core/types.ml`.

This document describes the P-A-R SDK's Agent configuration, runtime management, and tool registration API. The `Par` facade (see `lib/par.ml`) re-exports every public module, so a single `open Par` brings the runtime, types, providers, persistence, and middleware into scope.

## Runtime configuration

### runtime_config

A runtime is created through `Par.Runtime.create` and needs the following configuration:

```ocaml
type runtime_config = {
  persistence : [ `Sqlite of string ];
  event_bus : event_bus_config;
  default_quota : resource_quota;
  shutdown : shutdown_config;
  llm_providers : (string * llm_provider_config) list;
  eval_limits : eval_limits;
  parallel_tool_execution : bool;
  bash_confirm : bash_confirm_config;
  event_retention_seconds : float;
}
```

The `Par` facade (`lib/par.ml`) re-exports `Types`, `Runtime`, and the persistence and event-bus modules. The full source-of-truth `runtime_config` is in `lib/core/types.ml`.

`Par.Runtime` provides these default configuration values that you can use directly:

```ocaml
Runtime.default_event_bus_config   (* buffer_capacity=10000, DLQ enabled *)
Runtime.default_quota             (* max_concurrent_tasks=10 *)
Runtime.default_shutdown_config   (* drain_timeout=30s *)
Runtime.default_bash_confirm      (* Always policy *)
```

### Creating a runtime

```ocaml
val Runtime.create :
  ?persistence:Types.persistence_service ->
  ?event_bus:Types.event_bus_service ->
  ?llm:Types.llm_service ->
  config:Types.runtime_config ->
  Eio.Switch.t ->
  (runtime, Types.error_category) result
```

Full example:

```ocaml
open Par

let config = {
  persistence = `Sqlite "par.db";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
}

let () = Eio_main.run (fun _env ->
  Eio.Switch.run (fun switch ->
    match Runtime.create ~config switch with
    | Error _ -> Printf.eprintf "Runtime creation failed\n"
    | Ok rt ->
      (* ... use the runtime ... *)
      let exit_code = Runtime.close rt in
      exit exit_code
  )
)
```

## Agent configuration

### agent_config

```ocaml
type agent_config = {
  id : string;                            (* Unique Agent identifier *)
  system_prompt : string;                 (* System prompt *)
  model : model_config;                   (* LLM model configuration *)
  tools : tool_descriptor list;           (* Available tool list *)
  max_iterations : int;                   (* ReAct loop max iterations *)
  middleware : middleware_hook list;       (* Middleware pipeline *)
  retry_policy : retry_policy option;     (* Optional retry policy *)
  context_strategy : context_strategy option;  (* Context window management strategy *)
  resource_quota : resource_quota option;  (* Optional resource quota override *)
  max_execution_time : float option;      (* Optional max execution time in seconds *)
  early_stopping_method : early_stopping_method;  (* Force or Generate on iteration cap *)
  on_max_tokens : on_max_tokens_behavior; (* Retry, Continue, or Return_partial on truncation *)
  max_continuation_chunks : int;          (* Max continuation chunks for Continue mode (default 3) *)
}
```

### model_config

```ocaml
type model_config = {
  provider : [ `Openai | `Anthropic | `Ollama | `Custom of string ];
  model_name : string;
  api_base : string option;          (* Custom API endpoint *)
  temperature : float;
  max_tokens : int option;
  top_p : float option;
  stop_sequences : string list option;
}
```

Provider examples:

```ocaml
(* OpenAI *)
{ provider = `Openai; model_name = "gpt-4"; api_base = None;
  temperature = 0.7; max_tokens = Some 4096; top_p = None;
  stop_sequences = None }

(* Anthropic via ZhipuAI gateway *)
{ provider = `Anthropic; model_name = "claude-sonnet-4-20250514";
  api_base = Some "https://open.bigmodel.cn/api/paas/v4";
  temperature = 0.5; max_tokens = None; top_p = None;
  stop_sequences = None }

(* Ollama local model *)
{ provider = `Ollama; model_name = "llama3"; api_base = None;
  temperature = 0.8; max_tokens = None; top_p = None;
  stop_sequences = None }

(* Custom endpoint *)
{ provider = `Custom "my-provider"; model_name = "my-model";
  api_base = Some "http://localhost:8000/v1";
  temperature = 0.7; max_tokens = None; top_p = None;
  stop_sequences = None }
```

### LLM provider configuration

Provider instances are created through `llm_provider_config` and passed to the `llm` parameter of `Runtime.create`. The `` `Mock `` provider from `lib/providers` is the deterministic choice for tests; production code reaches for `` `Openai `` or `` `Anthropic ``.

```ocaml
type llm_provider_config =
  | Openai of { api_key : string; base_url : string option;
                organization : string option }
  | Anthropic of { api_key : string; base_url : string option }
  | Ollama of { base_url : string }
  | Custom of { base_url : string; headers : (string * string) list;
                request_format : [ `Openai_compatible | `Anthropic_compatible ] }
```

## Runtime operations

### Registering an agent

```ocaml
val Runtime.register_agent : runtime -> agent_config -> (unit, error_category) result
```

```ocaml
let agent = {
  Types.id = "my-agent";
  system_prompt = "You are a helpful assistant.";
  model = { provider = `Openai; model_name = "gpt-4"; api_base = None;
            temperature = 0.7; max_tokens = None; top_p = None;
            stop_sequences = None };
  tools = [ tool.descriptor ];   (* from Runtime.register_tool *)
  max_iterations = 5;
  middleware = [];
  retry_policy = None;
  context_strategy = None;
  resource_quota = None;
} in
ignore (Runtime.register_agent rt agent)
```

### Invoking an agent

```ocaml
val Runtime.invoke :
  runtime ->
  agent_id:string ->
  message:string ->
  ?cancellation_token:Types.cancellation_token ->
  unit ->
  (Types.llm_response, Types.error_category) result
```

```ocaml
match Runtime.invoke rt ~agent_id:"my-agent" ~message:"Hello!" () with
| Ok resp ->
  (match resp.text with Some text -> Printf.printf "Response: %s\n" text
  | None -> Printf.printf "No text response\n")
| Error err -> Printf.eprintf "Error: %s\n" (Types.error_category_to_yojson err |> Yojson.Safe.to_string)
```

### Shutting down the runtime

```ocaml
val Runtime.close : runtime -> int   (* returns exit code *)
```

`Runtime.close` also stops every MCP server child spawned through `Runtime.mcp_server`; the returned integer is the exit code, and a non-zero value means a child process refused to exit cleanly.

## Tool registration

### tool_descriptor

```ocaml
type tool_descriptor = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;     (* JSON Schema format *)
  permission : tool_permission;     (* default Allow *)
  timeout : float option;
  concurrency_limit : int option;
}
```

### Handler function signature

A tool handler receives JSON input and a cancellation token and returns a `handler_result`:

```ocaml
type handler_fn = Yojson.Safe.t -> Types.cancellation_token -> Types.handler_result

type handler_result =
  | Success of Yojson.Safe.t
  | Error of {
      category : error_category;
      message : string;
      retryable : bool;
      metadata : (string * Yojson.Safe.t) list;
    }
```

### Runtime.register_tool

```ocaml
val Runtime.register_tool :
  runtime ->
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  handler:handler_fn ->
  ?permission:tool_permission ->
  ?timeout:float ->
  ?concurrency_limit:int ->
  unit ->
  tool_binding    (* returns descriptor + handler *)
```

`tool_binding` contains `descriptor` (for `agent_config.tools`) and `handler` (already registered with the registry):

```ocaml
type tool_binding = {
  descriptor : tool_descriptor;
  handler : Yojson.Safe.t -> cancellation_token -> handler_result;
}
```

### Tool registration example

```ocaml
(* Define a calculator tool *)
let calc_tool = Runtime.register_tool rt
  ~name:"calculator"
  ~description:"Evaluate a math expression"
  ~input_schema:(`Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("expression", `Assoc [
        ("type", `String "string");
        ("description", `String "The math expression to evaluate");
      ])
    ]);
    ("required", `List [`String "expression"]);
  ])
  ~handler:(fun input token ->
    match input with
    | `Assoc fields ->
      (match List.assoc_opt "expression" fields with
       | Some (`String expr) ->
         (try
           let result = float_of_string expr in
           Types.Success (`Float result)
         with _ ->
           Types.Error {
             category = Types.Invalid_input "Invalid expression";
             message = "Could not parse expression";
             retryable = false;
             metadata = [];
           })
       | _ -> Types.Error {
           category = Types.Invalid_input "Missing expression";
           message = "Expression field is required";
           retryable = false;
           metadata = [];
         })
    | _ -> Types.Error {
        category = Types.Invalid_input "Invalid input";
        message = "Input must be a JSON object";
        retryable = false;
        metadata = [];
      })
  ()
```

## ReAct loop

The agent execution core is `Par.Engine.run_agent`:

1. Build the conversation (system prompt + user message).
2. Apply `context_strategy` (if configured) to manage the context window.
3. Send the `on_before_llm` hook through the middleware chain.
4. Call the LLM provider to get a response.
5. Send the `on_after_llm` hook through the middleware chain.
6. If the response contains `tool_calls`, execute each tool in order:
   - Look up the tool descriptor.
   - Resolve the handler from the `Tool_registry`.
   - Execute the tool (with `on_before_tool` / `on_after_tool` hooks).
   - Append the tool result to the conversation.
7. Recurse until `finish_reason` is `Stop` or `max_iterations` is reached.

### max_iterations behavior

When the iteration count reaches `max_iterations`, `run_agent` returns `Result.Error (Internal "Max iterations exceeded")`.

### on_max_tokens behavior

When the LLM returns `finish_reason=Max_tokens` (truncated response), the behavior depends on `agent.on_max_tokens`:

- `Return_partial` (default): If the truncated response has non-empty text, preserve it and return `Ok` with the partial result. Empty truncations retain error/retry behavior.
- `Retry`: Preserve the truncated message for context, then re-enter the ReAct loop (bounded by `max_iterations`).
- `Continue`: Inject a "continue from where you stopped" follow-up, concatenate chunks until `finish_reason=Stop`. Capped by `max_continuation_chunks` (default 3). A diminishing-returns guard stops if a chunk adds fewer than 500 characters.

A `Llm_response_truncated` event is emitted on every truncation for observability.

## System prompt design guidance

- Pin the agent's role and capability boundaries up front.
- List the available tools and the scenarios where each one fits.
- Specify the output format requirement (JSON, plain text, and so on).
- For tasks that need multi-step reasoning, prompt the agent to think step by step.

```ocaml
system_prompt = {|
  You are a data analysis assistant. You have access to a calculator tool.
  When asked to compute something:
  1. Identify the mathematical expression
  2. Use the calculator tool
  3. Present the result clearly

  Always show your reasoning step by step.
|}
```

## System prompt templates

When the system prompt needs to vary per invocation (injecting the agent id, the runtime id, the available tool list, or user-supplied variables), reach for `system_prompt_template` instead of a plain `system_prompt`. Added as the `agent_config.system_prompt_template` field, it ships mustache-style `{{variable}}` substitution without pulling in a templating dependency.

### The template type

```ocaml
type system_prompt_template = {
  template : string;        (* Body text with {{var}} placeholders *)
  variables : string list;  (* Every placeholder the template may use *)
  required : string list;   (* Subset of `variables` that must be supplied *)
}
```

`variables` is the complete set of names the renderer recognizes. `required` is the subset that must be present at render time; omitting a required variable returns `Error` rather than silently substituting an empty string. Keeping the two lists separate lets a template declare optional niceties (a user's locale, a session tag) alongside hard requirements (the agent id).

### render_context

The renderer pulls values from a `render_context` record. The runtime builds one internally; if you call `Template.render` by hand you construct it yourself.

```ocaml
type render_context = {
  agent_id : string;
  runtime_id : string;
  user_variables : (string * Yojson.Safe.t) list;
  available_tools : string list;
}
```

`agent_id` and `runtime_id` are always available. `available_tools` is the list of tool names registered on the agent. `user_variables` is where caller-supplied values land. The renderer consults all four when resolving a `{{name}}`.

### Rendering

```ocaml
val Template.render :
  template:string ->
  variables:(string * Yojson.Safe.t) list ->
  required:string list ->
  context:render_context ->
  (string, Types.error_category) result

val Template.effective_system_prompt :
  Types.agent_config ->
  runtime_id:string ->
  (string, Types.error_category) result
```

`Template.render` is the low-level entrypoint. `effective_system_prompt` is the convenience wrapper: pass an `agent_config` and a `runtime_id`, and it returns the final string the Engine will send to the LLM. If `system_prompt_template` is `None`, it falls back to the plain `system_prompt` field, so existing agents keep working unchanged.

### When to use a template

Use a template when any of these apply:

- The prompt must reference the agent id or runtime id, and you do not want to interpolate by hand.
- The prompt needs per-call variables (user locale, session metadata, dynamic examples) that the caller supplies.
- You want the renderer to enforce required variables at startup rather than discovering a missing value mid-conversation.

Stick with a plain `system_prompt` when the text is static. A template with an empty `variables` list buys nothing and adds a render step.

### Example

```ocaml
let agent = {
  Types.id = "support";
  system_prompt = "You are a helpful assistant.";   (* fallback *)
  system_prompt_template = Some {
    template = {|
      You are {{role}}, assisting agent {{agent_id}} on runtime {{runtime_id}}.
      Available tools: {{available_tools}}.
      User context: {{user_locale}}.
    |};
    variables = ["role"; "agent_id"; "runtime_id";
                 "available_tools"; "user_locale"];
    required = ["role"; "user_locale"];
  };
  model = (* ... *);
  tools = [];
  max_iterations = 5;
  middleware = [];
  retry_policy = None;
  context_strategy = None;
  resource_quota = None;
  max_execution_time = None;
  early_stopping_method = Types.Force;
}
```

At invoke time, the renderer substitutes `agent_id`, `runtime_id`, and `available_tools` from the runtime, and pulls `role` and `user_locale` from the per-call `user_variables`. Because both are `required`, a caller that forgets `user_locale` gets an `Error` before the first LLM round trip, not a garbled prompt.

## Context strategy

Long conversations outgrow the model's context window. The `agent_config.context_strategy` field decides how PAR trims a conversation before each LLM call. Leave it as `None` and the runtime applies its default; set it explicitly to override.

### The strategy variant

```ocaml
type context_strategy =
  | Truncate_oldest of { keepSystem : bool; min_messages : int }
  | Summarize of { max_tokens : int; summary_model : model_config option }
  | Sliding_window of { max_messages : int; max_tokens : int }
```

`Truncate_oldest` drops the oldest non-system messages until the conversation fits. `keepSystem` (default true) pins system messages at the front; `min_messages` is the floor below which nothing else is dropped even if the token estimate is over budget. Reach for this strategy when the recent turns carry the signal and old turns are noise.

`Summarize` compresses earlier turns into a summary message using a second LLM call. `max_tokens` bounds the summary length. `summary_model` optionally routes the summarization call to a cheaper or faster model than the agent's primary model; `None` reuses the agent's own `model_config`. This is the right choice when early context genuinely matters but token budget is tight, at the cost of an extra LLM round trip per summarization.

`Sliding_window` keeps the most recent `max_messages` messages and drops everything older, subject to a `max_tokens` ceiling. It is the cheapest strategy because it never calls another model, and it preserves the tail of the conversation verbatim. This is the default.

### How the Engine applies a strategy

Before each LLM round trip, the Engine calls `Context_manager.apply_strategy` on the current conversation. The function either returns the (possibly reduced) conversation or an `Error` if the strategy could not satisfy its constraints (for example, `Truncate_oldest` hitting `min_messages` while still over `max_tokens`).

```ocaml
val Context_manager.apply_strategy :
  Types.context_strategy -> Types.conversation ->
  Types.llm_service option ->
  on_event:(Types.event -> unit) option ->
  (Types.conversation, Types.error_category) result

val Context_manager.estimate_tokens : Types.conversation -> int
```

`estimate_tokens` is a rough character-divided-by-four heuristic. It is not a tokenizer. Treat the number as advisory when reasoning about budgets.

### The v0.5.1 default

As of v0.5.1, a runtime with no explicit `context_strategy` gets:

```ocaml
Some (Sliding_window { max_messages = 100; max_tokens = 200000 })
```

This is a deliberate change from earlier betas, which left the strategy unset and let conversations grow unbounded until the provider rejected them. The 200K token ceiling matches the largest current production models, and the 100 message ceiling keeps the conversation from sprawling even when individual messages are short. If you previously relied on unbounded growth (for example, summarizing yourself outside the runtime), set `context_strategy = None` explicitly to restore the old behavior.

For agents that talk to models with smaller windows, lower both numbers. A 4K-token model paired with `max_messages = 100` will still trip provider limits, because `max_messages` is checked before token estimation.

## Cancellation tokens

```ocaml
val Cancellation.create_token : Eio.Switch.t -> cancellation_token
val Cancellation.request_cancel : cancellation_token -> unit
val Cancellation.check_cancel : cancellation_token -> unit
  (* raises Eio.Cancel.Cancelled if already cancelled *)
val Cancellation.with_timeout : float -> cancellation_token ->
  (cancellation_token -> 'a) -> ('a, [ `Cancelled | `Timeout ]) result
```

```ocaml
let token = Cancellation.create_token switch in
(* Can be cancelled from another fiber *)
Cancellation.request_cancel token
```

## See also

- [Overview](overview.md) -- SDK architecture overview
- [Workflow API](workflow.md) -- Workflow orchestration
- [Middleware API](middleware.md) -- Middleware pipeline
- [MCP client](mcp.md) -- `Runtime.mcp_server` lifecycle, `call_tool`, `read_resource`, `get_prompt`
- [examples/basic_agent.ml](../../examples/basic_agent.ml) -- Complete runnable example
