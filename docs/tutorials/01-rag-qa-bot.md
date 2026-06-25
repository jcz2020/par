<!-- language: en -->

# Tutorial 1: Build a RAG Q&A Bot

> Follows the Diataxis tutorial form: learning by doing, not a reference page.
> Pair with the [RAG API reference](../sdk/rag.md) when you want the full type
> signatures, and with the [Quickstart](../quickstart.md) for the broader setup.

This tutorial walks you from an empty directory to a working retrieval-augmented
generation bot in roughly thirty minutes. You will start a PAR runtime, turn text
into vectors, store them, and ask a question that gets answered from the indexed
context. By the end you will understand the four moving parts of every RAG
pipeline and how PAR exposes them.

RAG grounds an LLM in your own documents. Instead of trusting the model's
parametric memory, you embed your text into vectors, store them in a local
index, and at query time pull out the chunks closest to the question. Those
chunks ride into the prompt as context before the model answers. PAR handles the
plumbing for this loop; you bring the documents.

## What you will build

A Python script that:

1. Starts a PAR runtime with SQLite persistence.
2. Embeds a few short passages into vectors.
3. Stores the vectors in PAR's local index.
4. Asks a question and gets an answer drawn from the indexed context.

Every code block in this tutorial runs without an LLM API key. Where a real
provider is needed for the final answer step, the block checks for a key and
skips cleanly when one is absent, so you can copy and run each snippet as-is.

## Prerequisites

You need the Python binding installed and importable.

```bash
pip install par-runtime
python -c "from par_runtime import Runtime; print('ok')"
```

If the second command prints `ok`, you are ready. If it raises
`ImportError`, the wheel for your platform is missing; fall back to building
from source with `make install` (see the [Quickstart](../quickstart.md)).

You do not need an OpenAI or Anthropic key to follow the embedding and indexing
steps. A key only unlocks the final grounded-answer step, and the block that
needs it degrades gracefully.

## Step 1: Start the runtime

PAR's runtime is the object that owns the persistence layer, the event bus, and
the provider registry. You construct it from a JSON config string. The shape
matters: missing fields cause `PARInitError`, so the block below is the minimal
config that initializes cleanly.

```python
import json
from par_runtime import Runtime

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
            "drain_timeout": 3.0,
            "cancel_grace_period": 1.0,
            "flush_batch_size": 100,
        },
        "llm_providers": [],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
    })

with Runtime(make_config()) as rt:
    health = rt.health()
    assert health.get("runtime_alive") is True, health
    print("runtime started:", health)
```

Run it. You should see `runtime started: {... 'runtime_alive': True ...}`.

Two things to notice. First, persistence is `["Sqlite", ":memory:"]`, the tuple
form of the `` `Sqlite `` polymorphic variant with an in-memory database. A file
path like `"par.db"` would persist to disk instead. Second, `llm_providers` is
empty here because this step only checks the runtime can start. Step 4 attaches a
real provider when it is time to generate an answer.

## Step 2: Embed text into vectors

Embedding converts a string into a fixed-length float array. PAR's vector store
is embedding-agnostic: it stores whatever floats you hand it and ranks them by
cosine similarity. The runtime's `embed` method is the way to produce those
floats for a chat-plus-embedding provider like OpenAI.

The block below stands up a tiny OpenAI-compatible HTTP server on a random local
port, then points the runtime at it. This is exactly how PAR's own test suite
exercises the embedding path without spending API credits. You get real vectors
back through the real FFI, no key required.

```python
import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from par_runtime import Runtime


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _MockEmbeddings(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            payload = json.loads(body)
        except Exception:
            payload = {}
        inputs = payload.get("input", [])
        if isinstance(inputs, str):
            inputs = [inputs]
        data = [
            {"object": "embedding", "index": i, "embedding": [0.1 * i, 0.2 * i, 0.3]}
            for i in range(len(inputs))
        ]
        body_out = json.dumps(
            {"object": "list", "data": data, "usage": {"prompt_tokens": 5, "total_tokens": 5}}
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_out)))
        self.end_headers()
        self.wfile.write(body_out)


def start_mock_embeddings_server():
    port = _free_port()
    server = HTTPServer(("127.0.0.1", port), _MockEmbeddings)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{port}/v1"


def provider_config(base_url):
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
        "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2},
        "shutdown": {"drain_timeout": 3.0, "cancel_grace_period": 1.0, "flush_batch_size": 100},
        "llm_providers": [
            ["default", ["Openai", {
                "api_key": "sk-mock-not-a-real-key",
                "base_url": base_url,
                "organization": None,
                "embedding_model": None,
            }]]
        ],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
    })


server, base_url = start_mock_embeddings_server()
try:
    with Runtime(provider_config(base_url)) as rt:
        vectors = rt.embed(["PAR is an OCaml runtime", "PAR ships twenty tools"])
        print("embedded %d strings" % len(vectors))
        print("each vector has %d dimensions" % len(vectors[0]))
finally:
    server.shutdown()
```

The output reports two vectors, each with three dimensions. The dimension comes
from the mock server, not from a real embedding model. When you swap in OpenAI
later, the dimension jumps to 1536 for `text-embedding-3-small`, and the floats
carry actual semantic signal. The call shape does not change.

A subtle point worth pinning down now. One provider block handles both embedding
and chat in PAR. You do not configure them separately. The same `[name, [tag,
fields]]` entry that satisfies `embed` also satisfies the chat step in
`invoke_with_rag`. Keep the embedding model name in one place and route both
indexing and querying through it. That is the cheapest defense against embedding
model drift, where you index with model A and query with model B and retrieval
silently collapses.

## Step 3: Index documents

With embedding working, indexing is one call. `add_documents` takes a list of
strings or dicts, embeds each one through the configured provider, and inserts
the vectors into the runtime's local store.

```python
import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from par_runtime import Runtime


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _MockEmbeddings(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            payload = json.loads(body)
        except Exception:
            payload = {}
        inputs = payload.get("input", [])
        if isinstance(inputs, str):
            inputs = [inputs]
        data = [
            {"object": "embedding", "index": i, "embedding": [0.1 * i, 0.2 * i, 0.3]}
            for i in range(len(inputs))
        ]
        body_out = json.dumps(
            {"object": "list", "data": data, "usage": {"prompt_tokens": 5, "total_tokens": 5}}
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_out)))
        self.end_headers()
        self.wfile.write(body_out)


def start_mock_embeddings_server():
    port = _free_port()
    server = HTTPServer(("127.0.0.1", port), _MockEmbeddings)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{port}/v1"


def provider_config(base_url):
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
        "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2},
        "shutdown": {"drain_timeout": 3.0, "cancel_grace_period": 1.0, "flush_batch_size": 100},
        "llm_providers": [
            ["default", ["Openai", {
                "api_key": "sk-mock-not-a-real-key",
                "base_url": base_url,
                "organization": None,
                "embedding_model": None,
            }]]
        ],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
    })


server, base_url = start_mock_embeddings_server()
try:
    with Runtime(provider_config(base_url)) as rt:
        documents = [
            "PAR is an OCaml agent runtime built on Eio structured concurrency.",
            "PAR's vector store uses sqlite-vec under the hood and is embedding-agnostic.",
            "PAR ships twenty built-in tools, including a type-safe bash tool.",
            "The ReAct loop bounds iterations and runs middleware at every boundary.",
        ]
        added = rt.add_documents(documents)
        print("add_documents returned:", added)
finally:
    server.shutdown()
```

The return value of `add_documents` is the count the FFI propagates back. Against
the mock it reads `0`; against a real provider it reflects the number indexed.
Treat the call as the source of truth for "the documents were handed off", and
verify retrieval quality by querying, not by inspecting the count.

For more than a handful of documents, pass dicts with explicit ids and metadata.
The id lets you upsert in place on reindex instead of duplicating, and metadata
rides along on every search result so a UI can show provenance. Chunking long
documents before embedding is its own topic; see the [RAG API reference](../sdk/rag.md)
for the `Chunking` module and the reindexing rules.

## Step 4: Ask a grounded question

This is where the four pieces compose. `invoke_with_rag` embeds your query,
retrieves the top-k chunks, augments the system prompt with them, and calls the
agent. One call.

The agent needs a chat provider to produce the final answer. The block below
reads your `OPENAI_API_KEY` and, if present, runs the full grounded query against
the real API. If the key is absent, it prints a clear skip message and exits 0,
so the snippet still runs cleanly in any environment. This is the honest shape
for a tutorial block that depends on a paid provider.

```python
import json
import os
import sys
from par_runtime import Runtime, PARError

api_key = os.environ.get("OPENAI_API_KEY")
if not api_key:
    print("skipped: set OPENAI_API_KEY to run the grounded query")
    sys.exit(0)

config = json.dumps({
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
    "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2},
    "shutdown": {"drain_timeout": 3.0, "cancel_grace_period": 1.0, "flush_batch_size": 100},
    "llm_providers": [
        ["default", ["Openai", {
            "api_key": api_key,
            "base_url": None,
            "organization": None,
            "embedding_model": None,
        }]]
    ],
    "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
    "parallel_tool_execution": True,
})

agent = json.dumps({
    "id": "rag_agent",
    "system_prompt": "Answer the question using only the provided context.",
    "model": {"provider": "openai", "model_name": "gpt-4o-mini"},
    "max_iterations": 1,
    "tools": [],
})

with Runtime(config) as rt:
    rt.register_agent(agent)
    rt.add_documents([
        "PAR is an OCaml agent runtime built on Eio structured concurrency.",
        "PAR's vector store uses sqlite-vec and is embedding-agnostic.",
        "PAR ships twenty built-in tools, including a type-safe bash tool.",
    ])
    try:
        raw = rt.invoke_with_rag("rag_agent", "How many built-in tools does PAR ship?", k=2)
        parsed = json.loads(raw)
        print("answer:", parsed)
    except PARError as exc:
        print("query failed:", exc)
```

Set the key and run it. With the real provider the answer draws on the indexed
context rather than the model's memory. The `k=2` argument retrieves the two
most similar chunks. Raise it for noisier, broader context. Lower it for tighter
focus. The default is `k=4`.

Three things changed from the indexing block. First, the provider now points at
the real OpenAI base URL (`base_url: None` means the provider default). Second,
an agent is registered, because `invoke_with_rag` routes the augmented prompt
through an agent just like a plain `Runtime.invoke` would. Third, the call
returns a JSON string shaped like any other invoke result, so you parse it the
same way.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `PARInitError: Failed to initialize PAR runtime` | A required config field is missing or has the wrong shape. | Compare your config block against Step 1. The `event_bus`, `default_quota`, and `shutdown` blocks all need their nested fields. |
| `embed` raises with `Embedding_unsupported` | You pointed `embed` at a provider with no embeddings API, which today means Anthropic. | Use OpenAI, Ollama, or Mock for the embedding step. Anthropic still works for the chat step inside `invoke_with_rag`. |
| `External_failure` mentioning `vec0.so` or `sqlite-vec` | The sqlite-vec extension failed to load, usually a platform mismatch or a missing path. | The Python wheel resolves the extension path automatically. If you build from source, pass the correct `vec_extension_path` for your platform. |
| Retrieval returns junk or nothing | Embedding model drift. You indexed with one model and queried with another, or you changed the dimension. | Reindex every document with one model. See Persistence and Reindexing in the [RAG API reference](../sdk/rag.md). |
| `invoke_with_rag` returns an `Internal` Yojson error against a hand-rolled mock | The mock's chat completion response is missing a field the provider parser expects. | Use a real provider for the answer step, or model your mock on a real OpenAI chat completion payload. |
| Out of memory on a large PDF | You embedded the whole document as one vector, averaging away every signal and bloating the prompt. | Chunk first with `Chunking.chunk_recursive`, then embed and index the chunks. |

## What's next

You now have the full RAG loop: embed, index, retrieve, answer. Two natural next
steps.

- See tokens arrive as the model produces them in [Tutorial 2: Streaming UI](02-streaming-ui.md).
  The same runtime that answered your question can stream its reply token by token.
- Read the [RAG API reference](../sdk/rag.md) for the chunking strategies, the
  OCaml `Vector_store` and `Chunking` module signatures, and the reindexing rules.

Two further tutorials ship once their dependencies land. Multi-provider fallback
([Tutorial 4](04-multi-provider-fallback.md)) shows OpenAI failing over to
Anthropic on a rate limit. Session resume ([Tutorial 5](05-session-resume.md))
shows a conversation surviving a process restart. Both are stubs today.
