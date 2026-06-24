# Skills API

Skills are reusable bundles of system prompt, tool filter, and trigger conditions. They let you package domain expertise (code review, translation, summarization, RAG) into a single file that PAR auto-discovers and activates when relevant.

**Status**: v0.5.2-beta. API may change before v1.0.

---

## What is a skill?

PAR has four abstraction layers. Skills sit alongside tools, agents, and middleware:

| Layer | What it packages | Example |
|-------|------------------|---------|
| **Tool** | A single function callable by the LLM | `read_file`, `web_search`, `bash` |
| **Skill** | System prompt + tool subset + trigger conditions | "Code reviewer" (review prompt + read/grep tools only) |
| **Agent** | Full config: model, tools, middleware, retry policy | Default agent with GPT-4 + 20 tools |
| **Middleware** | Cross-cutting hook (logging, retry, rate limit) | Retry with exponential backoff |

**When to create a skill** vs an agent:
- **Skill**: You want to switch behavior *within a conversation* without restarting. The agent stays the same; the skill overlays its prompt and tool filter.
- **Agent**: You need a fundamentally different model, tool set, or middleware chain.

---

## Quick start

Create a skill in 30 seconds:

```bash
mkdir -p ~/.par/skills/greeter
cat > ~/.par/skills/greeter/skill.md << 'EOF'
---
schema_version: 1
id: greeter
name: Greeter
description: Greet users warmly. Use when the conversation starts or the user says hello.
system_prompt_override: "You are an enthusiastic greeter. Always start with a warm welcome."
tool_filter: All
trigger: Keyword [hello, hi, hey]
---

# Greeter Skill

When activated, greet the user warmly and ask how you can help.
Use their name if provided in the conversation context.
EOF
```

Now start PAR and check:

```bash
par
> /skills
  greeter              Greet users warmly. Use when the conversation starts...
> /skill greeter
ID:          greeter
Name:        Greeter
Description: Greet users warmly. Use when the conversation starts or the user says hello.
Trigger:     keyword
```

The skill is auto-discovered and registered. When the user types "hello", the keyword trigger activates the skill.

---

## File format

Each skill lives in its own directory: `~/.par/skills/<id>/skill.md`.

### Directory structure

```
~/.par/skills/greeter/
└── skill.md          ← YAML frontmatter + markdown body
```

### YAML frontmatter reference

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `schema_version` | int | **yes** | — | Must be `1` for v0.5.2. Loader rejects unknown versions. |
| `id` | string | **yes** | — | Lowercase-hyphen identifier. Must match directory name. |
| `name` | string | **yes** | — | Display name. |
| `description` | string | **yes** | — | What the skill does + when to use it. Max 1024 chars. Always loaded (L1 metadata). |
| `system_prompt_override` | string \| null | no | `null` | Replaces the agent's system prompt when skill activates. |
| `tool_filter` | `All` \| `Only [...]` \| `Except [...]` | no | `All` | Restricts which tools the LLM can use. |
| `trigger` | `Auto` \| `Manual` \| `Keyword [...]` | no | `Auto` | When the skill gets activated. |
| `expected_output` | JSON \| null | no | `null` | Forward-looking: typed success criteria (informational in v0.5.2, LLM judge planned for a future version). |

### Markdown body

The body after the second `---` is the skill's instructions. It's **lazy-loaded** (L2) — only read into memory when the skill activates, not at startup. This keeps startup fast even with 50+ skills installed.

---

## Trigger types

The `trigger` field controls when a skill becomes active:

### Auto (default)

The skill description is loaded into the LLM's system prompt. The LLM itself decides whether to activate the skill based on the user's message and the description text.

```yaml
trigger: Auto
```

Best for: skills that should be "always available" to the LLM (summarizer, RAG assistant).

### Manual

The skill is never auto-activated. Users must explicitly invoke it:

```bash
par skill use my-skill
```

Best for: skills that should only fire on explicit request (dangerous operations, specialized workflows).

### Keyword

A fast substring pre-filter runs before LLM judgment. The skill is only considered if one of the keywords appears in the user's message:

```yaml
trigger: Keyword [pdf, form, document] confirm
```

- `confirm` (default): after keyword match, LLM still judges whether to activate
- `deterministic`: keyword match immediately activates, no LLM judgment needed

```yaml
trigger: Keyword [pdf, form] deterministic
```

Best for: skills with clear domain keywords (PDF extractor, translator for specific languages).

### Token budget

To prevent system prompt explosion, PAR caps total skill description tokens at **2048** (configurable via runtime config `skill_token_budget`). When the budget is exceeded, lowest-priority skill descriptions are dropped with a warning.

---

## Tool filter

Restricts which tools the LLM can access when the skill is active:

```yaml
tool_filter: All                    # all registered tools (default)
tool_filter: Only [read_file, grep] # only these tools
tool_filter: Except [bash]          # all tools except these
```

When multiple skills are active simultaneously, filters compose by **intersection** (most restrictive wins). This ensures no skill can widen another skill's restriction.

---

## Discovery

PAR discovers skills from three sources, in this precedence order (first match wins):

1. **SDK-registered** (highest): `Runtime.register_skill(descriptor)` — explicit, programmatic
2. **Project**: `./.par/skills/<id>/skill.md` — checked into the repo
3. **User**: `~/.par/skills/<id>/skill.md` — user-wide defaults
4. **Builtin** (lowest): 4 starter skills shipped with PAR

**Hot-reload**: On each `Runtime.invoke`, PAR checks if any skills directory's mtime changed. If so, it rescans automatically. You can also force a rescan:

```bash
par skill reload
```

---

## CLI usage

### REPL commands

| Command | Description |
|---------|-------------|
| `/skills` | List all registered skills with description preview |
| `/skill <id>` | Show full detail of a specific skill |

### Standalone commands

```bash
par skill list                    # list skills (non-interactive)
par skill show <id>               # show skill detail
par skill reload                  # force filesystem rescan
```

---

## SDK API

### Python

```python
from par_runtime import Runtime
import json

rt = Runtime(config_json)

# Register a skill programmatically
rt.register_skill(json.dumps({
    "schema_version": 1,
    "id": "my-skill",
    "name": "My Skill",
    "description": "Does something useful.",
    "system_prompt_override": "You are a specialist.",
    "tool_filter": "Only [read_file]",
    "trigger": "Auto"
}))

# List all registered skills
skills = rt.list_skills()
for s in skills:
    print(f"  {s['id']}: {s['description']}")
```

### OCaml

```ocaml
(* Create a skill descriptor *)
let descriptor =
  Par.Runtime.make_skill
    ~id:"my-skill"
    ~description:"Does something useful."
    ~system_prompt_override:"You are a specialist."
    ~tool_filter:(Par.Types.Only ["read_file"])
    ~trigger:Par.Types.Auto
    ()
  |> Result.get_ok

(* Register it *)
let _ = Par.Runtime.register_skill rt descriptor

(* List all skills *)
let skills = Par.Runtime.list_skills rt
List.iter (fun s -> Printf.printf "  %s: %s\n" s.Par.Types.id s.Par.Types.description) skills
```

---

## Builtin skills

PAR ships with 4 starter skills. Override them by creating a skill with the same `id` in `~/.par/skills/` or `./.par/skills/`:

| ID | Trigger | Tools | Description |
|----|---------|-------|-------------|
| `code-reviewer` | Keyword: review, audit | read_file, grep, glob | Reviews code for bugs, security, style |
| `summarizer` | Auto | All | Summarizes long text into key points |
| `translator` | Keyword: translate, 翻译 | All | Translates between languages |
| `rag-assistant` | Auto | add_documents, invoke_with_rag | Answers using retrieved document context |

---

## Examples

### Example 1: Custom skill — Python data analyst

```bash
mkdir -p ~/.par/skills/python-analyst
cat > ~/.par/skills/python-analyst/skill.md << 'EOF'
---
schema_version: 1
id: python-analyst
name: Python Data Analyst
description: Analyze Python code for data science patterns. Use when the user asks about pandas, numpy, or data analysis code.
system_prompt_override: "You are a Python data science expert. Focus on pandas/numpy patterns, performance, and correctness."
tool_filter: Only [read_file, grep, glob]
trigger: Keyword [pandas, numpy, dataframe, data analysis]
---

# Python Data Analyst

When analyzing Python code:
1. Check for common pandas anti-patterns (chained indexing, in-place modification)
2. Verify numpy vectorization opportunities
3. Suggest type annotations for data science functions
4. Flag potential memory issues with large DataFrames
EOF
```

### Example 2: Override a builtin

To customize the `summarizer` skill, create a project-level skill that overrides the builtin:

```bash
mkdir -p .par/skills/summarizer
cat > .par/skills/summarizer/skill.md << 'EOF'
---
schema_version: 1
id: summarizer
name: Tech Summarizer
description: Summarize technical documents. Use when the user asks for a summary or TL;DR.
system_prompt_override: "You are a technical writer. Summarize with structured headers, preserve all technical terms, and include a one-sentence TL;DR at the top."
tool_filter: All
trigger: Auto
---

# Tech Summarizer

Format summaries as:
## TL;DR
[one sentence]

## Key Points
- bullet points

## Technical Details
[code blocks, configs, commands]
```

Because this is in `./.par/skills/` (project), it takes precedence over the builtin `summarizer` (which is lowest priority).

### Example 3: Deterministic keyword skill

A skill that activates immediately on keyword match, without LLM judgment:

```bash
mkdir -p ~/.par/skills/log-parser
cat > ~/.par/skills/log-parser/skill.md << 'EOF'
---
schema_version: 1
id: log-parser
name: Log Parser
description: Parse and analyze log files. Use when the user mentions logs, stack traces, or error output.
system_prompt_override: "You are a log analysis expert. Extract timestamps, error codes, and stack traces. Correlate events across log lines."
tool_filter: Only [read_file, grep, bash]
trigger: Keyword [log, stack trace, error output, traceback] deterministic
---

# Log Parser

1. Identify the log format (syslog, JSON, plain text)
2. Extract all ERROR/WARN lines
3. Find the root cause (first error in the chain)
4. Suggest fixes based on the error pattern
```

The `deterministic` flag means: if the user's message contains "log", "stack trace", "error output", or "traceback", this skill activates immediately — no LLM round-trip needed.

---

## Tiered context loading

PAR uses a 2-level context loading model inspired by Anthropic Agent Skills:

| Level | What | When loaded | Token cost |
|-------|------|-------------|------------|
| **L1** | `id`, `name`, `description` (frontmatter only) | At startup, always in memory | ~100 tokens per skill |
| **L2** | Markdown body (instructions) | Only when skill activates | Variable (skill-specific) |

This means you can install 50+ skills without bloating every LLM call — only the L1 metadata is always resident. The L2 body is loaded on-demand when a skill triggers.

---

## Migration and versioning

The `schema_version` field (currently `1`) lets PAR evolve the skill format without breaking existing skills:

- **Unknown versions** are rejected at load time with a clear error: `"skill targets schema_version 2, current is 1. See MIGRATION.md."`
- **Old versions** may be auto-migrated (future) or rejected with upgrade instructions.

When PAR adds new frontmatter fields in v0.6+, skills with `schema_version: 1` will still work — new fields default to sensible values.

---

## See also

- [Agent API](agent.md) — agents, `Runtime.invoke`, tool handlers
- [Tools](tools.md) — 20 builtin tools, custom registration
- [RAG API](rag.md) — embeddings, vector store, retrieval (used by `rag-assistant` skill)
- [Architecture](../explanation/architecture.md) — how PAR works internally
