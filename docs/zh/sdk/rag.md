<!-- language: zh -->
**[English](../sdk/rag.md)** · 简体中文

# RAG API 参考

> 在 v0.5.1 中添加。真实来源：`lib/core/types.ml`、`lib/core/vector_store.mli` 和 `lib/core/chunking.mli` 中的 OCaml 类型。Python 绑定通过 FFI 提供相同的接口。Phase B.2（向量存储）、B.3（分块）和 C.3（Python FFI）实现本文档。

PAR 的 RAG（Retrieval-Augmented Generation，检索增强生成）管道将 LLM 响应锚定在你自己的文档中。你将文本嵌入（embed）为向量，存储在本地向量索引中，在查询时检索与问题最相似的 chunk。检索到的 chunk 作为上下文注入 prompt，然后 LLM 作答。

本页面覆盖两个接口。Python 绑定（`pip install par-runtime`）是大多数用户更快的路径，端到端支持完整的 RAG 循环。OCaml SDK 暴露相同的循环，并提供对 `Vector_store` 和 `Chunking` 模块的直接、类型安全访问，适合想要自己管理索引的调用方。

管道有四个部分：**Embeddings**（将文本转为向量）、**Vector Store**（存储和搜索向量）、**Chunking**（拆分长文档）和 **RAG Invocation**（将三者组合为锚定查询）。

## 为什么向量存储与 embedding 无关

PAR 的向量存储接受预计算的浮点数组。它不知道是哪个 embedding 模型产出的向量，也不会自己调用模型。调用方负责使用同一个模型对文档和查询进行嵌入。

这是一个刻意的选择。RAG 中的静默失败模式是 embedding 模型漂移：你用模型 A 索引文档，然后用模型 B 查询，检索质量崩溃但没有错误暴露。通过强制调用方拥有嵌入步骤，PAR 使在一个地方维护一个模型名称并通过它路由索引和查询变得自然。代价是在调用点多一行代码。

一个后果：如果你更换 embedding 模型，必须重新索引所有文档。见下方"持久化与重索引"。

## Embedding Provider 支持矩阵

Embedding 是与 chat completions 分离的能力。一个 provider 可以支持 chat 但不支持 embedding。下面的矩阵是 v0.5.1 中"我能用这个 provider 做 embedding 吗？"的权威回答。

| Provider | Embedding | 默认模型 | 维度 | 备注 |
|----------|-----------|----------|------|------|
| `` `Openai `` | 是 | `text-embedding-3-small` | 1536 | 完全支持。在 provider 配置中覆盖模型。返回余弦相似度向量。 |
| `` `Anthropic `` | 否 | 不适用 | 不适用 | Anthropic 不提供 embedding API。`embed` 无条件返回 `Error Embedding_unsupported`。使用 OpenAI、Ollama 或 Mock 进行嵌入步骤；你仍然可以在 `invoke_with_rag` 中使用 Anthropic 进行 chat completion。 |
| `` `Ollama `` | 是 | `nomic-embed-text`（推荐） | 取决于模型 | 通过 OpenAI 兼容端点（`/v1/embeddings`）工作。将 OpenAI provider 的 `base_url` 指向你的 Ollama 实例并选择一个 embedding 模型。维度取决于模型；在 `Vector_store.create` 中将 `dimension` 与模型输出匹配。 |
| `` `Mock `` | 是 | 确定性哈希向量 | 1536 | 用于测试的确定性哈希向量。相同输入字符串总是产出相同向量，因此单元测试可复现。不适合真实检索。 |

如果你对一个返回 `Embedding_unsupported` 的 provider 调用 `embed`，错误在 Python 中表现为 `PARError`，在 OCaml 中表现为 `Error Embedding_unsupported`。恢复方式是配置一个支持 embedding 的 provider。

## Python SDK

### 快速入门：端到端 RAG

此示例索引三个短文档，提出一个问题，并打印锚定回答。它使用 Mock provider，因此无需 API key 即可运行。要使用真实嵌入，将 provider 块替换为 OpenAI（注释在代码中）。

```python
import json
import os
from par_runtime import Runtime, PARError

# One provider configured for BOTH embeddings and chat. The Mock provider
# needs no credentials and returns deterministic vectors, so the script
# runs as-is. For real retrieval, use the OpenAI block below.
use_mock = os.environ.get("PAR_PROVIDER", "mock") == "mock"

if use_mock:
    provider = {"tag": "mock"}
else:
    provider = {
        "tag": "openai",
        "contents": {
            "api_key": os.environ["OPENAI_API_KEY"],
            # Ollama works too: set base_url to http://localhost:11434/v1
            # and pick an embedding model in the embedding_model field.
        },
    }

config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "llm_providers": [provider],
})

agent_config = json.dumps({
    "id": "rag_agent",
    "model": {"tag": "mock"},  # or {"tag": "openai", "contents": {...}}
    "system_prompt": "Answer the user's question using only the provided context.",
})

with Runtime(config) as rt:
    rt.register_agent(agent_config)

    # Index documents. Pass strings (ids auto-generated) or dicts with
    # id/content/metadata. Embedding happens inside add_documents.
    docs = [
        "PAR is an OCaml agent runtime. It handles the ReAct loop, tool dispatch, and multi-provider LLM calls.",
        "PAR's vector store uses sqlite-vec under the hood and is embedding-agnostic.",
        "PAR ships 20 built-in tools, including a type-safe bash tool that prevents shell injection.",
    ]
    added = rt.add_documents(docs)
    print(f"Indexed {added} documents")

    # Ask a question. invoke_with_rag embeds the query, retrieves top-k
    # chunks, augments the prompt, and invokes the agent.
    answer = rt.invoke_with_rag("rag_agent", "How many tools does PAR ship?", k=2)
    print(json.loads(answer))
```

示例演示的要点：

- 一个 provider 块同时处理 embedding 和 chat。你不需要分别配置它们。
- `add_documents` 接受纯字符串用于常见情况，或字典用于需要稳定 id 或元数据过滤的场景。
- `invoke_with_rag` 返回与 `invoke` 相同的 JSON 字符串形状。用 `json.loads` 解析以取出 assistant 消息和任何工具调用。
- `k=2` 检索两个最相似的 chunk。默认是 `k=4`。更高的 k 意味着更多上下文但更长的 prompt；根据你的文档集调优。

### 多文档索引

当你有不止少量文档时，传入带有显式 id 和元数据的字典。id 让你之后可以更新或删除单个文档而不影响其他。元数据存储在向量旁边并在搜索结果中返回，因此你可以过滤或显示来源。

```python
documents = [
    {
        "id": "docs/arch-001",
        "content": "The runtime uses Eio for structured concurrency. Every fiber has a parent; no orphan fibers.",
        "metadata": {"source": "architecture.md", "section": "concurrency", "version": "0.5"},
    },
    {
        "id": "docs/arch-002",
        "content": "Persistence defaults to SQLite, the only persistent backend.",
        "metadata": {"source": "architecture.md", "section": "persistence", "version": "0.5"},
    },
    {
        "id": "docs/tools-001",
        "content": "The bash tool takes a Bash_safe_command ADT. Raw strings are not accepted, so shell injection is unrepresentable.",
        "metadata": {"source": "tools.md", "section": "bash", "version": "0.5"},
    },
]

with Runtime(config) as rt:
    rt.register_agent(agent_config)
    count = rt.add_documents(documents)
    assert count == len(documents)

    # Retrieval still goes through invoke_with_rag. Metadata is not queried
    # directly from Python in v0.5.1; it rides along on each search result
    # for the OCaml caller and for future filter support.
    answer = rt.invoke_with_rag("rag_agent", "What concurrency library does PAR use?", k=3)
```

关于大规模索引的两个实用说明。第一，批量嵌入。OpenAI embedding 端点每次请求接受多个输入，`Runtime.embed` 已经做了批处理；`add_documents` 内部也是如此。如果你通过 OCaml SDK 索引数千个文档，将列表分成 100 到 500 个一批以保持请求大小合理。第二，优先使用稳定 id。如果你通过添加新 id 的文档来重索引，旧条目会留下并稀释检索质量。跨重索引运行使用相同的 id，这样 `add` 会原地更新。

### 持久化与重索引

Python 绑定的向量存储默认存在于进程内存中（`":memory:"` SQLite）。它不会跨进程重启存活。要在 Python 中跨运行持久化，目前需要在启动时重新索引或将文档集序列化到磁盘后重新加载。

OCaml SDK 给你显式控制。传入真实文件路径到 `Vector_store.create ~db_path:"/var/lib/par/vectors.db"`。sqlite-vec 索引随后跨进程重启持久化。用相同路径和维度重新打开存储会重新加载已有向量；你不需要每次启动都重新索引。

何时需要重索引：

- **你更换了 embedding 模型。** 不同模型在不同空间产出向量。跨混合模型向量的余弦相似度没有意义。清空存储（按 id 调用 `Vector_store.delete`，或删除 db 文件）并重新嵌入每个文档。
- **你更改了维度。** `Vector_store.create` 在创建时固定维度。添加不同维度的向量会失败。用新维度重新创建存储并重索引。
- **你的文档语料库大幅变化。** 如果超过约 30% 的文档是新增或移除的，干净重索引通常比增量添加获得更好的检索质量。增量添加适合小规模追加。

你不需要重索引的情况：你更换了 chat 模型（embedding 和 chat 是解耦的）、你更改了 `k`、或者你对持久化 db 文件重启了进程。

## OCaml SDK 参考

OCaml 接口是真实来源。每个 Python 方法通过 FFI 映射到一个 OCaml 函数，因此下面的签名是运行时实际执行的。

### Embedding

```ocaml
open Par
open Types

let embed rt messages =
  Runtime.embed rt messages
(* val embed : Runtime.t -> string list ->
 *   (float array list, error_category) result *)
```

`Runtime.embed` 接受字符串列表并返回浮点数组列表（每个输入一个向量），或返回 `error_category`。Provider 行为匹配上面的矩阵。在 OpenAI 上，网络故障返回为 `External_failure`，请求超时为 `Timeout`，缺少 API key 为 `Invalid_input`。

### 向量存储

`Vector_store` 模块是持久化层。它与 embedding 无关：它存储 `(document, float array)` 对并按余弦相似度排序返回。

```ocaml
open Par.Vector_store

(* Create an in-memory store. For persistence, use a file path.
   The vec_extension_path is resolved automatically by the FFI layer
   (par_set_vec_extension_path) for pip-installed users; OCaml SDK
   callers pass it explicitly. *)
let store =
  match create
    ~db_path:":memory:"
    ~vec_extension_path:"vendor/sqlite-vec/linux-x86_64/vec0.so"
    ~dimension:1536
    () with
  | Ok s -> s
  | Error e -> failwith (Runtime.string_of_error_category e)

let doc = {
  id = "doc1";
  content = "PAR is an OCaml agent runtime";
  metadata = None;  (* optional Yojson; rides along on search results *)
}
let vec = [| 0.1; 0.2; 0.3; (* ...1536 floats... *) |]  (* from Runtime.embed *)
let () =
  match add store [(doc, vec)] with
  | Ok () -> ()
  | Error e -> prerr_endline (Runtime.string_of_error_category e)

let results =
  match search store ~query:query_vec ~k:4 with
  | Ok rs -> rs
  | Error e -> []
(* results : search_result list =
 *   [{ doc = { id; content; metadata }; score }] *)
```

完整签名：

| 函数 | 签名 | 用途 |
|------|------|------|
| `create` | `db_path:string -> vec_extension_path:string -> dimension:int -> unit -> (t, error_category) result` | 打开或创建存储。`db_path ":memory:"` 是临时的；文件路径则持久化。`dimension` 必须匹配你的 embedding 模型。 |
| `add` | `t -> (document * float array) list -> (unit, error_category) result` | 插入或更新文档。`document.id` 是主键；添加已存在的 id 会替换向量。 |
| `search` | `t -> query:float array -> k:int -> (search_result list, error_category) result` | 按余弦相似度返回 top-k 文档，最高分在前。 |
| `delete` | `t -> ids:string list -> (unit, error_category) result` | 按 id 删除文档。 |
| `close` | `t -> unit` | 关闭底层 SQLite 句柄。在关闭时安全调用一次。 |

`score` 是 `[-1.0, 1.0]` 范围内的余弦相似度；越高表示越相似。`document` 记录携带 `id : string`、`content : string` 和 `metadata : Yojson.Safe.t option`。元数据对存储是不透明的；它随每个搜索结果一起返回，以便调用方过滤或显示来源。

### 分块

长文档在嵌入前应该被拆分。一个 10,000 token 的 PDF 整块喂给嵌入器会产出一个平均化掉每个有用信号的向量。分块将一个长文档变成多个短文档，每个有自己的向量，这样检索就能命中正确的段落。

```ocaml
open Par.Chunking

let chunks = chunk_recursive
  ~text:long_document
  ~max_size:1000
  ~overlap:200
(* chunks : chunk list = [{ text; start_pos; end_pos }] *)
```

三种策略，都是纯函数（无 I/O、无 provider 耦合、无分词器依赖）：

| 函数 | 策略 | 适用场景 |
|------|------|----------|
| `chunk_by_chars` | 基于字符的固定大小滑动窗口，`stride = max_size - overlap`。 | 字符数是语义单元大小良好代理的统一文档。简单且可预测。 |
| `chunk_by_tokens` | 基于空白分词的滑动窗口。一个词等于一个 token（近似；没有真正的分词器）。 | 当你想要每个 chunk 大约 N 个词且不需要精确 token 计数时。精确计数请用 provider 的分词器预分词，然后对结果调用 `chunk_by_chars`。 |
| `chunk_recursive` | LangChain `RecursiveCharacterTextSplitter`。按顺序尝试分隔符 `["\n\n"; "\n"; " "; ""]`，当片段超过 `max_size` 时回退到更细的拆分。 | 散文、markdown、代码注释的默认选择。优先尊重段落和行边界，因此 chunk 保持可读。 |

如果 `max_size <= 0` 或 `overlap >= max_size`，三种策略都会抛出 `Invalid_argument`。调用方必须指定 `max_size` 和 `overlap`；此模块不继承 LangChain 的 `chunk_size=4000, chunk_overlap=200` 默认值，因为正确的值取决于你的 embedding 模型的上下文窗口。

典型值：`text-embedding-3-small`（接受最多 8191 个 token）用 `max_size=1000` 和 `overlap=200`。重叠保持跨 chunk 边界的上下文，这样在边缘附近的检索命中仍然携带相邻文本。

### RAG 调用

`Runtime.invoke_with_rag` 是嵌入、搜索、增强和调用的单次组合。

```ocaml
let (answer, retrieved_docs) =
  Runtime.invoke_with_rag rt
    ~agent_id:"my_agent"
    ~message:"What is PAR?"
    ~k:4
    ~vector_store:(Some store)
    ()
```

管道按顺序执行：

1. 使用运行时配置的 embedding provider 嵌入查询消息。
2. 在向量存储中搜索 top-k 最相似的文档。
3. 用检索到的上下文增强 agent 的系统提示词，格式化为上下文块。
4. 通过正常的 `Runtime.invoke` 路径用增强后的 prompt 调用 agent。
5. 返回 `(answer, retrieved_documents)`，以便调用方可以显示来源或记录检索到的内容。

如果 `?vector_store` 是 `None`，`invoke_with_rag` 回退到没有检索的普通 `Runtime.invoke`。这让你可以通过传入 `Some store` 或 `None` 来开关 RAG，而无需改变调用形状。

## 错误类别参考

每个可能失败的 RAG 操作在 OCaml 中返回 `( _, error_category) result`，在 Python 中抛出 `PARError`。七个 `error_category` 变体覆盖完整的失败面。使用此表编写恢复逻辑。

| 变体 | 在 RAG 中何时发生 | 恢复方式 |
|------|-------------------|----------|
| `Embedding_unsupported` | 你对一个没有 embedding API 的 provider（Anthropic）调用了 `embed` 或 `add_documents`。 | 将 embedding provider 切换为 OpenAI、Ollama 或 Mock。你可以在 `invoke_with_rag` 的 chat 步骤中保留 Anthropic。 |
| `Invalid_input of string` | 空 API key、分块中 `max_size <= 0` 或 `overlap >= max_size`、provider 返回格式错误的 embedding 响应、`Vector_store.add` 时向量维度不匹配。 | 字符串携带详情。修复输入并重试。这不是瞬态错误；不改变输入重试会以同样方式失败。 |
| `External_failure of string` | embedding HTTP 请求期间的网络错误、provider 返回非 200 状态（不是限流或认证错误）、sqlite-vec 扩展加载失败。 | 检查网络连接和 provider 状态。对于扩展路径，验证 `vec_extension_path` 指向一个存在的文件且匹配你的平台。瞬态；带退避的重试是合理的。 |
| `Rate_limited` | Provider 返回 429。 | 退避并重试。实现带抖动的指数退避。PAR 的 Retry 中间件可以在调用经过 agent 时处理此情况。 |
| `Permission_denied of string` | 错误或过期的 API key（401/403）。 | 刷新凭证。非瞬态。 |
| `Timeout` | embedding 请求或 `invoke_with_rag` 内部的 LLM 调用超过了配置的超时。 | 重试一次。如果持续发生，提高超时或减小 embedding 的批次大小。 |
| `Internal of string` | 意外的 OCaml 异常、网络句柄未初始化（OpenAI provider `set_network` 未调用）、或 bug。 | 检查运行时是否通过 `Runtime.create` 创建（它会连接网络）。如果调用路径正确且持续发生，可能是值得提交的 bug。 |

在 Python 中，所有这些都表现为带有消息字符串的 `PARError`。在 v0.5.1 中，变体没有跨 FFI 边界保留；如果需要分支匹配请根据消息文本判断。在 OCaml 中，直接对变体进行模式匹配。

## 使用示例

三个可运行的 OCaml 示例，覆盖你实际需要的模式：基本 embedding 健全性检查、带分块的文档索引、以及完整的 RAG 问答调用。

### 示例 1：基本 embedding 健全性检查

在构建更大功能之前确认 embedding provider 连接正确。一个字符串进，一个向量出，打印维度。

```ocaml
let () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun switch ->
      match Runtime.create ~config switch with
      | Ok rt ->
        (match Runtime.embed rt ["hello world"] with
         | Ok [vec] ->
           Printf.printf "Vector has %d dimensions\n" (Array.length vec)
         | Ok _ -> prerr_endline "embed returned unexpected number of vectors"
         | Error e ->
           prerr_endline ("embed failed: " ^ Runtime.string_of_error_category e));
        ignore (Runtime.close rt)
      | Error e -> prerr_endline (Runtime.string_of_error_category e)))
```

如果打印 `Vector has 1536 dimensions`，OpenAI 或 Mock 工作正常。如果打印 `embed failed: embedding_unsupported`，你指向了 Anthropic；请重新配置。如果打印 `embed failed: api_key must not be empty`，请设置你的 API key。

### 示例 2：分块并索引长文档

用 `chunk_recursive` 拆分长文档，嵌入 chunk，并用生成的 id 插入向量存储。这是你会围绕每个文档源包装的索引循环。

```ocaml
open Par
open Types

let index_documents rt store docs =
  (* Concatenate, chunk, then embed each chunk. Overlap keeps context
   * across boundaries so retrieval near a chunk edge still sees the
   * neighboring text. *)
  let full_text = String.concat "\n\n" docs in
  let chunks = Chunking.chunk_recursive
    ~text:full_text ~max_size:1000 ~overlap:200 in
  match Runtime.embed rt (List.map (fun c -> c.Chunking.text) chunks) with
  | Error e ->
    prerr_endline ("indexing failed: " ^ Runtime.string_of_error_category e)
  | Ok vecs ->
    let doc_vecs =
      List.mapi (fun i vec ->
        ({ Vector_store.id = Printf.sprintf "chunk_%04d" i;
           content = (List.nth chunks i).Chunking.text;
           metadata = None }, vec)) vecs
    in
    (match Vector_store.add store doc_vecs with
     | Ok () -> Printf.printf "Indexed %d chunks\n" (List.length chunks)
     | Error e ->
       prerr_endline ("store add failed: " ^ Runtime.string_of_error_category e))
```

生成的 id（`chunk_0000`、`chunk_0001`、...）对给定输入文本是确定性的。如果你重新索引同一个文档，id 匹配，存储会原地更新而非重复。

### 示例 3：RAG 问答

收获时刻。文档索引好后，锚定查询只需一次调用。

```ocaml
let rag_qa rt store question =
  match Runtime.invoke_with_rag rt
    ~agent_id:"assistant"
    ~message:question
    ~k:4
    ~vector_store:(Some store)
    () with
  | Ok (answer, retrieved) ->
    Printf.printf "Answer: %s\n" answer;
    Printf.printf "Based on %d retrieved documents\n" (List.length retrieved);
    List.iteri (fun i r ->
      Printf.printf "  [%d] id=%s score=%.4f\n"
        (i + 1) r.Vector_store.doc.id r.Vector_store.score) retrieved
  | Error e ->
    prerr_endline ("RAG failed: " ^ Runtime.string_of_error_category e)
```

检索到的文档带着分数返回，这样你可以在 UI 中显示来源、为调试记录检索内容、或在信任回答前应用分数阈值。

## 限制

- **Python 向量存储是内存中的。** Python 绑定的 `add_documents` 创建临时存储。跨进程重启持久化需要 OCaml SDK 配合文件路径，或在启动时重新索引。Python 的文件持久化是未来候选。
- **Python 不支持元数据过滤。** 元数据被存储并在搜索结果中返回，但 Python 绑定没有在 `invoke_with_rag` 或 `add_documents` 上暴露过滤参数。过滤将在未来版本的外部向量存储支持中落地。
- **尚无外部向量存储。** 存储仅支持 sqlite-vec。Qdrant 和 Milvus 支持在路线图上，用于超出单进程 SQLite 索引能力的工作负载。
- **没有流式 RAG。** `invoke_with_rag` 返回完整回答。流式变体（`invoke_with_rag_streaming`）推迟到基础流式接口稳定后；见 Streaming API 页面。
- **分块没有真正的分词器。** `chunk_by_tokens` 将一个空白分隔的词视为一个 token。要进行精确的基于 token 的分块，请用 provider 的分词器预分词，然后将结果传给 `chunk_by_chars`。
- **维度在存储创建时固定。** 更换 embedding 模型几乎总会改变维度。你必须重新创建存储并重索引；见"持久化与重索引"。

## 另请参阅

- [Agent API](agent.md) - `Runtime.invoke`、`agent_config`、非 RAG 入口
- [Streaming API](streaming.md) - `invoke_stream`、Event 类型、分块输出接口
- [工作流 API](workflow.md) - 顺序、并行、条件编排
- [概览](overview.md) - SDK 架构和模块映射
