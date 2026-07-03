<!-- language: zh -->

**[English](../explanation/rag-architecture.md)** · 简体中文

# RAG 架构

> **Note (v0.6.7):** 本文前部对 `par ask` 的引用是历史性的（CLI 已移除）。RAG 管道（embeddings、向量存储、检索）没有变化，通过 `Runtime.invoke_with_rag` 暴露。见 [RAG 参考](../sdk/rag.md)。

RAG（检索增强生成，Retrieval-Augmented Generation）是让 LLM 的回答基于你自己的文档：把文档嵌入为向量，存储起来，搜索与查询最接近的向量，把检索到的上下文作为提示的一部分交给 LLM。PAR 在 v0.5.1 发布了 RAG 基础设施。本文解释这背后的设计决策：为什么向量存储是 embedding 无关的，为什么 sqlite-vec 是第一个后端，三阶段检索管道是如何接线的。API 签名请阅读 [RAG 参考](../sdk/rag.md)。这里我们讲*为什么*。

## 塑造一切的决策：embedding 无关的存储

PAR RAG 栈中最重要的设计决策是 `Vector_store` 对 embedding 一无所知。它存储文档配上预计算的 `float array` 向量。它用你交给它的查询向量搜索。它从不自己调用 embedding 模型。

这不是显而易见的选择。LangChain 的 `FAISS` 模式和大多数 Python RAG 教程把向量存储和 embedding 模型耦合在一起：在创建存储时注入 embedding，存储内部对文档和查询做嵌入。简单场景下这很方便。但它也是最常见的 RAG bug 的根源。

这个 bug 就是 embedding 模型漂移。如果你的文档向量是模型 A 生成的，查询向量是模型 B 生成的，余弦相似度就没有意义了。存储返回垃圾结果且不报错。你到用户抱怨检索坏了才发现。在耦合存储中，每当有人改了配置的 embedding 模型却忘了重新索引、或两条代码路径用不同模型构造存储、或查询通过默认使用不同模型的路径溜进来，就会发生这种情况。

PAR 的 `Vector_store` 从构造上消除了漂移的可能性。存储的类型签名接受 `float array` 入、返回 `float array` 结果。里面没有 embed 调用。embedding 模型唯一的所在是 `Runtime.services.embeddings`，在运行时创建时注入一次。调用方 `Runtime.invoke_with_rag` 用这一个服务对文档（索引时）和查询（搜索时）做嵌入。两个不同的模型不可能溜进来，因为整个运行时只有一个 embedding 服务句柄。

完整推理在 `docs/plans/b2-vector-store-design.md` 中。简短版本：PAR 评估了三个选项（embedding 耦合、embedding 无关、双层 functor），选了 embedding 无关，因为它消除了漂移这一类问题，代价只是在已经存在的唯一编排点加约五行组合代码。存储可以用手工构造的向量轻松测试，无需 mock embedding。接口可以直接移植到 Qdrant、Milvus 或 pgvector，因为它们都接受原始向量。

## 为什么选 sqlite-vec

PAR 发布的第一个向量后端是 [sqlite-vec](https://github.com/asg017/sqlite-vec)，一个 SQLite 扩展，添加 `vec0` 虚拟表类型用于向量存储和 KNN 搜索。这个选择是深思熟虑的，备选方案也确实存在。

| 选项 | 考虑原因 | 不选原因（v0.5.1） |
|------|----------|-------------------|
| sqlite-vec | 嵌入式，无服务器，以可加载 `.so`/`.dylib` 形式发布，在 opam-repository 路径上。 | 选定。 |
| Qdrant | 专用向量数据库，快，可过滤。 | 需要单独的服务器进程。增加运维依赖。更适合 v0.5.4+ 外部存储落地时。 |
| Milvus | 分布式，可扩展到数十亿向量。 | 重量级。对 PAR 首先瞄准的单进程、单机场景过于复杂。 |
| Pinecone | 托管服务，零运维。 | 仅云端，外部依赖，供应商锁定。与 PAR 本地优先的理念冲突。 |

sqlite-vec 胜出有三个原因。第一，它是嵌入式的。用 `par ask` 或 Python quickstart 本地运行的 PAR 用户无需启动第二个服务就能获得 RAG。扩展通过 SQLite 的 `enable_load_extension` 加载，`Vector_store.create` 调用它。第二，它覆盖了主要场景：每个节点数千到低百万级向量，基于余弦相似度的 KNN，单进程。这大约是真实 RAG 工作负载的 80%。第三，它保持依赖面很小。`vec0.so` 二进制文件在仓库的 `vendor/sqlite-vec/` 下发布，版本锁定（v0.1.9），OCaml 侧通过 PAR 已经用于事件持久化的标准 SQLite3 绑定与其通信。

存储拥有自己的 SQLite 连接，与事件持久化连接分开。这是有意为之。sqlite-vec 需要在原始 `Sqlite3.db` 句柄上启用 `enable_load_extension`，而持久化后端的抽象 `t` 不暴露这个能力。给向量存储独立的连接让扩展加载需求局部化到向量路径，避免泄漏持久化内部细节。

## Score 语义

`Vector_store.search` 返回 `search_result` 记录，其 `score` 字段是范围在 `[-1.0, 1.0]` 的余弦相似度，值越高表示越相似。内部 sqlite-vec 存储的是余弦*距离*（0 表示完全相同）。PAR 在边界做转换：`score = 1.0 - distance`。这个归一化很重要，因为大多数 RAG 提示逻辑和大多数 embedding 模型文档用的是相似度而非距离。直接暴露相似度意味着调用方不需要记住底层引擎选了哪种约定。

## 分块策略：三种

文档很少短到能作为一个向量嵌入。长文本被分成 chunks，每个独立嵌入，这样检索可以返回相关段落而非整个文档。PAR 在 `lib/core/chunking.mli` 中提供三种分块策略，都是纯函数，无 I/O，无分词器依赖。

`chunk_by_chars` 是粗暴工具。它用 `max_size` 字符的窗口滑过文本，相邻 chunk 之间共享 `overlap` 字符。步长是 `max_size - overlap`。可预测、快速、不了解结构。适合日志和平坦文本。

`chunk_by_tokens` 用空白分割近似 token 级分块：一个空白分隔的词算一个 token。这是近似，因为真正的分词器（tiktoken、Claude 分词器、SentencePiece）会把词拆成子词单元。要精确 token 计数，调用方应该用 provider 的分词器预分词，然后把拼接后的 token 传给 `chunk_by_chars`。近似模式存在是因为为每个 provider 引入分词器是沉重依赖，而近似在大多数情况下对检索质量足够接近。`chunking.mli` 的文档字符串明确说明了这一点，调用方不会把近似误认为精确。

`chunk_recursive` 是 LangChain `RecursiveCharacterTextSplitter` 的算法，语义保留。它按顺序尝试一组分隔符，默认 `["\n\n"; "\n"; " "; ""]`：先段落分隔，再换行，再空格，再逐字符。对每个片段，如果放进 `max_size` 就保留；否则用下一个更细的分隔符递归。结果比固定窗口分块更好地尊重文档结构：段落尽可能保持完整，句子不会在词中间被切断，除非 chunk 真的是一大段连续文本。PAR 刻意不继承 LangChain 的 `chunk_size=4000, chunk_overlap=200` 默认值；调用方必须指定 `max_size` 和 `overlap`。这么大的默认值隐藏了成本，PAR 的类型纪律延伸到让调用方自己掌控分块参数。

三种策略都返回 `chunk list`，每个 chunk 携带 `start_pos` 和 `end_pos` 偏移量指向原始文本。这些偏移量对引用很重要：检索返回一个 chunk 时，调用方可以指出它来自源文档的什么位置。

## 三阶段检索管道

`Runtime.invoke_with_rag` 是一切组合的地方。管道是三个阶段，直线流程，无分支。

```
阶段 1: embed
  Runtime.embed rt [query_message]
     │  使用 rt.services.embeddings（唯一的 embedding 句柄）
     ▼
  query_vector : float array

阶段 2: search
  Vector_store.search rt.services.vstore ~query:query_vector ~k
     │  基于 vec0 虚拟表的余弦 KNN
     ▼
  hits : search_result list（按 score 降序排列）

阶段 3: augment
  build_rag_prompt query_message hits
     │  把检索到的上下文注入 system prompt
     ▼
  Runtime.invoke rt ~agent_id ~message:augmented_prompt
```

阶段一用运行时的 embedding 服务嵌入查询。阶段二用该向量搜索向量存储。阶段三构建包含检索上下文的提示并调用 agent。返回值是 `(answer, retrieved_documents)`，调用方可以向用户展示哪些段落支撑了回答。

这个管道最重要的属性是：同一个 embedding 服务句柄在阶段一（查询）和索引时（文档，通过 `Runtime.add_documents` 或 OCaml `Vector_store.add` 路径）使用。因为只有一个句柄，漂移不可表示。这就是 embedding 无关存储决策的回报。如果存储自带 embedding 模型，这个保证需要纪律而非类型。

`invoke_with_rag` 上的 `?vector_store` 为 `None` 时，调用退化为普通 `Runtime.invoke`。无嵌入、无搜索、无增强。这让调用方可以写一条代码路径，根据是否配置了存储有条件地使用 RAG，无需在每个调用点加分支逻辑。

## Embedding provider 支持

Embedding 支持因 LLM provider 而异，运行时坦诚地暴露了差异而非隐藏它。

| Provider | Embedding 支持 |
|----------|----------------|
| OpenAI（`text-embedding-3-small`，1536 维度） | 完整支持。RAG 的默认选择。 |
| Anthropic | 抛出 `Embedding_unsupported`。Anthropic 没有 embeddings API。即使你用 Claude 做生成，也请用 OpenAI 做嵌入。 |
| Ollama | 通过 OpenAI 兼容的 `/v1/embeddings` 端点。本地模型。 |
| Mock | 基于哈希的确定性向量，用于测试检索管道而无需网络调用。 |

运行时不静默回退。如果你把 Anthropic 配置为唯一 provider 并调用 `Runtime.embed`，会得到 `Embedding_unsupported`。错误就是信号。隐藏它会让配置错误的服务返回空向量，产生一个看起来能用但实际损坏的 RAG 管道。

## 尚未实现的部分

PAR 的 RAG 基础设施是刻意限定范围的。三件事在路线图上但不在 v0.5.1 中。

**外部向量存储。** Qdrant 和 Milvus 支持计划在 v0.5.5 及以后。embedding 无关的 `Vector_store` 接口设计使得添加它们只需替换 `type t` 实现；搜索和添加签名保持不变。未来的 `module type VECTOR_STORE`（镜像现有的 `LLM_SERVICE` 模块类型）将在有第二个实现需要抽象时引入。在此之前，一个接口加一个后端是正确的泛化程度。

**文档加载器。** PAR 分块接收原始文本。它不解析 PDF、HTML、Markdown frontmatter 或任何结构化文档格式。未来版本计划文档加载器层，把常见格式转换为分块器期望的文本字符串。目前由调用方转换。这让分块器保持纯粹和可测试，也为只有纯文本的用户避免引入一森林的格式特定依赖。

**混合搜索。** 纯向量检索可能漏掉精确匹配查询（包含用户搜索的字面字符串的文档可能不是嵌入空间中的最近邻）。BM25 加向量重排序是标准修复。PAR 的 `search` 签名有空间容纳未来的 `hybrid_search` 扩展而不扰动核心接口，但尚未实现。

贯穿始终的是每个缺口都是增量的。embedding 无关的存储、sqlite-vec 后端和三阶段管道是脊柱。其他一切都插入脊柱而不需要重写它。

## 另请参阅

- [RAG API 参考](../sdk/rag.md) 函数签名和 provider 支持表
- [B.2 向量存储设计](../plans/b2-vector-store-design.md) 产生 embedding 无关决策的完整 Option A/B/C 评估
- [架构](architecture.md) RAG 服务如何融入 `Runtime.services` 注册表，与 LLM、持久化和事件总线并列
- [并发模型](concurrency-model.md) embedding API 调用（网络 I/O）如何与运行时的 fiber 协作
