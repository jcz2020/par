<!-- language: en -->

# Agent API Reference

> Translated to English for v0.3.2. Source-of-truth: the OCaml types in `lib/core/types.ml`.

This document describes the P-A-R SDK's Agent configuration, runtime management, and tool registration API. The `Par` facade (see `lib/par.ml`) re-exports every public module, so a single `open Par` brings the runtime, types, providers, persistence, and middleware into scope.

## Runtime configuration

### runtime_config

A runtime is created through `Par.Runtime.create` and needs the following configuration:

```ocaml
type runtime_config = {
  persistence : [ `Sqlite of string | `Postgresql of string ];
  event_bus : event_bus_config;
  default_quota : resource_quota;
  shutdown : shutdown_config;
  llm_providers : (string * llm_provider_config) list;
  eval_limits : eval_limits;
}
```

The `Par` facade (`lib/par.ml`) re-exports `Types`, `Runtime`, and the persistence and event-bus modules. The full source-of-truth `runtime_config` in `lib/core/types.ml` adds `parallel_tool_execution` and a `` `Noop `` persistence variant for tests; the snippets below use the stable subset that compiles against the published `par` opam package.

`Par.Runtime` provides three default configuration values that you can use directly:

```ocaml
Runtime.default_event_bus_config   (* buffer_capacity=10000, DLQ enabled *)
Runtime.default_quota             (* max_concurrent_tasks=10 *)
Runtime.default_shutdown_config   (* drain_timeout=30s *)
```

### Creating a runtime

```ocaml
val Runtime.create :
  ?persistence:Types.persistence_service ->
  ?event_bus:(module Types.EVENT_BUS_SERVICE) ->
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

Provider instances are created through `llm_provider_config` and passed to the `llm` parameter of `Runtime.create`. The `` `Mock `` provider from `lib/providers` is the deterministic choice for tests; production code reaches for `` `Openai `` or `` `Anthropic ``. The PostgreSQL backend, when needed, is registered through `` `Postgresql `` in `persistence`, with the full `par_postgres` opam package providing the implementation.

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

For a `Max_tokens` `finish_reason`, if the iteration cap has not been reached, the loop retries automatically.

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
