# How-to: 注册自定义 LLM Provider
[English](../howto/custom-llm-provider.md) · **简体中文**

PAR 内置 OpenAI 和 Anthropic 两个 provider。本教程演示如何加一个（比如 Cohere、Mistral、Ollama 自托管等）。

## 步骤 1: 找到 `llm_provider_config` 位置

`lib/core/types.ml` 定义了 `llm_provider_config` 类型：

```ocaml
type llm_provider_config =
  | Openai of { api_key : string; base_url : string option; ... }
  | Anthropic of { api_key : string; base_url : string option; ... }
  | Ollama of { base_url : string; model : string }
  | Custom of {
      name : string;        (* 你的 provider 名 *)
      base_url : string;     (* HTTP endpoint *)
      request_fn : ...       (* 自定义请求/响应函数 *)
    }
[@@deriving yojson]
```

## 步骤 2: 继承 `llm_service` 接口

每个 provider 必须实现 `llm_service` record type（`lib/core/types.ml`）：

```ocaml
type llm_service = {
  complete_fn : ... -> (string, error_category) result;
  stream_fn : ... -> (string, error_category) result;
  close_fn : unit -> unit;
}
```

参考 `lib/providers/openai_provider.ml:1-50`，复制这个 pattern 改 HTTP endpoint + 请求/响应 schema 即可。

## 步骤 3: 在 `make_runtime` 注册

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

## 步骤 4: agent 引用

```ocaml
let agent = {
  id = "my-agent";
  model = { provider = `Custom "cohere"; model_name = "command-r-plus"; ... };
  ...
} in
Runtime.make_agent ~id:"my-agent" ~model:agent.model ...
```

## 完整例子：Ollama

参考 `lib/providers/openai_provider.ml` 写 `Ollama_provider.ml`，然后：

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

`Ollama` 已经被预置（v0.3.0 加的），可以直接用：

```ocaml
let config = {
  ...
  llm_providers = [("ollama", { base_url = "http://localhost:11434"; model = "llama3" })];
  ...
}
```

## 测试

每个 provider 建议至少 3 个测试：
1. `complete` happy path
2. `complete` 错误响应（401 / 429 / 500）
3. `stream` SSE 解析

参考 `test/test_openai_provider.ml` 模板。
