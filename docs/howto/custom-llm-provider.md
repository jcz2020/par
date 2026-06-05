<!-- language: en -->

> Translated to English for v0.3.2.

# How-to: Register a Custom LLM Provider

PAR ships OpenAI and Anthropic providers out of the box. This guide shows how to add another one (e.g. Cohere, Mistral, self-hosted Ollama, etc.).

## Step 1: Find the `llm_provider_config` type

`lib/core/types.ml` defines `llm_provider_config`:

```ocaml
type llm_provider_config =
  | Openai of { api_key : string; base_url : string option; ... }
  | Anthropic of { api_key : string; base_url : string option; ... }
  | Ollama of { base_url : string; model : string }
  | Custom of {
      name : string;        (* your provider name *)
      base_url : string;     (* HTTP endpoint *)
      request_fn : ...       (* custom request/response function *)
    }
[@@deriving yojson]
```

## Step 2: Implement the `llm_service` interface

Every provider must implement the `llm_service` record type (`lib/core/types.ml`):

```ocaml
type llm_service = {
  complete_fn : ... -> (string, error_category) result;
  stream_fn : ... -> (string, error_category) result;
  close_fn : unit -> unit;
}
```

See `lib/providers/openai_provider.ml:1-50` — copy the pattern and change the HTTP endpoint and request/response schema.

## Step 3: Register in `make_runtime`

```ocaml
let () =
  let module Cohere = My_cohere_provider in
  let runtime = Runtime.create
    ~config:my_config
    ?llm:(Some {
      complete_fn = Cohere.complete;
      stream_fn = Cohere.stream;
      close_fn = Cohere.close;
    })
    switch
  in
  ...
```

## Step 4: Reference from agent config

```ocaml
let agent = {
  id = "my-agent";
  model = { provider = `Custom "cohere"; model_name = "command-r-plus"; ... };
  ...
} in
Runtime.make_agent ~id:"my-agent" ~model:agent.model ...
```

## Full example: Ollama

Follow `lib/providers/openai_provider.ml` to write `Ollama_provider.ml`, then:

```ocaml
module Ollama = struct
  type t = { base_url : string; model : string }
  let create ~base_url ~model = { base_url; model }
  let complete t model_config tools conversation =
    (* POST to {base_url}/api/chat with {model, messages, tools, stream:false} *)
    ...
  let stream t model_config tools conversation stream_config callback =
    (* Same but stream:true, parse SSE *) ...
  let close _ = ()
end
```

`Ollama` is already built-in (added in v0.3.0). Use it directly:

```ocaml
let config = {
  ...
  llm_providers = [("ollama", { base_url = "http://localhost:11434"; model = "llama3" })];
  ...
}
```

## Testing

Every provider should have at least 3 tests:
1. `complete` happy path
2. `complete` error responses (401 / 429 / 500)
3. `stream` SSE parsing

See `test/test_openai_provider.ml` for a template.
