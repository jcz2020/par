# RAG API Reference

> Added in v0.5.1. RAG (Retrieval-Augmented Generation) lets you ground LLM responses in your own documents by embedding text, storing vectors, and retrieving relevant context at query time.

PAR's RAG pipeline has four components: **Embeddings** (convert text to vectors), **Vector Store** (store and search vectors), **Chunking** (split long documents), and **RAG Invocation** (compose all three into a grounded query).

## OCaml SDK

### Embeddings

```ocaml
open Par
open Types

let embed rt messages =
  Runtime.embed rt messages
```

`Runtime.embed` takes a list of strings and returns a list of float arrays (one vector per input). Provider support:

| Provider | Status |
|----------|--------|
| OpenAI (`text-embedding-3-small`) | Full support |
| Anthropic | Raises `Embedding_unsupported` (no embeddings API) |
| Ollama | Via OpenAI-compatible endpoint (`/v1/embeddings`) |
| Mock | Deterministic hash-based vectors for testing |

### Vector Store

```ocaml
open Par.Vector_store

let store =
  create
    ~db_path:":memory:"
    ~vec_extension_path:"vendor/sqlite-vec/linux-x86_64/vec0.so"
    ~dimension:1536
    ()

let doc = { id = "doc1"; content = "PAR is an OCaml agent runtime"; metadata = None }
let vec = [| 0.1; 0.2; 0.3; ... |]  (* from Runtime.embed *)
let () = add store [(doc, vec)]

let results = search store ~query:query_vec ~k:4
(* results : search_result list = [{ doc; score }] *)
```

The vector store is **embedding-agnostic** — it accepts pre-computed float arrays. The caller is responsible for embedding both documents and queries using the same model. This eliminates the silent-failure mode of embedding-model drift.

`score` is cosine similarity in `[-1.0, 1.0]` (higher = more similar).

### Chunking

```ocaml
open Par.Chunking

let chunks = chunk_recursive
  ~text:long_document
  ~max_size:1000
  ~overlap:200

(* chunks : chunk list = [{ text; start_pos; end_pos }] *)
```

Three strategies:
- `chunk_by_chars` — fixed-size sliding window over characters
- `chunk_by_tokens` — whitespace-tokenized sliding window (approximate)
- `chunk_recursive` — LangChain RecursiveCharacterTextSplitter (tries `["\n\n"; "\n"; " "; ""]` in order)

### RAG Invocation

```ocaml
let (answer, retrieved_docs) =
  Runtime.invoke_with_rag rt
    ~agent_id:"my_agent"
    ~message:"What is PAR?"
    ~k:4
    ~vector_store:(Some store)
    ()
```

The pipeline:
1. Embed the query message
2. Search the vector store for top-k similar documents
3. Augment the system prompt with retrieved context
4. Invoke the agent with the augmented prompt
5. Return `(answer, retrieved_documents)`

If `?vector_store` is `None`, falls back to plain `Runtime.invoke` (no retrieval).

## Python SDK

### Streaming (fully functional)

See [Streaming API](streaming.md) for `invoke_stream` — fully implemented with 13 passing tests.

### Embeddings

```python
from par_runtime import Runtime
from par_runtime._errors import PARError

try:
    vecs = rt.embed(["hello", "world"])
    print(f"Got {len(vecs)} vectors, dim={len(vecs[0])}")
except PARError as e:
    print(f"Embedding not available: {e}")
```

`rt.embed()` calls the OCaml `Runtime.embed` via FFI. When an embedding provider is configured (OpenAI, Mock, or Ollama), returns real vectors. When no provider is configured, raises `PARError("embed failed: embeddings not initialized")`.

**Note**: In v0.5.1-beta, the Python binding's `par_init` does not automatically configure an embedding service. To use embeddings from Python, you need to configure a provider with an API key. The OCaml SDK handles this via `make_embedding_service` in the CLI.

### RAG Pipeline (OCaml SDK only in beta)

`add_documents` and `invoke_with_rag` are available in the OCaml SDK. Python FFI for these methods is planned for the stable release.

## Examples

### Example 1: Basic embedding (OCaml)

```ocaml
let () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun switch ->
      match Runtime.create ~config switch with
      | Ok rt ->
        (match Runtime.embed rt ["hello world"] with
         | Ok [vec] -> Printf.printf "Vector has %d dimensions\n" (Array.length vec)
         | _ -> prerr_endline "embed failed");
        ignore (Runtime.close rt)
      | Error e -> prerr_endline (Runtime.string_of_error_category e)))
```

### Example 2: Document indexing (OCaml)

```ocaml
let index_documents rt store docs =
  let chunks = Chunking.chunk_recursive
    ~text:(String.concat "\n\n" docs)
    ~max_size:1000 ~overlap:200 in
  let doc_vecs =
    match Runtime.embed rt (List.map (fun c -> c.text) chunks) with
    | Ok vecs ->
      List.mapi (fun i vec ->
        ({ Vector_store.id = Printf.sprintf "chunk_%d" i;
           content = (List.nth chunks i).text;
           metadata = None }, vec)) vecs
    | Error _ -> []
  in
  Vector_store.add store doc_vecs
```

### Example 3: RAG Q&A (OCaml)

```ocaml
let rag_qa rt store question =
  Runtime.invoke_with_rag rt
    ~agent_id:"assistant"
    ~message:question
    ~k:4
    ~vector_store:(Some store)
    ()
```

## See also

- [Agent API](agent.md) - `Runtime.invoke`, `agent_config`
- [Streaming API](streaming.md) - `invoke_stream`, Event types
- [Workflow API](workflow.md) - sequential, parallel, conditional orchestration
- [B.2 Vector Store Design](../plans/b2-vector-store-design.md) - embedding-agnostic rationale
