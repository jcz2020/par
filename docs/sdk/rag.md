<!-- language: en -->

# RAG API Reference

> Added in v0.5.1. Source-of-truth: the OCaml types in `lib/core/types.ml`, `lib/core/vector_store.mli`, and `lib/core/chunking.mli`. The Python binding ships the same surface via FFI. Phases B.2 (vector store), B.3 (chunking), and C.3 (Python FFI) implement this document.

PAR's RAG (Retrieval-Augmented Generation) pipeline grounds LLM responses in your own documents. You embed text into vectors, store them in a local vector index, and at query time retrieve the chunks most similar to the question. The retrieved chunks go into the prompt as context before the LLM answers.

This page covers both surfaces. The Python binding (`pip install par-runtime`) is the faster path for most users and supports the full RAG loop end to end. The OCaml SDK exposes the same loop with direct, type-safe access to the `Vector_store` and `Chunking` modules for callers who want to manage indexing themselves.

The pipeline has four parts: **Embeddings** (convert text to vectors), **Vector Store** (store and search vectors), **Chunking** (split long documents), and **RAG Invocation** (compose all three into a grounded query).

## Why the vector store is embedding-agnostic

PAR's vector store accepts pre-computed float arrays. It does not know which embedding model produced the vectors, and it does not call the model itself. The caller is responsible for embedding both documents and queries using the same model.

This is a deliberate choice. The silent-failure mode in RAG is embedding-model drift: you index documents with model A, then query with model B, and retrieval quality collapses with no error surfaced. By forcing the caller to own the embedding step, PAR makes it natural to keep one model name in a single place and route both indexing and querying through it. The tradeoff is one extra line of code at the call site.

A consequence: if you change embedding models, you must reindex every document. See Persistence and Reindexing below.

## Embedding provider support matrix

Embeddings are a separate capability from chat completions. A provider can support chat but not embeddings. The matrix below is the authoritative answer to "can I embed with this provider?" in v0.5.1.

| Provider | Embeddings | Default model | Dimension | Notes |
|----------|-----------|---------------|-----------|-------|
| `` `Openai `` | Yes | `text-embedding-3-small` | 1536 | Full support. Override the model in the provider config. Returns cosine-similar vectors. |
| `` `Anthropic `` | No | n/a | n/a | Anthropic ships no embeddings API. `embed` returns `Error Embedding_unsupported` unconditionally. Use OpenAI, Ollama, or Mock for the embedding step; you can still use Anthropic for the chat completion in `invoke_with_rag`. |
| `` `Ollama `` | Yes | `nomic-embed-text` (recommended) | model-dependent | Works via OpenAI-compatible endpoint (`/v1/embeddings`). Point the OpenAI provider's `base_url` at your Ollama instance and pick an embedding model. Dimensions depend on the model; match `dimension` in `Vector_store.create` to the model's output. |
| `` `Mock `` | Yes | deterministic hash vector | 1536 | Deterministic hash-based vectors for tests. Same input string always yields the same vector, so unit tests are reproducible. Not useful for real retrieval. |

If you call `embed` on a provider that returns `Embedding_unsupported`, the error surfaces as `PARError` in Python and as `Error Embedding_unsupported` in OCaml. The recovery is to configure a provider that supports embeddings.

## Python SDK

### Quick start: end-to-end RAG

This example indexes three short documents, asks a question, and prints the grounded answer. It uses the Mock provider so it runs without an API key. To use real embeddings, swap the provider block for OpenAI (commented inline).

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

Key points the example demonstrates:

- One provider block handles both embedding and chat. You do not configure them separately.
- `add_documents` takes plain strings for the common case, or dicts when you need stable ids or metadata for filtering.
- `invoke_with_rag` returns the same JSON string shape as `invoke`. Parse it with `json.loads` to pull out the assistant message and any tool calls.
- `k=2` retrieves the two most similar chunks. The default is `k=4`. Higher k means more context but a longer prompt; tune against your document set.

### Multi-document indexing

When you have more than a handful of documents, pass dicts with explicit ids and metadata. The id lets you update or delete a document later without touching the others. The metadata is stored alongside the vector and returned in search results, so you can filter or display provenance.

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

Two practical notes on indexing at scale. First, embed in batches. The OpenAI embeddings endpoint accepts multiple inputs per request and `Runtime.embed` already batches; `add_documents` does the same internally. If you are indexing thousands of documents via the OCaml SDK, chunk your list into batches of 100 to 500 to keep request sizes reasonable. Second, prefer stable ids. If you reindex by adding documents with new ids, the old entries stay behind and dilute retrieval quality. Use the same ids across reindex runs so `add` upserts in place.

### Persistence and reindexing

The Python binding's vector store lives in process memory by default (`":memory:"` SQLite). It does not survive a process restart. To persist across runs in Python today, re-index on startup or serialize your document set to disk and reload.

The OCaml SDK gives you explicit control. Pass a real file path to `Vector_store.create ~db_path:"/var/lib/par/vectors.db"`. The sqlite-vec index then persists across process restarts. Reopening the store with the same path and dimension reloads the existing vectors; you do not reindex on every boot.

When to reindex:

- **You changed the embedding model.** Different models produce vectors in different spaces. Cosine similarity across mixed-model vectors is meaningless. Wipe the store (`Vector_store.delete` by id, or delete the db file) and reembed every document.
- **You changed the dimension.** `Vector_store.create` pins the dimension at creation time. Adding vectors of a different dimension fails. Recreate the store with the new dimension and reindex.
- **Your document corpus changed substantially.** If more than ~30 percent of documents are new or removed, a clean reindex often beats incremental adds for retrieval quality. Incremental adds are fine for small appends.

You do not need to reindex when: you change the chat model (embeddings and chat are decoupled), you change `k`, or you restart the process against a persistent db file.

## OCaml SDK reference

The OCaml surface is the source of truth. Every Python method maps to an OCaml function via FFI, so the signatures below are what the runtime actually does.

### Embeddings

```ocaml
open Par
open Types

let embed rt messages =
  Runtime.embed rt messages
(* val embed : Runtime.t -> string list ->
 *   (float array list, error_category) result *)
```

`Runtime.embed` takes a list of strings and returns a list of float arrays (one vector per input), or an `error_category`. Provider behavior matches the matrix above. On OpenAI, network failures come back as `External_failure`, request timeouts as `Timeout`, and a missing API key as `Invalid_input`.

### Vector store

The `Vector_store` module is the persistence layer. It is embedding-agnostic: it stores `(document, float array)` pairs and returns them ranked by cosine similarity.

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

The full signature:

| Function | Signature | Purpose |
|----------|-----------|---------|
| `create` | `db_path:string -> vec_extension_path:string -> dimension:int -> unit -> (t, error_category) result` | Open or create a store. `db_path ":memory:"` is ephemeral; a file path persists. `dimension` must match your embedding model. |
| `add` | `t -> (document * float array) list -> (unit, error_category) result` | Insert or upsert documents. The `document.id` is the primary key; adding an existing id replaces the vector. |
| `search` | `t -> query:float array -> k:int -> (search_result list, error_category) result` | Return the top-k documents by cosine similarity, highest score first. |
| `delete` | `t -> ids:string list -> (unit, error_category) result` | Remove documents by id. |
| `close` | `t -> unit` | Close the underlying SQLite handle. Safe to call once at shutdown. |

`score` is cosine similarity in `[-1.0, 1.0]`; higher means more similar. The `document` record carries `id : string`, `content : string`, and `metadata : Yojson.Safe.t option`. Metadata is opaque to the store; it rides along on every search result so the caller can filter or display provenance.

### Vector store backends

Since v0.7.5, PAR supports two vector store backends:

| Backend | Implementation | External deps | Platform | Use case |
|---------|---------------|---------------|----------|----------|
| **sqlite-vec** | SQLite with vec0 extension | C extension (`vec0.so`/`.dll`/`.dylib`) | Linux x86_64, macOS arm64 | Production with persistence |
| **HNSW** | Pure OCaml HNSW graph | None | All platforms (including Windows) | Portability, zero deps |

**sqlite-vec** (default) uses SQLite with the vec0 C extension for vector similarity search. It requires the `vec0.so` (or platform equivalent) shared library. This is the recommended backend for production use on supported platforms.

**HNSW** is a pure OCaml implementation of the Hierarchical Navigable Small World algorithm (Malkov & Yashunin, TPAMI 2020). It requires zero external dependencies and works on all platforms, including Windows where the vec0 extension was problematic. It stores vectors in memory with optional file persistence.

To use the HNSW backend:

```ocaml
open Par

let config : Types.vector_store_backend = Vs_hnsw {
  persist_path = None;       (* or Some "/path/to/index.bin" for persistence *)
  dimension = 1536;
  m = 16;                    (* max edges per node, default 16 *)
  ef_construction = 200;     (* insert search width, default 200 *)
  ef_search = 50;            (* query search width, default 50 *)
}

match Vector_store.create_for_backend config with
| Ok store -> (* use store with add/search/delete/close *)
| Error e -> (* handle error *)
```

To use via `Runtime.create`:

```ocaml
let backend = Types.Vs_hnsw {
  persist_path = Some "/tmp/my_index.bin";
  dimension = 1536; m = 16; ef_construction = 200; ef_search = 50;
} in
match Runtime.create ~vector_store_backend:backend ~config switch with
| Ok rt -> (* rt.services.vector_store is set automatically *)
| Error e -> ...
```

When `?vector_store_backend` is passed to `Runtime.create`, the vector store is created and stored in the runtime. `Runtime.invoke_with_rag` will use it automatically when no explicit `?vector_store` is passed.

### Chunking

Long documents should be split before embedding. A 10,000-token PDF fed to the embedder in one piece produces a single vector that averages away every useful signal. Chunking turns one long document into many short ones, each with its own vector, so retrieval can land on the right passage.

```ocaml
open Par.Chunking

let chunks = chunk_recursive
  ~text:long_document
  ~max_size:1000
  ~overlap:200
(* chunks : chunk list = [{ text; start_pos; end_pos }] *)
```

Three strategies, all pure (no I/O, no provider coupling, no tokenizer dependency):

| Function | Strategy | When to use it |
|----------|----------|----------------|
| `chunk_by_chars` | Fixed-size sliding window over characters, `stride = max_size - overlap`. | Uniform documents where character count is a good proxy for semantic unit size. Simple and predictable. |
| `chunk_by_tokens` | Whitespace-tokenized sliding window. One word equals one token (approximate; no real tokenizer). | When you want roughly N words per chunk and do not need exact token counts. For accurate counts, pre-tokenize with the provider's tokenizer and call `chunk_by_chars` on the result. |
| `chunk_recursive` | LangChain `RecursiveCharacterTextSplitter`. Tries separators `["\n\n"; "\n"; " "; ""]` in order, falling through to finer splits when a piece exceeds `max_size`. | The default choice for prose, markdown, code comments. Respects paragraph and line boundaries first, so chunks stay readable. |

All three raise `Invalid_argument` if `max_size <= 0` or `overlap >= max_size`. The caller must specify `max_size` and `overlap`; this module does not inherit LangChain's `chunk_size=4000, chunk_overlap=200` defaults, because the right values depend on your embedding model's context window.

Typical values: `max_size=1000` and `overlap=200` for `text-embedding-3-small` (which accepts up to 8191 tokens). The overlap keeps context across chunk boundaries so a retrieval hit near the edge still carries neighboring text.

### RAG invocation

`Runtime.invoke_with_rag` is the one-call composition of embed, search, augment, and invoke.

```ocaml
let (answer, retrieved_docs) =
  Runtime.invoke_with_rag rt
    ~agent_id:"my_agent"
    ~message:"What is PAR?"
    ~k:4
    ~vector_store:(Some store)
    ()
```

The pipeline, in order:

1. Embed the query message using the runtime's configured embedding provider.
2. Search the vector store for the top-k most similar documents.
3. Augment the agent's system prompt with the retrieved context, formatted as a context block.
4. Invoke the agent with the augmented prompt via the normal `Runtime.invoke` path.
5. Return `(answer, retrieved_documents)` so the caller can display provenance or log what was retrieved.

If `?vector_store` is `None`, `invoke_with_rag` falls back to plain `Runtime.invoke` with no retrieval. This lets you toggle RAG on and off by passing `Some store` or `None` without changing the call shape.

## Error category reference

Every RAG operation that can fail returns `( _, error_category) result` in OCaml, or raises `PARError` in Python. The seven `error_category` variants cover the full failure surface. Use this table to write recovery logic.

| Variant | When it occurs in RAG | Recovery |
|---------|----------------------|----------|
| `Embedding_unsupported` | You called `embed` or `add_documents` on a provider with no embeddings API (Anthropic). | Switch the embedding provider to OpenAI, Ollama, or Mock. You can keep Anthropic for the chat step in `invoke_with_rag`. |
| `Invalid_input of string` | Empty API key, `max_size <= 0` or `overlap >= max_size` in chunking, malformed embedding response from the provider, vector dimension mismatch on `Vector_store.add`. | The string carries the detail. Fix the input and retry. This is not a transient error; retrying without a change will fail the same way. |
| `External_failure of string` | Network error during the embedding HTTP request, provider returned a non-200 status that is not a rate limit or auth error, sqlite-vec extension failed to load. | Check network connectivity and provider status. For the extension path, verify `vec_extension_path` points at a file that exists and matches your platform. Transient; retry with backoff is reasonable. |
| `Rate_limited` | Provider returned 429. | Back off and retry. Implement exponential backoff with jitter. PAR's Retry middleware can handle this if the call goes through an agent. |
| `Permission_denied of string` | Bad or expired API key (401/403). | Refresh credentials. Not transient. |
| `Timeout` | Embedding request or the LLM call inside `invoke_with_rag` exceeded the configured timeout. | Retry once. If it persists, raise the timeout or reduce batch size for embeddings. |
| `Internal of string` | Unexpected OCaml exception, network handle not initialized (OpenAI provider `set_network` not called), or a bug. | Check that the runtime was created through `Runtime.create` (which wires the network). If the call path is correct and this persists, it is likely a bug worth filing. |

In Python, all of these surface as `PARError` with a message string. The variant is not preserved across the FFI boundary in v0.5.1; match on the message text if you need to branch. In OCaml, pattern match on the variant directly.

## Usage examples

Three runnable OCaml examples covering the patterns you will actually need: a basic embedding sanity check, document indexing with chunking, and a full RAG question-answering call.

### Example 1: basic embedding sanity check

Confirm the embedding provider is wired correctly before building anything larger. One string in, one vector out, print the dimension.

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

If this prints `Vector has 1536 dimensions`, OpenAI or Mock is working. If it prints `embed failed: embedding_unsupported`, you are pointing at Anthropic; reconfigure. If it prints `embed failed: api_key must not be empty`, set your API key.

### Example 2: chunk and index a long document

Split a long document with `chunk_recursive`, embed the chunks, and insert them into the vector store with generated ids. This is the indexing loop you will wrap around every document source.

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

The generated ids (`chunk_0000`, `chunk_0001`, ...) are deterministic for a given input text. If you reindex the same document, the ids match and the store upserts in place rather than duplicating.

### Example 3: RAG question answering

The payoff. With documents indexed, a grounded query is one call.

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

The retrieved documents come back with their scores so you can show provenance in a UI, log what was retrieved for debugging, or apply a score threshold before trusting the answer.

## Limitations

- **Python vector store is in-memory.** The Python binding's `add_documents` creates an ephemeral store. Persistence across process restarts requires the OCaml SDK with a file path, or reindexing on startup. File-backed persistence from Python is a future candidate.
- **No metadata filtering from Python.** Metadata is stored and returned on search results, but the Python binding does not expose a filter parameter on `invoke_with_rag` or `add_documents`. Filtering lands with the external vector store support in a future version.
- **No external vector stores yet.** The store is sqlite-vec only. Qdrant and Milvus support is on the roadmap for workloads that outgrow a single-process SQLite index.
- **No streaming RAG.** `invoke_with_rag` returns the full answer. A streaming variant (`invoke_with_rag_streaming`) is deferred until the base streaming surface stabilizes; see the Streaming API page.
- **Chunking has no real tokenizer.** `chunk_by_tokens` treats one whitespace-separated word as one token. For accurate token-based chunking, pre-tokenize with the provider's tokenizer and pass the result to `chunk_by_chars`.
- **Dimension is fixed at store creation.** Changing embedding models almost always changes the dimension. You must recreate the store and reindex; see Persistence and Reindexing.

## See also

- [Agent API](agent.md) - `Runtime.invoke`, `agent_config`, the non-RAG entrypoint
- [Streaming API](streaming.md) - `invoke_stream`, Event types, the chunked output surface
- [Workflow API](workflow.md) - sequential, parallel, conditional orchestration
- [Overview](overview.md) - SDK architecture and module map
