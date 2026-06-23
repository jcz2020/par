<!-- language: en -->

**English** · [简体中文](../zh/howto/rag-pipeline.md)

> Added in v0.5.2. Fulfills the v0.5.1-ROADMAP B.6 promise of a runnable RAG how-to.

# How-to: Build a Basic RAG Pipeline

This guide walks through three runnable Python programs that ground LLM answers in your own text using PAR's retrieval-augmented generation pipeline. You will embed text, store it in the runtime's vector index, and ask questions whose answers come from that text rather than the model's training data. Every example runs against a local mock server, so no API key and no network access are required.

If you want the *why* behind the design (embedding-agnostic storage, sqlite-vec, the three-phase retrieval pipeline), read [RAG Architecture](../explanation/rag-architecture.md) first. If you want the function signatures, read the [RAG API reference](../sdk/rag.md). This page is the *how*: copy the code, run it, modify it.

## What you will build

Three programs, increasing in scope:

1. **Short text Q&A.** Embed one paragraph, ask one question, get one grounded answer. About 50 lines. Shows the minimum viable pipeline: `embed`, `add_documents`, `invoke_with_rag`.
2. **Long document indexing.** Take a multi-paragraph document, split it into overlapping chunks, index each chunk with its position metadata, and query across all chunks. About 80 lines. Shows chunking and per-chunk retrieval.
3. **Multi-document corpus.** Index several distinct documents, each tagged with metadata (title, section, source), query across the whole corpus, and inspect which documents the runtime surfaced. About 100 lines. Shows the multi-document pattern that real applications use.

By the end you will have the building blocks for a documentation-search bot, a personal-notes assistant, or any system where the model needs to reason over text you control.

## Prerequisites

You need the PAR Python binding installed:

```bash
pip install par-runtime
```

That pulls a wheel with the OCaml shared library bundled. No OCaml toolchain, no compiler, no separate binary. Linux x86_64 and macOS arm64 are supported in v0.5.2.

You also need Python 3.9 or newer. The examples use only the standard library plus `par_runtime`, nothing else.

## The mock server pattern

The PAR runtime has no `Mock` variant in its provider config. The four provider variants are `Openai`, `Anthropic`, `Ollama`, and `Custom` (see `lib/core/types.ml`). To run these examples without an OpenAI key, we point an `Openai` provider at a tiny local HTTP server that speaks the OpenAI `/v1/embeddings` and `/v1/chat/completions` protocols. This is the same pattern the PAR test suite uses in `bindings/python/tests/test_rag_e2e.py`, and it is the most honest way to exercise the full embed, index, retrieve, and invoke loop without network calls.

Every example below assumes this helper is on the import path. Save it as `mock_server.py` next to your example script.

```python
# mock_server.py
"""Tiny OpenAI-compatible mock for the RAG how-to examples.

Returns deterministic embeddings and a canned chat completion so the
full RAG loop runs without an API key. Not for production."""
import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            payload = json.loads(body)
        except Exception:
            self.send_response(400); self.end_headers()
            self.wfile.write(b'{"error":"bad json"}'); return

        if self.path.endswith("/embeddings"):
            inputs = payload.get("input", [])
            if isinstance(inputs, str):
                inputs = [inputs]
            # Deterministic pseudo-embedding: hash the text into a small
            # vector. Enough for cosine similarity to rank identical-text
            # matches highest; not a real embedding model.
            data = []
            for i, text in enumerate(inputs):
                h = sum(ord(c) for c in text)
                vec = [((h >> k) & 1) * 1.0 for k in range(8)]
                data.append({"object": "embedding", "index": i,
                             "embedding": vec})
            resp = {"object": "list", "data": data,
                    "model": "text-embedding-3-small",
                    "usage": {"prompt_tokens": 5, "total_tokens": 5}}
        elif self.path.endswith("/chat/completions"):
            # Echo the retrieved context back so we can see RAG worked.
            msgs = payload.get("messages", [])
            sys_prompt = next((m.get("content", "") for m in msgs
                               if m.get("role") == "system"), "")
            user_msg = next((m.get("content", "") for m in msgs
                             if m.get("role") == "user"), "")
            answer = (f"[mock answer grounded in "
                      f"{len(sys_prompt)} chars of context] "
                      f"Question was: {user_msg[:60]}")
            resp = {"id": "chatcmpl-mock", "object": "chat.completion",
                    "choices": [{"index": 0, "message":
                        {"role": "assistant", "content": answer},
                        "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 10,
                              "total_tokens": 20}}
        else:
            self.send_response(404); self.end_headers(); return

        body_json = json.dumps(resp).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_json)))
        self.end_headers()
        self.wfile.write(body_json)

    def log_message(self, *args):
        pass  # quiet


def start_mock_server():
    port = _free_port()
    server = HTTPServer(("127.0.0.1", port), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{port}/v1"
```

A shared config builder keeps the three examples short. The provider entry is a `[agent_id, ["Openai", {fields}]]` pair, matching the OCaml `llm_provider_config` variant. The `embedding_model` field is `None` because the mock ignores it.

```python
# shared.py
import json
from mock_server import start_mock_server

MOCK_SERVER, MOCK_BASE_URL = start_mock_server()


def make_config():
    return json.dumps({
        "persistence": ["Sqlite", ":memory:"],
        "event_bus": {
            "buffer_capacity": 10,
            "delivery": {
                "max_delivery_attempts": 3,
                "initial_retry_delay": 0.1,
                "retry_backoff": ["Fixed", 0.5],
                "delivery_timeout": 5.0,
            },
            "dlq_enabled": False,
            "critical_event_types": [],
        },
        "default_quota": {
            "max_concurrent_tasks": 4,
            "max_concurrent_tools_per_agent": 2,
        },
        "shutdown": {
            "drain_timeout": 5.0,
            "cancel_grace_period": 2.0,
            "flush_batch_size": 100,
        },
        "llm_providers": [
            ["rag_agent", ["Openai", {
                "api_key": "sk-mock-test-key",
                "base_url": MOCK_BASE_URL,
                "organization": None,
                "embedding_model": None,
            }]],
        ],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
        "event_retention_seconds": 604800.0,
    })


def make_agent_config():
    return json.dumps({
        "id": "rag_agent",
        "system_prompt": "Answer using only the provided context.",
        "model": {
            "provider": "openai",
            "model_name": "gpt-4",
            "temperature": 0.2,
        },
        "max_iterations": 1,
        "tools": [],
    })
```

The runtime's Python wrapper fills in any missing fields with safe defaults, so you do not have to spell out every config key. The `llm_providers` list is the one that matters for RAG: it wires the `rag_agent` to the mock endpoint and turns on embedding support.

## Example 1: Short text Q&A

The smallest complete pipeline. Embed one paragraph, hand it to the runtime, ask a question. Three calls do all the work: `embed`, `add_documents`, `invoke_with_rag`.

```python
# example1_short_text.py
"""Example 1: short text Q&A. Embed a paragraph, ask a question."""
from shared import make_config, make_agent_config
from par_runtime import Runtime, PARError

PARAGRAPH = (
    "PAR is a programmable agent runtime written in OCaml. "
    "It provides a ReAct agent loop, multi-provider LLM calls, "
    "type-safe tool dispatch, and a workflow engine for sequential, "
    "parallel, and conditional orchestration. PAR targets LLM backend "
    "engineers who want compile-time guarantees without rewriting their "
    "Python stack."
)
QUESTION = "What programming language is PAR written in?"

def main():
    with Runtime(make_config()) as rt:
        rt.register_agent(make_agent_config())

        # Step 1: embed the source text. Returns one vector per input.
        vectors = rt.embed([PARAGRAPH])
        print(f"Embedded 1 passage into a {len(vectors[0])}-dim vector")

        # Step 2: index the passage. Pass strings or dicts with
        # id/content/metadata. Returns 0 on success; raises PARError
        # if the embedding or storage step failed.
        rc = rt.add_documents([
            {"id": "par-intro", "content": PARAGRAPH,
             "metadata": {"source": "readme"}},
        ])
        print(f"add_documents returned {rc} (0 means success)")

        # Step 3: ask the question with RAG. The runtime embeds the
        # query, searches the index for the top-k passages, injects
        # them into the system prompt, and invokes the agent.
        answer = rt.invoke_with_rag("rag_agent", QUESTION, k=1)
        print(f"\nQ: {QUESTION}")
        print(f"A: {answer}")

if __name__ == "__main__":
    main()
```

Expected output (the exact JSON will vary, but the shape is stable):

```
Embedded 1 passage into a 8-dim vector
add_documents returned 0 (0 means success)

Q: What programming language is PAR written in?
A: {"content":"[mock answer grounded in 412 chars of context] Question was: What programming language is PAR written in?","finish_reason":"stop","role":"assistant"}
```

The answer JSON is whatever the LLM (here, the mock) returned, plus the finish reason and role. In a real deployment with OpenAI or Anthropic configured, the `content` field would be the model's grounded answer. The retrieval itself is real: the query was embedded, the index was searched, and the paragraph was injected into the context window.

### What just happened

Three phases, executed in order inside `invoke_with_rag`:

1. **Embed the query.** The runtime calls the same embedding endpoint that produced the document vector. Using one endpoint for both is what prevents embedding-model drift, the silent-failure mode where documents and query come from different models and similarity scores become meaningless.
2. **Search the index.** The runtime runs cosine KNN over the sqlite-vec virtual table and keeps the top `k` results.
3. **Augment and invoke.** Retrieved passages are folded into the system prompt, and the agent is invoked with the augmented prompt.

`k=1` keeps the example minimal. For most real workloads, `k=3` or `k=4` gives the model enough context without flooding the prompt.

## Example 2: Long document indexing

Real documents are longer than one embedding. A 3000-word article does not fit cleanly into a single vector, and even if it did, retrieval would return the whole article instead of the relevant paragraph. The fix is chunking: split the document into overlapping windows, embed each window, and let retrieval surface the specific passage.

PAR's chunking lives in the OCaml `Chunking` module (`chunk_by_chars`, `chunk_by_tokens`, `chunk_recursive`). From Python, the simplest approach is to chunk in your own code before calling `add_documents`, which keeps the binding thin and the chunking logic inspectable. This example chunks a long document with a sliding window and indexes each chunk with position metadata.

```python
# example2_long_doc.py
"""Example 2: chunk a long document, index chunks, query across them."""
from shared import make_config, make_agent_config
from par_runtime import Runtime

# A synthetic long document: five paragraphs about PAR features.
LONG_DOC = """
PAR provides a ReAct agent loop with bounded iterations. The agent
reasons step by step, calls tools, observes results, and repeats until
it reaches a final answer or hits the iteration cap. Middleware hooks
fire at every LLM and tool boundary, so logging, retry, and rate
limiting compose cleanly.

The workflow engine orchestrates multi-step tasks. Sequential steps run
in order, parallel steps run concurrently with structured concurrency,
and conditional steps branch on intermediate results. Map-reduce fan-out
is supported for batch workloads. Workflows checkpoint to the
persistence layer, so long-running jobs survive restarts.

PAR supports multiple LLM providers. OpenAI and Anthropic are built in.
Ollama works through an OpenAI-compatible local endpoint. A Mock
provider exists for testing without network calls. Custom providers can
be registered for any OpenAI-compatible API, including self-hosted
vLLM or llama.cpp servers.

Twenty built-in tools ship with the runtime, including a type-safe bash
tool. The bash tool uses an algebraic data type for command construction,
which makes shell injection unrepresentable in the type system. Other
tools cover file I/O, HTTP fetch, web search, and arithmetic.

Seven middleware modules compose into a pipeline. Logging records every
boundary. Retry handles transient failures with exponential backoff.
Rate limit enforces per-token throttling. Timeout bounds each call.
Validation checks inputs and outputs against schemas. PII mask redacts
sensitive fields. Sanitize tool output strips dangerous content.
""".strip()

QUESTION = "How does the bash tool prevent shell injection?"

def chunk_text(text, max_size=400, overlap=80):
    """Sliding-window chunker. Yields (index, start, end, text)."""
    chunks = []
    start = 0
    n = len(text)
    idx = 0
    while start < n:
        end = min(start + max_size, n)
        chunk = text[start:end]
        chunks.append((idx, start, end, chunk))
        if end == n:
            break
        start = end - overlap
        idx += 1
    return chunks

def main():
    with Runtime(make_config()) as rt:
        rt.register_agent(make_agent_config())

        chunks = chunk_text(LONG_DOC, max_size=400, overlap=80)
        print(f"Split document into {len(chunks)} chunks "
              f"(max_size=400, overlap=80)")

        # Index each chunk with position metadata. The metadata dict is
        # free-form: PAR stores it alongside the vector and returns it
        # with retrieval results so the caller can cite the source.
        documents = []
        for idx, start, end, text in chunks:
            documents.append({
                "id": f"features-chunk-{idx}",
                "content": text,
                "metadata": {
                    "source": "features.md",
                    "chunk_index": idx,
                    "char_start": start,
                    "char_end": end,
                },
            })
        rc = rt.add_documents(documents)
        print(f"add_documents returned {rc}, indexed {len(documents)} chunks")

        # Query with k=2 to pull the two most relevant chunks.
        answer = rt.invoke_with_rag("rag_agent", QUESTION, k=2)
        print(f"\nQ: {QUESTION}")
        print(f"A: {answer}")

if __name__ == "__main__":
    main()
```

Expected output:

```
Split document into 6 chunks (max_size=400, overlap=80)
add_documents returned 0, indexed 6 chunks

Q: How does the bash tool prevent shell injection?
A: {"content":"[mock answer grounded in 893 chars of context] Question was: How does the bash tool prevent shell injection?","finish_reason":"stop","role":"assistant"}
```

### Tuning chunk size

The two parameters that matter are `max_size` (window length in characters) and `overlap` (shared tail between consecutive windows). Default values of 800 to 1200 characters with 10 to 20 percent overlap work well for prose. Smaller chunks improve retrieval precision but lose cross-paragraph context. Larger chunks carry more context but dilute similarity scores when only one sentence is relevant.

For structured text where paragraph boundaries matter, split on `\n\n` first and only fall back to fixed-size windows for over-long paragraphs. That is what PAR's OCaml `chunk_recursive` strategy does internally: it tries structural separators in order before resorting to character windows.

The chunk metadata is your citation surface. When retrieval returns a hit, the `char_start` and `char_end` fields let you point the user at the exact passage in the source document, the way a search result highlights a snippet.

## Example 3: Multi-document corpus

Real RAG applications index many documents, not one. A documentation site might have hundreds of pages, each tagged with its section, version, and product. This example indexes three distinct documents, each with its own metadata, and shows how the runtime retrieves across the whole corpus.

```python
# example3_multi_doc.py
"""Example 3: index multiple tagged documents, query across the corpus."""
import json
from shared import make_config, make_agent_config
from par_runtime import Runtime

# Three short documents, each from a different source and section.
DOCS = [
    {
        "id": "install-cli",
        "content": (
            "Install the PAR CLI with the bootstrap script: "
            "curl -fsSL https://example.com/install.sh | bash. "
            "The binary lands in /usr/local/bin/par. Run 'par config' "
            "once to choose a provider and enter an API key."
        ),
        "metadata": {"section": "install", "source": "cli.md",
                     "audience": "new-users"},
    },
    {
        "id": "install-python",
        "content": (
            "Install the PAR Python binding with pip: "
            "pip install par-runtime. The wheel bundles the OCaml "
            "shared library, so no compiler is needed. Import with "
            "'from par_runtime import Runtime' and construct a "
            "runtime from a JSON config string."
        ),
        "metadata": {"section": "install", "source": "python.md",
                     "audience": "developers"},
    },
    {
        "id": "troubleshoot-timeout",
        "content": (
            "If LLM calls time out, check the request_timeout setting. "
            "The default is 60 seconds. Streaming uses an idle timeout "
            "that resets on each chunk, so slow-but-steady streams "
            "survive where burst-then-stall streams do not. Raise the "
            "limit with par_set_request_timeout from Python."
        ),
        "metadata": {"section": "troubleshoot", "source": "faq.md",
                     "audience": "operators"},
    },
]

QUESTIONS = [
    "How do I install PAR from Python?",
    "The LLM keeps timing out, what do I do?",
    "What does par config do?",
]

def main():
    with Runtime(make_config()) as rt:
        rt.register_agent(make_agent_config())

        # Index all three documents in one call. Mixing strings and dicts
        # in the same list is allowed; dicts let you attach metadata.
        rc = rt.add_documents(DOCS)
        print(f"Indexed {len(DOCS)} documents (rc={rc})\n")

        # Also embed each question directly so we can inspect similarity
        # scores ourselves. This mirrors what invoke_with_rag does
        # internally and is useful for debugging retrieval quality.
        for question in QUESTIONS:
            qvecs = rt.embed([question])
            print(f"Question embedding has {len(qvecs[0])} dims: "
                  f"{qvecs[0][:4]}...")

            answer = rt.invoke_with_rag("rag_agent", question, k=2)
            parsed = json.loads(answer)
            print(f"Q: {question}")
            print(f"A: {parsed.get('content', answer)}\n")

if __name__ == "__main__":
    main()
```

Expected output:

```
Indexed 3 documents (rc=0)

Question embedding has 8 dims: [0.0, 1.0, 1.0, 0.0]...
Q: How do I install PAR from Python?
A: [mock answer grounded in 612 chars of context] Question was: How do I install PAR from Python?

Question embedding has 8 dims: [1.0, 0.0, 1.0, 1.0]...
A: [mock answer grounded in 598 chars of context] Question was: The LLM keeps timing out, what do I do?

Question embedding has 8 dims: [0.0, 1.0, 0.0, 1.0]...
A: [mock answer grounded in 530 chars of context] Question was: What does par config do?
```

### How metadata flows through retrieval

The `metadata` dict on each document is opaque to PAR. The runtime stores it with the vector and does not inspect its contents. This matters because it means metadata-based filtering (only retrieve documents where `section == "install"`) is not built into the `add_documents` and `invoke_with_rag` Python surface in v0.5.2. To filter, you have two options today:

1. **Maintain separate runtime instances per filter slice.** One runtime for install docs, one for troubleshooting docs. Query the relevant runtime. Simple, but loses cross-slice ranking.
2. **Retrieve wide and filter narrow.** Call `invoke_with_rag` with a larger `k`, then post-filter the retrieved context by metadata before constructing the final prompt. Requires dropping down to the `embed` plus manual search path, which the OCaml SDK exposes directly via `Vector_store.search` and the Python binding will expose in a later release.

The embedding-agnostic store design documented in [RAG Architecture](../explanation/rag-architecture.md) was built so that hybrid search and metadata filtering can be added later without changing the core signatures. Until then, the metadata you store is primarily for citation and display, not for server-side filtering.

## Running the examples

Save the four files in one directory: `mock_server.py`, `shared.py`, `example1_short_text.py`, `example2_long_doc.py`, `example3_multi_doc.py`. Then:

```bash
python3 example1_short_text.py
python3 example2_long_doc.py
python3 example3_multi_doc.py
```

Each script starts its own mock server on a free port, constructs a runtime, and tears everything down when the `with Runtime(...) as rt:` block exits. The mock server runs on a daemon thread, so it dies with the process. No cleanup needed.

If you see `PARInitError: Failed to initialize PAR runtime`, the most likely cause is a malformed config. The runtime's Python wrapper normalizes missing fields, but it cannot fix a JSON syntax error. Validate your config string with `json.loads(config)` before passing it to `Runtime`.

If `embed` raises `PARError("embed failed: embeddings not initialized")`, the `llm_providers` list is empty or the provider does not support embeddings. Anthropic has no embeddings API and will raise `Embedding_unsupported`. OpenAI, Ollama, and the mock server all support embeddings.

## Swapping in a real provider

When you are ready to move past the mock, change the `llm_providers` entry in `make_config`. Point `base_url` at the real endpoint and `api_key` at a real key. Everything else stays the same.

```python
"llm_providers": [
    ["rag_agent", ["Openai", {
        "api_key": "sk-...",          # real key
        "base_url": None,             # None = default OpenAI endpoint
        "organization": None,
        "embedding_model": None,      # None = text-embedding-3-small
    }]],
],
```

For Ollama, point at the local server:

```python
["rag_agent", ["Ollama", {"base_url": "http://localhost:11434/v1"}]]
```

Ollama exposes an OpenAI-compatible embeddings endpoint, so it works through the same retrieval pipeline. Use the same provider for embedding documents and queries. Mixing providers across the two is the drift bug the architecture was designed to prevent, and the runtime will not catch it for you.

## Limitations in v0.5.2

A few things this guide does not cover, and why:

- **No metadata filtering in the Python surface.** As noted above, `invoke_with_rag` retrieves purely by vector similarity. Hybrid search (BM25 plus vector reranking) and metadata predicates are on the roadmap.
- **No document loaders.** The examples pass raw strings. PAR does not parse PDF, HTML, or Markdown frontmatter. Convert to text before indexing. A document-loader layer is planned.
- **The mock embeddings are not semantic.** The hash-based vectors in `mock_server.py` rank identical-text matches highest, but they have no notion of meaning. They exist to prove the plumbing works end to end. Real retrieval quality requires a real embedding model.
- **`add_documents` returns 0 on success in v0.5.2.** The return value is a status code, not a count. A future release may return the number of documents indexed. Do not rely on the return value being the count today.
- **External vector stores are deferred.** Qdrant and Milvus support lands in a later release. The embedding-agnostic store interface is designed so that swapping backends does not change the Python API.

## See also

- [RAG API reference](../sdk/rag.md) for the full function signatures, provider support table, and OCaml examples
- [RAG Architecture](../explanation/rag-architecture.md) for the design decisions: embedding-agnostic storage, why sqlite-vec, score semantics, the three-phase pipeline
- [Streaming API](../sdk/streaming.md) for token-by-token output, which composes with RAG when you want to stream the grounded answer
- [Agent API](../sdk/agent.md) for `register_agent`, `invoke`, and the non-RAG invocation path that `invoke_with_rag` falls back to when no vector store is configured
