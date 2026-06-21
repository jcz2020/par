<!-- language: en -->

**English** · [简体中文](zh-CN/cli.md)

> Translated to English for v0.3.2. Source-of-truth: bin/ CLI implementation.

# par_cli — CLI Reference

par_cli is the command-line tool for P-A-R (Programmable Agent Runtime). It wraps the par SDK and provides multiple modes: an interactive REPL, single-shot queries, a configuration wizard, history lookup, and usage statistics.

Command structure:

```
par [global options] <subcommand> [subcommand options] [arguments]
```

Subcommands:

| Subcommand | Purpose |
|------------|---------|
| (none) | Start interactive REPL (default) |
| `config` | Run the configuration wizard |
| `ask` | Single-shot query |
| `update` | Check for updates and update par to the latest version |
| `history <session_id>` | Show event history for a session |
| `stats` | Show usage statistics and recent sessions |

## Install

Build from source:

```bash
git clone https://github.com/jcz2020/par.git && cd par
opam install . --deps-only
dune build @install
dune install
```

After installation the `par` executable is available. Run `par --version` to see the installed version (sourced from `dune-project` via `Cmdliner.Cmd.info`'s `~version` declaration).

To install to a custom prefix:

```bash
dune install --prefix /path/to/prefix
```

## Global options

The following options apply to both `par` (REPL) and `par ask`. They override the corresponding fields in the configuration file.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `--provider PROVIDER` | string | `openai` (from config) | LLM provider: `openai` or `anthropic` |
| `--api-key KEY` | string | (from config) | API key, overrides `api_key` in config |
| `--api-base URL` | string | (from config or provider default) | Custom API base URL, overrides config |
| `--model NAME` | string | `gpt-4` (from config) | Model name, overrides `model` in config |
| `--persistence BACKEND` | string | `sqlite` (from config) | Persistence backend: `sqlite` or `postgres` |
| `--db-uri URI` | string | `postgresql://localhost/par` (when postgres) | PostgreSQL connection URI, only effective with postgres backend |
| `--temperature FLOAT` | float | `0.7` (from config) | Sampling temperature, overrides config |
| `--system-prompt PROMPT` | string | `You are a helpful assistant.` (from config) | Agent system prompt, overrides config |
| `--max-iterations N` | int | `10` | Maximum ReAct loop iterations |
| `--max-tokens N` | int | (from config) | Max tokens per LLM response |
| `--top-p FLOAT` | float | (from config) | Top-p sampling parameter (0.0–1.0) |
| `--no-parallel-tools` | flag | (from config) | Disable parallel tool execution |
| `--retention-days N` | int | `7` | Event retention in days. 0 = never prune |

All global options are optional (`opt` type). When not specified, values are read from `~/.par/config.json`.

## par (default: REPL)

Starts an interactive ReAct agent conversation. Reads the configuration file and enters a readline loop.

**Usage**

```
par [global options]
```

**Prerequisites**

You must run `par config` first to create `~/.par/config.json`. Otherwise:

```
Configuration file not found. Run `par config` to set up.
```

**REPL behavior**

On startup:

```
Enter a message to start the conversation (Ctrl+D to exit)
```

The prompt is `> `. Each line of input is sent as a message to the agent (agent id: `default-agent`), and the agent's text response is printed directly. Blank lines (after trimming) are ignored and not sent.

### REPL commands

Inside the REPL, input starting with `/` is parsed as a command:

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/steer <message>` | Inject a steering message (takes effect on the next turn) |
| `/followup <message>` | Inject a follow-up directive (takes effect on the next turn) |
| `/health` | Display runtime health status (JSON) |
| `/metrics` | Display runtime metrics (JSON) |
| `/quit` or `/exit` | Exit the REPL |

Plain text input is sent as a user message to the agent.

**Exiting**

`Ctrl+D` (EOF) exits the REPL with a farewell message.

**Output format**

- When there is a text response: the response text is printed directly.
- When there is no text response: the full LLM response is printed as formatted JSON (`Yojson.Safe.pretty_to_string`).

**Exit code**

- `0`: normal exit (Ctrl+D)
- `1`: config file missing / runtime creation failed / agent registration failed / LLM call error

**Examples**

```bash
# Start REPL with config file defaults
par

# Specify Anthropic provider and model
par --provider anthropic --model claude-3-sonnet-20240229

# Use a custom system prompt
par --system-prompt "You are an OCaml expert"
```

## par config

Runs the interactive configuration wizard. Guides you through setting up the LLM provider, API key, model, and other parameters. Results are written to the configuration file.

**Usage**

```
par config
```

This command takes no additional options.

**Wizard flow**

1. If the config file already exists, show a summary of the current configuration and prompt for changes; otherwise show a welcome message.
2. Prompt for each field (shows default values; press Enter to keep):

| Field | Prompt text | Default | Description |
|-------|------------|---------|-------------|
| Provider | `Provider (openai/anthropic) [openai]:` | `openai` | Select the LLM provider |
| API Key | `API Key: ` | (none, must enter) | API key for the chosen provider |
| API Base URL | `API Base URL (default: https://api.openai.com/v1): ` | (none) | Optional custom URL. Press Enter to skip |
| Model name | `Model name [gpt-4]:` | `gpt-4` | Model identifier |
| Persistence | `Persistence (sqlite/postgres) [sqlite]:` | `sqlite` | Persistence backend type |
| DB URI | `DB URI (leave blank to skip): ` | (none) | Only shown when `postgres` is selected |
| Temperature | `Temperature [0.7]:` | `0.7` | Sampling temperature (float) |
| System prompt | `System prompt [You are a helpful assistant.]:` | `You are a helpful assistant.` | Agent system prompt |

3. On completion: `Configuration saved to ~/.par/config.json`

**Configuration file location**

```
~/.par/config.json
```

The `~/.par/` directory is created automatically on first save (permissions `0o755`).

**Exit codes**

- `0`: configuration saved successfully
- `1`: stdin hit EOF during the wizard (fields filled with defaults)

## par ask

Single-shot query mode. Sends one message to the agent, prints the response, and exits.

**Usage**

```
par ask "question" [global options]
```

**Positional arguments**

| Argument | Description |
|----------|-------------|
| `QUESTION` (required) | The question string to send |

**Prerequisites**

Same as REPL: `~/.par/config.json` must exist.

**Output format**

- When there is a text response: prints the response text followed by a newline.
- When there is no text response: prints the full LLM response JSON.

**Exit codes**

- `0`: successfully received a response
- `1`: config file missing / LLM call failed

**Examples**

```bash
# Basic query
par ask "What is the ReAct pattern?"

# Use Anthropic with a specific model
par ask "Explain OCaml GADTs" --provider anthropic --model claude-3-sonnet-20240229

# Override temperature and system prompt
par ask "Write a quicksort" --temperature 0.2 --system-prompt "Answer in OCaml"
```

## par history

Show event history for a specific session. Displays events from the persistence backend in chronological order.

**Usage**

```
par history <session_id>
```

**Positional arguments**

| Argument | Description |
|----------|-------------|
| `SESSION_ID` (required) | The session ID to query |

**Prerequisites**

Same as REPL: `~/.par/config.json` must exist.

**Exit codes**

- `0`: history displayed successfully
- `1`: config file missing / session not found

## par stats

Show usage statistics and recent sessions. Displays aggregate metrics from the persistence backend.

**Usage**

```
par stats
```

This command takes no additional options.

**Prerequisites**

Same as REPL: `~/.par/config.json` must exist.

**Exit codes**

- `0`: stats displayed successfully
- `1`: config file missing / persistence error

## Configuration file format

The configuration file is standard JSON at `~/.par/config.json`. Here is a complete example with all fields:

```jsonc
{
  // LLM provider identifier. Options: "openai" (default) or "anthropic"
  "provider": "openai",

  // API key. Required; empty string will cause API call failures
  "api_key": "sk-xxxxxxxxxxxxxxxx",

  // Custom API base URL. Optional; null means use the provider default
  // OpenAI default: https://api.openai.com/v1
  // Anthropic default: https://api.anthropic.com
  // OpenAI-compatible: e.g. http://localhost:8000/v1
  "api_base": null,

  // Model name. Must match a model supported by the provider
  // OpenAI examples: "gpt-4", "gpt-4o", "gpt-3.5-turbo"
  // Anthropic examples: "claude-3-sonnet-20240229", "claude-3-opus-20240229"
  "model": "gpt-4",

  // Persistence backend. Options: "sqlite" (default) or "postgres"
  "persistence": "sqlite",

  // PostgreSQL connection URI. Only effective when persistence is "postgres"
  // Default: "postgresql://localhost/par"
  "db_uri": null,

  // Sampling temperature. Float, typically 0.0–2.0
  "temperature": 0.7,

  // Agent system prompt
  "system_prompt": "You are a helpful assistant.",

  // Maximum ReAct loop iterations
  "max_iterations": 10,

  // Max tokens per LLM response. null means no limit, uses model default
  "max_tokens": null,

  // Top-p (nucleus) sampling parameter, range 0.0–1.0. null uses provider default
  "top_p": null,

  // Whether to allow parallel execution of multiple tool calls
  "parallel_tool_execution": true,

  // Event retention in days. 0 = never prune. Default: 7
  "event_retention_days": 7,

  // System prompt template variables (set by par config)
  "template_variables": {
    "role": "AI assistant",
    "task": "Answer questions and provide help"
  },

  // Custom system prompt template. null uses the built-in default template
  "system_prompt_template_override": null
}
```

**Field notes**

- `api_base` and `db_uri` are optional; set to `null` or omit them in JSON
- `provider` values are case-insensitive (internally matched with `String.lowercase_ascii`)
- CLI flags take priority over the config file; unset CLI flags fall back to config values

## System prompt template

The CLI has a built-in default template:

```
You are {{role}}, your task is {{task}}.
Available tools: {{available_tools}}.
Current time: {{current_time}}.
```

Template variables:
- `role`, `task` — user-defined, set through `par config`
- `available_tools` — auto-filled (list of currently registered tools)
- `current_time` — auto-filled (ISO 8601 format)

Advanced users can set the `system_prompt_template_override` field in `~/.par/config.json` to customize the full template.

## Environment variables

par_cli does not read environment variables directly. API keys are passed through the configuration file or the `--api-key` CLI flag.

If you use an OpenAI-compatible provider that requires environment variable authentication:

| Variable | Description |
|----------|-------------|
| `HOME` | Used to locate the config directory `~/.par/`. Falls back to `/` if unset |
| `OPENAI_API_KEY` | par_cli does not read this directly, but OpenAI SDKs might |
| `ANTHROPIC_API_KEY` | par_cli does not read this directly, but Anthropic SDKs might |

**Best practice**: write keys to `~/.par/config.json` (via `par config`), or pass `--api-key` each time.

## Examples

Here are 8 practical usage scenarios:

**1. First-time setup**

```bash
par config
```

Starts the wizard — follow the prompts for Provider, API Key, Model, etc.

**2. Use an OpenAI-compatible endpoint**

```bash
par config
# Provider: openai
# API Key: <your key>
# API Base URL: http://localhost:8000/v1
# Model: my-model

par ask "Hello"
```

**3. Use Anthropic**

```bash
par config
# Provider: anthropic
# API Key: <your Anthropic key>
# Model: claude-3-sonnet-20240229

par ask "Explain Rust's ownership system"
```

**4. Interactive conversation**

```bash
par
```

Enter the REPL, type at the `> ` prompt, `Ctrl+D` to exit.

**5. Precise query with low temperature**

```bash
par ask "What is 1+1?" --temperature 0.0
```

**6. Custom system prompt**

```bash
par --system-prompt "You only answer in OCaml code" ask "What is machine learning?"
```

**7. PostgreSQL backend**

```bash
par --persistence postgres --db-uri "postgresql://user:pass@host/par_db"
```

**8. Single-shot in a script**

```bash
result=$(par ask "Translate to French: Hello World" --temperature 0.1)
echo "$result"
```

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Command succeeded |
| `1` | Error occurred (config missing, runtime creation failed, LLM call failed, etc.) |

`par config` always exits with `0` (config file written successfully).

`par` and `par ask` return `1` when:

- `~/.par/config.json` does not exist (outputs: `Configuration file not found. Run par config to set up.`)
- SQLite database open failure
- Runtime creation failure
- Agent registration failure
- LLM call failure (including timeout, rate limit, permission denied)
- PostgreSQL backend dependencies not installed (outputs: `PostgreSQL backend requires 'opam install postgresql' then rebuild`)

## Troubleshooting

### Configuration file not found

```
Configuration file not found. Run `par config` to set up.
```

**Cause**: `~/.par/config.json` does not exist.

**Fix**: Run `par config` to create the configuration file.

### SQLite database error

```
Error opening SQLite database: ...
```

**Cause**: Insufficient permissions on the `par.db` file in the current directory, or disk is full.

**Fix**: Check write permissions in the current directory, or delete the old `par.db` and retry.

### PostgreSQL backend unavailable

```
PostgreSQL backend requires 'opam install postgresql' then rebuild
```

**Cause**: The PostgreSQL persistence backend requires an additional OCaml package.

**Fix**:

```bash
opam install postgresql
dune clean && dune build
```

### API call failures

```
Error: External failure: ...
Error: Rate limited
Error: Permission denied: ...
```

**Cause**: Invalid API key, quota exhausted, or network issue.

**Fix**:

1. Check `api_key` in `~/.par/config.json`
2. Use `--api-base` to confirm the API endpoint is reachable
3. Verify `provider` matches the key type (OpenAI keys don't work on Anthropic endpoints)

### OpenAI-compatible provider connection failure

**Cause**: `api_base` URL format is incorrect, or the provider's API compatibility is incomplete.

**Fix**: Confirm the URL ends with `/v1` (or the correct path for your provider), and that the provider supports the OpenAI Chat Completions API format.

### Configuration file JSON parse error

**Cause**: Syntax error introduced during manual editing.

**Fix**: Run `par config` to regenerate, or validate the JSON with `python3 -m json.tool ~/.par/config.json`.

## See also

- [Quickstart](quickstart.md) — installation and first-use guide
- [SDK overview](sdk/overview.md) — par SDK architecture and modules
- [Agent docs](sdk/agent.md) — agent registration and configuration
- [Workflow docs](sdk/workflow.md) — workflow engine usage guide
- [Middleware docs](sdk/middleware.md) — middleware configuration reference
