<!-- language: en -->

**English** · [简体中文](../zh/sdk/prompt_caching.md)

# Prompt Caching

> Added in v0.6.4-beta. Source-of-truth: `lib/core/types.ml` (types), `lib/core/cache_breakpoint.ml` (marking API), `lib/core/engine.ml` (budget manager).

Prompt caching lets you avoid reprocessing repeated prefixes across LLM calls. Anthropic charges full price for every token in the prompt, even if the same system instructions and tool definitions appear word-for-word on every request. With caching, the provider stores the prefix after the first call and charges a fraction of the cost on subsequent calls. The savings compound fast for agents that reuse long system prompts or large tool lists.

PAR exposes this through a typed API: a `cache_strategy` on the agent config for coarse control, and `mark_tool` / `mark_message` functions for fine-grained per-block marking.

## Overview

Different providers handle caching differently.

**Anthropic** uses explicit `cache_control` markers. You attach a `cache_control` field to content blocks (system prompt segments, tool definitions, message blocks), and Anthropic caches the marked prefix for the specified TTL. Without a marker, nothing is cached.

**OpenAI** caches automatically for prompts that share a long common prefix. No markers are needed. The effect is visible in usage stats: a `cached_tokens` field in the response indicates how many prompt tokens were served from cache.

**Ollama** does not support prompt caching.

PAR's caching API targets Anthropic's marker-based system. When you set a `cache_strategy` or use `mark_tool` / `mark_message`, PAR attaches `cache_control` to the appropriate content blocks before sending them to Anthropic. On OpenAI, these markers are ignored and automatic prefix caching works as usual. On Ollama, caching is a no-op.

## Quick Start

The simplest way to enable caching: set `cache_strategy` on the agent and use a stable system prompt.

```ocaml
open Par

let agent = {
  Types.id = "my-agent";
  system_prompt = stable_prompt "You are a helpful assistant.";
  cache_strategy = With_cache_of `Five_min;
  model = { provider = `Anthropic; model_name = "claude-sonnet-4-20250514";
            api_base = None; temperature = 0.7; max_tokens = None;
            top_p = None; stop_sequences = None };
  tools = [];
  max_iterations = 5;
  middleware = [];
  retry_policy = None;
  context_strategy = None;
  resource_quota = None;
  max_execution_time = None;
  system_prompt_template = None;
  early_stopping_method = Types.Force;
  on_max_tokens = None;
  max_continuation_chunks = None;
  tool_timeout = None;
  context_compression_threshold = None;
  compression_cooldown_messages = None;
  context_window_override = None;
}
```

From Python via the FFI:

```python
import json
from par_runtime import Runtime

config = {
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "default_quota": {"max_tokens": 4096, "max_iterations": 10, "timeout_seconds": 30.0},
    "llm_providers": [
        ["anthropic", {"api_key": "sk-ant-..."}]
    ],
}

with Runtime(json.dumps(config)) as rt:
    rt.register_tool("echo", "Echo tool", '{"type": "object"}')
    # Agent registration via JSON
    agent_config = {
        "id": "my-agent",
        "system_prompt": "You are a helpful assistant.",
        "system_prompt_zone": "stable",
        "cache_strategy": ["With_cache_of", "Five_min"],
        "model": {"model_name": "claude-sonnet-4-20250514", "provider": "anthropic"}
    }
    rt.register_agent(json.dumps(agent_config))
```

That is it. PAR sends `cache_control` markers to Anthropic, and the provider caches the prefix for 5 minutes.

## Stable vs Volatile System Prompts

Not every system prompt should be cached. PAR distinguishes two zones through the `system_prompt` type:

```ocaml
type zone_tag = Zone_stable | Zone_volatile

type system_prompt = {
  sp_raw : string;
  sp_zone : zone_tag;
}
```

**`stable_prompt`** marks the prompt as cacheable. The text does not change between invocations. PAR sends `cache_control` markers when the `cache_strategy` requests them.

**`volatile_prompt`** marks the prompt as uncacheable. The text changes per invocation (for example, it includes the current date or user-specific data). PAR skips `cache_control` markers for volatile prompts, regardless of the `cache_strategy`.

Constructors:

```ocaml
val stable_prompt : string -> system_prompt
val volatile_prompt : string -> system_prompt
```

### Hard-fail on conflicting zones (v0.6.4+)

Setting `cache_strategy = With_cache_of _` together with a `volatile_prompt` is an error. PAR returns `Error (Invalid_input _)` from `make_agent` rather than silently sending markers that would be rejected by Anthropic.

This was a soft-fail in earlier versions. The hard-fail prevents wasted API calls and makes the misconfiguration obvious at agent creation time.

### Template zone detection

When you use `system_prompt_template` instead of a plain `system_prompt`, PAR auto-detects the zone from the template variables:

```ocaml
val Template.classify_template_zone : template:string -> zone_tag
```

The classification logic:

| Variable | Zone | Why |
|---|---|---|
| `{{agent_id}}` | Stable | Identical across calls within a runtime |
| `{{runtime_id}}` | Stable | Identical across calls within a runtime |
| `{{available_tools}}` | Stable | Same tools unless the toolset changes |
| `{{current_time}}` | Volatile | Changes every second |
| Any user variable | Stable (default) | Unknown variables default to stable |

If any variable in the template is volatile, the entire template is classified as volatile. The rule is: `Zone_volatile` dominates. This means `{{agent_id}} + {{current_time}}` produces a volatile template, not a mixed one.

## cache_strategy

The `cache_strategy` type on `agent_config` controls whether PAR sends `cache_control` markers at all:

```ocaml
type cache_strategy =
  | No_caching
  | With_cache_of of cache_ttl

type cache_ttl = [ `Five_min | `One_hour ]
```

**`No_caching`** (the default): no `cache_control` markers are sent. The prompt is processed from scratch on every call. Use this when you want deterministic latency or when the provider does not support caching.

**`With_cache_of `Five_min`**: attaches `cache_control` with a 5-minute TTL. Good for most workloads. The cached prefix is reused for any call within the window.

**`With_cache_of `One_hour`**: attaches `cache_control` with a 1-hour TTL. Better for long-running agents where the system prompt and tool definitions stay stable for extended periods.

The strategy applies uniformly: when `With_cache_of` is set, PAR marks the system prompt, all tool definitions, and the last user message (when appropriate) for caching. For finer control over individual blocks, use `mark_tool` and `mark_message`.

## mark_tool and mark_message

For cases where you want to cache specific tools or messages but not everything, use the `Cache_breakpoint` module:

```ocaml
val Cache_breakpoint.mark_tool : ttl:cache_ttl -> tool_descriptor -> tool_descriptor
val Cache_breakpoint.mark_message : ttl:cache_ttl -> message -> message
```

### mark_tool

Attaches `cache_control` to a tool descriptor. When the engine builds the request, marked tools carry their `cache_control` through to the wire format.

```ocaml
let my_tool = Runtime.register_tool rt
  ~name:"code_search"
  ~description:"Search the codebase"
  ~input_schema:(`Assoc [("type", `String "object")])
  ~handler:(fun _input _token -> Types.Success (`String "result"))
  ()

(* Mark the tool for caching *)
let cached_tool = Cache_breakpoint.mark_tool ~ttl:`Five_min my_tool.descriptor
```

This is useful when a tool's definition is long (complex JSON Schema, detailed description) and you want to avoid reprocessing it on every call.

### mark_message

Attaches `cache_control` to the **last** content block of a message. This targets the point where Anthropic breaks the prefix for caching purposes.

```ocaml
let msg : Types.message = {
  role = `User;
  content_blocks = [
    Text_block { text = "Please review this code:"; cache_control = None };
    Text_block { text = long_code_snippet; cache_control = None };
  ];
}

let marked = Cache_breakpoint.mark_message ~ttl:`Five_min msg
(* The LAST Text_block now has cache_control = Some { type_ = `Ephemeral; ttl = Some `Five_min } *)
```

If the message has no content blocks, `mark_message` is a no-op (the message passes through unchanged).

### Priority and the budget manager

Anthropic caps the number of `cache_control` markers per request at 4. PAR's budget manager decides which markers to keep when there are more candidates than the provider allows.

Each candidate breakpoint carries a priority:

| Source | Priority | When it appears |
|---|---|---|
| System prompt | 100 | Every `With_cache_of` call |
| User-marked tools (`mark_tool`) | 60 | When you explicitly mark a tool |
| Last user message | 10 | Every `With_cache_of` call |

The budget manager sorts candidates by priority (highest first), keeps the top N (where N is the provider's cap), and drops the rest. Dropped breakpoints are reported through the `Cache_breakpoint_dropped` event so you can adjust your marking strategy.

## Budget Manager

The budget manager lives in `Cache_breakpoint.plan_breakpoints`:

```ocaml
val Cache_breakpoint.plan_breakpoints :
  ?max_override:int ->
  Types.llm_service ->
  Types.breakpoint list ->
  Types.breakpoint_plan
```

It works in three steps:

1. **Collect candidates**: the engine gathers all `cache_control` markers from the system prompt, marked tools, and marked messages.
2. **Sort by priority**: highest priority first (system prompt at 100, user tools at 60, last user message at 10).
3. **Split at the cap**: keep the top `max_breakpoints` entries (from the provider's `cache_control_capability`), and label the rest as `Over_budget`.

If the provider does not support caching at all (`cache_control_fn` returns `None` or `max_breakpoints = 0`), every candidate is dropped with `Unsupported_by_provider`.

You can override the cap with `~max_override:n` for testing or to force a specific limit.

```ocaml
type breakpoint_plan = {
  used : breakpoint list;                         (* markers that will be sent *)
  dropped : (breakpoint * drop_reason) list;       (* markers that were skipped *)
}

type drop_reason =
  | Over_budget                          (* provider cap exceeded, lowest priority dropped *)
  | Unsupported_by_provider              (* provider does not support caching *)
  | Lower_priority_than_dropped          (* (reserved for future use) *)
```

## Events

Five events track caching behavior through the event bus:

### Cache_write

Fired after the LLM response indicates that new cache entries were written.

```ocaml
| Cache_write of {
    tokens_written : int;    (* tokens stored in the cache *)
    ttl : cache_ttl;         (* the TTL that was requested *)
  }
```

### Cache_read

Fired when the LLM response indicates that cached tokens were served.

```ocaml
| Cache_read of {
    tokens_read : int;              (* tokens served from cache *)
    total_prompt_tokens : int;      (* total prompt tokens for context *)
  }
```

### Cache_strategy_skipped

Fired when caching was skipped for an entire request. The `reason` tells you why:

```ocaml
| Cache_strategy_skipped of {
    reason : [ `Volatile_system              (* system prompt is volatile *)
             | `Volatile_builtins of string list  (* volatile builtin tools *)
             | `Unsupported_provider          (* provider has no cache_control_fn *)
             | `No_strategy ];                (* cache_strategy = No_caching *)
  }
```

### Cache_breakpoint_dropped

Fired when the budget manager drops a breakpoint that exceeded the provider cap:

```ocaml
| Cache_breakpoint_dropped of {
    location : [ `System | `Tool of int | `Message of int * int ];
    reason : drop_reason;
  }
```

### Cache_invalidated_by_skill

Fired when a skill modifies the tool list in a way that invalidates cached prefixes. The event reports how many tools changed and the estimated wasted tokens:

```ocaml
| Cache_invalidated_by_skill of {
    skill_id : string;
    before_tool_count : int;
    after_tool_count : int;
    estimated_wasted_tokens : int;
  }
```

## Provider Support

| Provider | Caching mechanism | `cache_control` markers | Automatic caching |
|---|---|---|---|
| Anthropic | Explicit markers on content blocks | Full support | No |
| OpenAI | Automatic prefix caching | Ignored (no effect) | Yes, visible via `cached_tokens` in usage |
| Ollama | None | Ignored | No |

For Anthropic, PAR's entire caching API (strategy, `mark_tool`, `mark_message`, budget manager) controls which markers are sent. For OpenAI, you do not need to do anything. The provider caches automatically when the prompt prefix is stable across calls, and reports the savings in the response's `usage` field.

## FFI / Python Config

When configuring agents from Python (through the FFI layer), use these JSON shapes:

### cache_strategy

```json
{"tag": "No_caching"}
```

```json
{"tag": "With_cache_of", "contents": "Five_min"}
```

```json
{"tag": "With_cache_of", "contents": "One_hour"}
```

### system_prompt_zone

The `system_prompt_zone` field on agent config controls how the system prompt is classified:

```json
"system_prompt_zone": "stable"
```

```json
"system_prompt_zone": "volatile"
```

When `system_prompt_zone` is omitted from the JSON, the prompt defaults to stable. Bare string values in `system_prompt_override` within skill descriptors also default to `Stable_prompt`.

### prompt_cache_key

On the OpenAI provider config, an optional `prompt_cache_key` field lets you supply a cache key for OpenAI's prefix caching:

```json
{
    "tag": "Openai",
    "contents": {
        "api_key": "sk-...",
        "base_url": null,
        "organization": null,
        "embedding_model": null,
        "prompt_cache_key": "my-agent-cache-v1"
    }
}
```

This field is OpenAI-specific. It is ignored by Anthropic and Ollama providers.

### skill_prompt_zone

Skill prompt overrides use the `skill_prompt_zone` ADT. In JSON, three forms are accepted:

```json
"system_prompt_override": "static instructions"
```

Bare strings are treated as `Stable_prompt` for backward compatibility.

```json
"system_prompt_override": {"zone": "stable", "text": "static instructions"}
```

```json
"system_prompt_override": {"zone": "volatile", "text": "instructions with {{current_time}}"}
```

```json
"system_prompt_override": {"zone": "both", "stable": "core rules", "volatile": "time-sensitive rules"}
```

The `both` variant splits the prompt into stable and volatile halves. PAR concatenates them (`stable ^ "\n" ^ volatile`) and marks the result as volatile (any volatile component makes the whole prompt uncacheable).

## See also

- [Agent API Reference](agent.md) -- `agent_config` fields including `cache_strategy` and `system_prompt`
- [Skills API](skills.md) -- skill prompt zones and `skill_prompt_zone` ADT
- [Middleware API](middleware.md) -- middleware pipeline for request/response hooks
- [Observability](observability.md) -- event bus subscription for cache events
