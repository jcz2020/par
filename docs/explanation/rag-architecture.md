<!-- language: en -->

# RAG Architecture

> **Note (v0.6.7):** The `par ask` reference early in this article is historical (the CLI was removed). The RAG pipeline — embeddings, vector store, retrieval — is unchanged and exposed via `Runtime.invoke_with_rag`. See [RAG reference](../sdk/rag.md).

RAG, retrieval-augmented generation, is the pattern of grounding an LLM's answer in your own documents: embed the documents, store the vectors, search for the ones closest to the query, and hand the retrieved context to the LLM as part of the prompt. PAR shipped a RAG foundation in v0.5.1. This document explains the design decisions behind that foundation, why the vector store is embedding-agnostic, why sqlite-vec was the first backend, and how the three-phase retrieval pipeline is wired. For the API signatures, read the [RAG reference](../sdk/rag.md) at `docs/sdk/rag.md`. Here we cover the *why*.

## The decision that shaped everything: embedding-agnostic storage

The single most consequential design choice in PAR's RAG stack is that `Vector_store` knows nothing about embeddings. It stores documents paired with pre-computed `float array` vectors. It searches with a query vector you hand it. It never calls an embedding model itself.

This is not the obvious choice. LangChain's `FAISS` pattern and most Python RAG tutorials couple the vector store to an embedding model: you inject the embeddings at store creation, and the store embeds documents and queries internally. That is ergonomic for the simple case. It is also the source of the most common RAG bug.

The bug is embedding-model drift. If the vectors stored for your documents were produced by model A, and the query vector is produced by model B, the cosine similarities are meaningless. The store returns garbage results with no error signal. You find out when a user complains that retrieval is broken. In a coupled store, this happens whenever someone changes the configured embedding model and forgets to re-index, or when two code paths construct stores with different models, or when a query sneaks in through a path that defaults to a different model.

PAR's `Vector_store` makes drift impossible by construction. The store's type signature takes `float array` in and returns `float array` results. There is no embed call inside it. The only place an embedding model lives is `Runtime.services.embeddings`, injected once at runtime creation. The caller, `Runtime.invoke_with_rag`, uses that one service to embed both documents (at index time) and the query (at search time). Two different models cannot sneak in, because there is only one handle to an embedding service in the whole runtime.

PAR evaluated three options (embedding-coupled, embedding-agnostic, two-layer functor) and picked embedding-agnostic because it eliminates the drift class for the cost of about five lines of composition at the single orchestration site that already exists. The store is trivially testable with hand-crafted vectors, no mock embeddings needed. And the interface ports verbatim to Qdrant, Milvus, or pgvector in a future version, because all of them accept raw vectors.

## Why sqlite-vec

The first vector backend PAR ships is [sqlite-vec](https://github.com/asg017/sqlite-vec), a SQLite extension that adds a `vec0` virtual table type for vector storage and KNN search. The choice was deliberate, and the alternatives were real.

| Option | Why considered | Why not (for v0.5.1) |
|---------|---------------|---------------------|
| sqlite-vec | Embedded, no server, ships as a loadable `.so`/`.dylib`, on opam-repository path. | Chosen. |
| Qdrant | Purpose-built vector DB, fast, filterable. | Requires a separate server process. Adds an operational dependency. Better fit for v0.5.4+ when external stores land. |
| Milvus | Distributed, scales to billions of vectors. | Heavy. Overkill for the single-process, single-machine use case PAR targets first. |
| Pinecone | Managed, zero ops. | Cloud-only, external dependency, vendor lock-in. Conflicts with PAR's local-first ethos. |

sqlite-vec won for three reasons. First, it is embedded. A PAR user running locally with `par ask` or a Python quickstart gets RAG without standing up a second service. The extension loads via SQLite's `enable_load_extension`, which `Vector_store.create` invokes. Second, it covers the dominant use case: thousands to low-millions of vectors per node, KNN over cosine similarity, single-process. That is roughly 80 percent of real RAG workloads. Third, it keeps the dependency surface small. The `vec0.so` binary ships in the repo under `vendor/sqlite-vec/`, version-pinned (v0.1.9), and the OCaml side talks to it through the standard SQLite3 bindings PAR already uses for event persistence.

The store owns its own SQLite connection, separate from the event-persistence connection. This is deliberate. sqlite-vec requires `enable_load_extension` on a raw `Sqlite3.db` handle, and the persistence backend's abstract `t` does not expose that. Giving the vector store its own connection keeps the extension-loading requirement local to the vector path and avoids leaking persistence internals.

## Score semantics

`Vector_store.search` returns `search_result` records whose `score` field is cosine similarity in the range `[-1.0, 1.0]`, where higher means more similar. Internally, sqlite-vec stores cosine *distance* (0 means identical). PAR converts at the boundary: `score = 1.0 - distance`. This normalization matters because most RAG prompting logic and most embedding-model documentation talk in terms of similarity, not distance. Exposing similarity directly means the caller does not have to remember which convention the underlying engine picked.

## Chunking: three strategies

A document is rarely short enough to embed as a single vector. Long text gets split into chunks, each embedded independently, so retrieval can surface the relevant passage rather than the whole document. PAR provides three chunking strategies in `lib/core/chunking.mli`, all pure functions with no I/O and no tokenizer dependency.

`chunk_by_chars` is the blunt instrument. It slides a window of `max_size` characters across the text with `overlap` characters shared between consecutive chunks. The stride is `max_size - overlap`. Predictable, fast, and unaware of structure. Good for logs and flat text.

`chunk_by_tokens` approximates token-based chunking using whitespace splitting: one whitespace-separated word counts as one token. This is an approximation because real tokenizers (tiktoken, the Claude tokenizer, SentencePiece) split words into subword units. For accurate token counts, the caller should pre-tokenize with the provider's tokenizer and then pass the concatenated tokens to `chunk_by_chars`. The approximate mode exists because pulling in a tokenizer per provider is a heavy dependency, and the approximation is close enough for retrieval quality in most cases. The `chunking.mli` docstring says this explicitly so callers do not mistake the approximation for precision.

`chunk_recursive` is the LangChain `RecursiveCharacterTextSplitter` algorithm, semantics preserved. It tries a list of separators in order, defaulting to `["\n\n"; "\n"; " "; ""]`: paragraph breaks first, then line breaks, then spaces, then individual characters. For each piece, if it fits in `max_size`, keep it; if not, recurse with the next finer separator. The result respects document structure better than fixed-size windowing: paragraphs stay together when they can, sentences are not split mid-word unless a chunk is genuinely one giant run of text. PAR deliberately does not inherit LangChain's `chunk_size=4000, chunk_overlap=200` defaults; the caller must specify `max_size` and `overlap`. Defaults that large hide cost from the caller, and PAR's type discipline extends to making the caller own their chunking parameters.

All three return `chunk list` where each chunk carries `start_pos` and `end_pos` offsets into the original text. Those offsets matter for citation: when retrieval surfaces a chunk, the caller can point back to where in the source document it came from.

## The three-phase retrieval pipeline

`Runtime.invoke_with_rag` is where everything composes. The pipeline is three phases, straight-line, no branching.

```
phase 1: embed
  Runtime.embed rt [query_message]
     │  uses rt.services.embeddings (the single embedding handle)
     ▼
  query_vector : float array

phase 2: search
  Vector_store.search rt.services.vstore ~query:query_vector ~k
     │  cosine KNN over the vec0 virtual table
     ▼
  hits : search_result list  (ranked by descending score)

phase 3: augment
  build_rag_prompt query_message hits
     │  inject retrieved context into the system prompt
     ▼
  Runtime.invoke rt ~agent_id ~message:augmented_prompt
```

Phase one embeds the query using the runtime's embedding service. Phase two searches the vector store with that vector. Phase three builds a prompt that includes the retrieved context and invokes the agent. The return is `(answer, retrieved_documents)`, so the caller can show the user which passages grounded the answer.

The single most important property of this pipeline is that the *same* embedding service handle is used in phase one (for the query) and at index time (for the documents, via `Runtime.add_documents` or the OCaml `Vector_store.add` path). Because there is one handle, drift is unrepresentable. This is the payoff of the embedding-agnostic store decision. If the store had its own embedding model, this guarantee would require discipline instead of types.

If `?vector_store` is `None` on `invoke_with_rag`, the call degrades to plain `Runtime.invoke`. No embedding, no search, no augmentation. This lets a caller write one code path that conditionally uses RAG based on whether a store is configured, without branching logic at every call site.

## Embedding provider support

Embedding support varies by LLM provider, and the runtime surfaces the variation honestly rather than hiding it.

| Provider | Embedding support |
|----------|-------------------|
| OpenAI (`text-embedding-3-small`, 1536 dimensions) | Full. The default for RAG. |
| Anthropic | Raises `Embedding_unsupported`. Anthropic has no embeddings API. Use OpenAI for embeddings even if you use Claude for generation. |
| Ollama | Via OpenAI-compatible `/v1/embeddings` endpoint. Local models. |
| Mock | Deterministic hash-based vectors, for testing the retrieval pipeline without network calls. |

The runtime does not silently fall back. If you configure Anthropic as your only provider and call `Runtime.embed`, you get `Embedding_unsupported`. The error is the signal. Hiding it would let a misconfigured service return empty vectors and produce a broken RAG pipeline that looks like it works.

## What is not here yet

PAR's RAG foundation is deliberately scoped. Three things are on the roadmap but not yet shipped.

**External vector stores.** Qdrant and Milvus support is planned for v0.5.5 and later. The embedding-agnostic `Vector_store` interface is designed so that adding them means swapping the `type t` implementation; the search and add signatures stay the same. A future `module type VECTOR_STORE`, mirroring the existing `LLM_SERVICE` module type, will abstract the backend when there is a second implementation to motivate the abstraction. Until then, one interface and one backend is the right amount of generality.

**Document loaders.** Shipped in v0.7.0. The `lib/documents/` module provides `Document.t` (a record of `content` + `metadata` + `source`) and a `LOADER` module type. Five built-in loaders convert PDF (via camlpdf `Pdftext`), Markdown (with YAML frontmatter via `omd` + `Yaml`), HTML (via `lambdasoup`), CSV (row-per-Document), and plain text into `Document.t` lists. `Directory_loader` dispatches by extension. Each loader goes through `Workspace.admit` for path safety. This closes the gap between real files and the chunker's text input without coupling the chunker to format-specific dependencies. See [Document Loaders](../sdk/document_loaders.md) for the API and the composition pattern with `Chunking` + `Vector_store`. The chunker itself stays pure and format-agnostic — loaders convert, the chunker splits, the two compose.

**Hybrid search.** Pure vector retrieval can miss exact-match queries (a document containing the literal string the user searched for may not be the nearest neighbor in embedding space). BM25 plus vector reranking is the standard fix. PAR's `search` signature has room for a future `hybrid_search` addition without perturbing the core surface, but it is not implemented yet.

The throughline is that each gap is additive. The embedding-agnostic store, the sqlite-vec backend, and the three-phase pipeline are the spine. Everything else plugs into the spine without rewriting it.

## See also

- [RAG API reference](../sdk/rag.md) for the function signatures and provider support table
- [Document Loaders](../sdk/document_loaders.md) for the v0.7.0 document-loader layer that feeds the chunker
- [Architecture](architecture.md) for how the RAG services fit into the `Runtime.services` registry alongside LLM, persistence, and event bus
- [Concurrency Model](concurrency-model.md) for how embedding API calls (network I/O) cooperate with the runtime's fibers
