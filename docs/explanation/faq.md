<!-- language: en -->

# FAQ: Common Questions

This page collects the questions that come up most often when someone evaluates PAR, picks a surface to start with, or hits a behavior they did not expect. Each answer points at the deeper reference page so you can keep reading without backtracking. If your question is not here, the [How-to guides](../howto/) cover specific recipes and the [Architecture](architecture.md) page covers the design rationale.

## Q1. How is PAR different from LangChain?

PAR occupies the same niche as LangChain, agent runtime plus orchestration primitives, but the design priorities are inverted. LangChain optimizes for breadth and Python ergonomics. PAR optimizes for type rigor and structured concurrency. The differences show up in three concrete places.

**Type safety at compile time, not at runtime.** LangChain tools are Python callables behind a dictionary-shaped `args_schema`. A typo in a field name, a missing argument, a wrong type, lands as a runtime crash deep inside an agent loop. PAR tools are OCaml records behind a typed `tool_descriptor`, and every call site goes through pattern matching that the compiler forces you to cover. The bash tool is the loudest example. LangChain exposes `subprocess.run` with a raw string. PAR has the `Bash_safe_command` ADT, an algebraic data type with no `Exec_raw_shell` constructor, which means shell injection is unrepresentable at the type level. You cannot write the bug. STRATEGY.md section 3 calls this the core differentiator, the property PAR cannot be copied on.

**Structured concurrency instead of asyncio.** LangChain runs on Python asyncio. Every async function carries a color, every `await` is a suspension point, and a tool handler has to commit to `async def` or stay sync. PAR runs on OCaml 5.4 effect handlers plus the Eio library. Functions are direct style. There is no color split. The runtime hands every `Runtime.create` call one `Eio.Switch.t`, and every fiber the runtime forks is a child of that switch. When the switch exits, the children are joined. A leaked tool handler holding a database connection cannot outlive its runtime. Go has goroutines and a context model that asks children to cooperate. asyncio has task groups in 3.11. Eio has had structured enforcement from day one.

**A filesystem-native skill system.** LangChain prompts and tool subsets live in code. PAR's skill layer, shipped in v0.5.2, discovers reusable behavior packages from `~/.par/skills/<name>/skill.md` on disk. Each skill bundles a `system_prompt_override`, a typed `tool_filter` ADT (`All_tools`, `Only [...]`, `Except [...]`), and a `skill_trigger` (`Auto`, `Manual`, `Keyword [...]`). The 3-level context loading pattern, always-resident metadata, lazy body, never-loaded supporting files, keeps token budgets sane with 50+ skills installed. No Python framework ships this combination of filesystem discovery, typed tool filter, and budget enforcement. See [Concurrency Model](concurrency-model.md) for the fiber story and Q6 below for the skill surface.

The short version: LangChain is the right pick when you want maximum ecosystem breadth in Python today. PAR is the right pick when type guarantees, predictable concurrency, and a durable skill abstraction matter more than the long tail of LangChain integrations.

## Q2. When should I use the OCaml SDK vs the Python binding vs the CLI?

PAR ships three surfaces over the same runtime. They are not three products. They are three doors into one engine, and the right door depends on what you are building.

| Surface | Pick it when | Avoid it when |
|---------|--------------|---------------|
| OCaml SDK | You are writing production OCaml and need every public API typed end to end | You do not want an OCaml toolchain in your build |
| Python binding (`par_runtime` on PyPI) | You have an existing Python service and want a typed agent runtime without rewriting your stack | You need features the binding has not exposed yet (some advanced config fields are SDK-only) |
| CLI (`par`, `par ask`, `par config`) | You want a one-off answer, a smoke test, or a REPL | You are building anything programmatic |

The decision matrix is mostly about who owns the deployment. The OCaml SDK is the canonical surface. Every public API exists here first, every behavior is documented against the OCaml types, and every other surface is a thin wrapper. If you are writing OCaml, there is no reason to pick anything else. The SDK reference under `docs/sdk/` is the source of truth for type signatures.

The Python binding is for the case PAR was designed for, Python backend engineers who want type-safe agent infrastructure without rewriting their stack in OCaml. You `pip install par-runtime`, import `Runtime`, and call `invoke` or `invoke_stream`. The binding talks to the same OCaml runtime through a ctypes FFI bridge. A persistent OCaml domain owns the `Runtime`, and Python threads dispatch work closures onto it. The Python surface is thread-safe without holding a global lock on the Python side. Where the SDK and the binding disagree, the SDK reference wins, and the binding is updated to match.

The CLI is a convenience layer. It is the right tool for answering a single question from a shell, for running `par config` to set up a provider, or for the interactive REPL. It is not the right tool for building an agent-powered service. The CLI is documented under [CLI reference](../cli.md) and exists to support the end-user experience, not to replace the SDK.

A reasonable progression looks like this. Start with the CLI to verify the install and feel out the provider config. Move to the Python binding when you have a real service to build and your stack is Python. Move to the OCaml SDK when you want full type coverage, custom tool handlers in OCaml, or features the binding does not surface yet. The runtime behavior is identical across all three, so swapping surfaces later is a refactor, not a rewrite.

## Q3. Does streaming deliver tokens incrementally?

**Yes, as of v0.5.3.** `invoke_stream` runs `par_invoke_stream` in a background daemon thread; the OCaml SSE parser fires a ctypes callback for each chunk as the LLM produces it, pushing onto a `queue.Queue`. The Python iterator consumes the queue concurrently, so the first token reaches the caller within milliseconds — not after the full response completes. For a 30-second generation, perceived latency drops from "30 s black screen then everything" to "first token < 1 s, then steady drip."

**History.** v0.5.1–v0.5.2 shipped *buffered* streaming: the OCaml work loop collected all chunks in a ref list, serialized them as JSON at the end, and Python parsed the array on first `__iter__`. The buffer eliminated a domain-lock crash that affected the initial ctypes-callback design, but it meant all chunks arrived at once after the LLM finished. v0.5.3 rewired the FFI (`caml_dispatch_chunk_to_c` external + background thread + `queue.Queue`) to deliver chunks in real time without the domain-lock issue.

**Known limitation (v0.5.3).** Breaking early from the iterator leaves the background thread holding the process-global `ocaml_lock` until the LLM stream completes naturally. During that window, subsequent `par_*` calls block. Consume the iterator fully if you need to make further calls. A `par_cancel_stream` FFI for immediate cancellation is planned for v0.5.4. See the [Streaming API reference](../sdk/streaming.md) and CHANGES.md for details.

**What stays the same.** The `Event` tagged union (`TextDelta`, `ToolCallStart`, `ToolCallDelta`, `UsageUpdate`, `Done`) matches the OCaml `llm_response_chunk` ADT field-for-field. The API shape did not change between buffered and incremental — only the delivery cadence improved.

## Q4. How do I configure persistence for production?

PAR ships three persistence backends, selected by the `persistence` field in `runtime_config`. Picking the right one is a one-time decision based on how many processes hit the data and how hard you push audit queries. The deep writeup is in [Persistence and Durability](persistence-and-durability.md).

**SQLite for dev and single-instance production.** The default. A single file on disk (or `:memory:` for tests). Zero external dependencies. WAL mode handles the read-heavy, write-batched workload PAR generates. The default retention TTL is 7 days, pruned at backend open. For a single PAR process under moderate load, SQLite is enough. Back up the `.db` file on whatever schedule your audit window requires. A single runtime with SQLite can push hundreds of events per second through the batched writer. The LLM provider is almost always the bottleneck, not the database.

**PostgreSQL for multi-instance production.** SQLite's file locking does not survive multiple processes writing to the same file across containers. When you need horizontal scale, point PAR at Postgres. The backend lives in a separate opam package, `par_postgres`, because it pulls in `pgwire` and TLS libraries that not every user wants. Same schema as SQLite, but multi-process safe. Several PAR runtimes can share one database. The upgrade trigger is almost always one of two things: you need more than one PAR process hitting the same data, or your audit query patterns have outgrown what SQLite indexes give you.

**Noop for tests.** Discards everything. No event bus, no writer fiber, no I/O. Tests that only care about agent behavior run faster and do not leave files behind. The runtime skips wiring up the event bus entirely when persistence is noop, so there is no dead bus feeding a dead writer.

**Tuning knobs that matter.** The `Persistence_writer` buffers events in a mutex-protected list with capacity 1000 and flushes every 50 milliseconds. If the buffer overflows, events route to the event bus dead-letter queue instead of being dropped silently. Retention pruning is timestamp-based, on the `events` table only. `task_states` and `workflow_states` are not pruned automatically because their rows represent resumable state. If you want long retention in a regulated environment, point PAR at Postgres and tune retention server-side, integrated with your existing backup pipeline.

**Dual-layer is coming.** The current model is single-tier: events go to one backend, full stop. A future version plans a dual-layer design with a fast local tier (SQLite, low latency, short retention) plus a remote tier (Postgres or object storage, durable, long retention). The local tier absorbs burst traffic and forwards to the remote tier asynchronously. Until it lands, pick your backend based on the matrix above and accept that one tier is what you have.

## Q5. Can I use PAR with provider X?

Probably yes, if the provider speaks the OpenAI Chat Completions API. PAR ships four providers built in and a custom registration path for anything else.

| Provider | Text | Tool calls | Streaming | Embeddings (RAG) | Notes |
|----------|------|------------|-----------|------------------|-------|
| `` `Openai `` | yes | yes | yes | yes | First-class. Reference implementation. |
| `` `Anthropic `` | yes | yes | yes | **no** | Anthropic has no embeddings API. Use OpenAI or a local embedder for RAG. |
| `` `Ollama `` | yes | yes | yes | yes | Local. Spoke to via the OpenAI-compatible endpoint. |
| `` `Mock `` | yes | yes | yes | yes | For tests. Emits all event types. |
| Custom | yes | yes | varies | varies | Anything OpenAI-compatible (Cohere, Mistral, vLLM, LM Studio, etc.) |

The interesting cases are Anthropic and custom providers.

**Anthropic and RAG.** Anthropic's API does not expose an embeddings endpoint. The Claude family is chat-only. If you want RAG with Anthropic as the chat model, you need a separate embeddings source. The common pattern is to use OpenAI's embeddings API or a local embedder (Ollama's `nomic-embed-text`, for example) for the embedding step, then use Anthropic for the generation step. PAR's RAG pipeline is split that way by design, `invoke_with_rag` accepts the chat provider and the embeddings provider as separate config fields.

**Ollama and OpenAI-compatible local servers.** Ollama exposes an OpenAI-compatible endpoint at `http://localhost:11434/v1`. Point PAR's `` `Ollama `` provider at it, or register a custom provider pointing at the same URL, and you get the same surface. The same trick works for vLLM, LM Studio, LocalAI, and any other server that mimics the OpenAI Chat Completions shape. Streaming behavior depends on the server. PAR's streaming reference documents provider support; verify your local server emits Server-Sent Events before relying on incremental delivery (shipped in v0.5.3).

**Custom providers.** If your provider is not on the list, follow the [Custom LLM provider how-to](../howto/custom-llm-provider.md). The pattern is the same one used for Cohere, Mistral, and Ollama: implement the provider interface, register it with `Runtime.register_agent` or via config, and PAR routes invokes to it. The provider interface is documented under `docs/sdk/`. Anything that speaks OpenAI Chat Completions, with or without tool calls, works without new code.

The one provider category PAR does not support today is non-OpenAI-compatible proprietary APIs (Google Gemini's native API, for example, distinct from its OpenAI-compatibility layer). For those, write a custom provider adapter. The abstraction is designed for this.

## Q6. What is the skill system and when should I use it?

The skill system, shipped in v0.5.2 Track A, is PAR's typed abstraction over reusable agent behavior packages. It is the answer to a recurring problem: you have an agent that does good work, you want to give it a focused capability (PDF extraction, SQL querying, code review) without rewriting its system prompt or its tool list. Skills let you package that capability as a directory on disk and load it on demand.

**What a skill is.** A skill is a directory under `~/.par/skills/<name>/` containing a `skill.md` file with YAML frontmatter and a markdown body. The frontmatter declares:

- `system_prompt_override` or `system_prompt_append`: the prompt material to inject when the skill activates.
- `tool_filter`: a typed ADT, `All_tools`, `Only ["read_file", "list_dir"]`, or `Except ["bash"]`. Replaces the string-list allowlists every other framework uses.
- `trigger`: `Auto` (always load description, LLM judges), `Manual` (explicit invoke only), or `Keyword [...]` (deterministic match, optional LLM confirm).
- `expected_output`: an optional typed JSON schema for success criteria. Forward-looking, informational in v0.5.2, consumed by an LLM judge in a future version.

**Why typed matters.** Every other framework that ships a skill-like abstraction (LangChain Hub, OpenAI Assistants, CrewAI Tasks, Claude Code Skills) uses string lists for tool filtering. PAR uses an ADT. `Only` and `Except` compose under intersection semantics with multi-skill activation: two skills with `Only ["a", "b"]` and `Only ["b", "c"]` both active yield `Only ["b"]`. Most-restrictive-wins fails safe. This is the kind of property you cannot get back by patching a string-list API later.

**When to use it.** Reach for a skill when you have a behavior you want to reuse across agents without copy-pasting prompts and tool subsets. A PDF extractor skill, a SQL query skill, a code review skill, a security audit skill. The 3-level context loading pattern keeps token budgets sane at scale. Level 1 is the metadata block, always resident in context, roughly 100 tokens per skill. Level 2 is the body, lazy-loaded when the skill triggers. Level 3 is supporting files, never loaded into context. With a 2048-token description budget (overridable via `skill_token_budget`), you can have 20 Auto skills installed and the runtime stays under budget. Overflow prioritization is explicit, then keyword-matched, then auto-declared in declaration order.

**When not to use it.** Skills are not the right tool for one-off prompts. If you have a system prompt you use in exactly one agent, write it in `agent_config`. Skills earn their keep when the same behavior package is composed into multiple agents, when non-engineers need to add capabilities without touching OCaml code, or when you want to share capabilities across projects via a skills directory.

The v0.5.2 release ships the data model, the filesystem discovery, the YAML frontmatter format, and the typed `tool_filter` composition. Future versions will add the LLM judge for `expected_output`, hot-reload via mtime rescan, and a `par skill` CLI for listing, installing, and validating skills. The roadmap is in `docs/v0.5.2-ROADMAP.md`. The skill design research, including the 5-framework comparison that informed the paradigm choice, is documented alongside the roadmap.

## See also

- [Architecture](architecture.md) for the module map and how skills fit into the larger Runtime structure
- [Concurrency Model](concurrency-model.md) for the fiber story that skills compose into
- [Persistence and Durability](persistence-and-durability.md) for the persistence backend decision matrix
- [Streaming API](../sdk/streaming.md) for the incremental chunk delivery path (v0.5.3)
- [Agent API](../sdk/agent.md) for `Runtime.invoke`, `agent_config`, and tool registration
