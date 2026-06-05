<!-- language: en -->

# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.3.1   | :white_check_mark: |
| < 0.3.0 | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability in PAR, please report it responsibly:

1. **Do not** open a public GitHub issue.
2. Email the maintainer at the address listed in the GitHub repository's security advisories, or use the GitHub "Report a vulnerability" feature.
3. Include: the affected version, steps to reproduce, and the potential impact.
4. You will receive an acknowledgment within 48 hours. The maintainer will assess severity and coordinate a fix.

We ask that you give us 90 days to address the issue before any public disclosure.

## Security Features

PAR includes several security-relevant mechanisms:

### Bash tool (v0.3.1)

The bash tool is designed to make shell injection unrepresentable at the type level:

- **Safe_command ADT** — no `Exec_raw_shell` constructor; all commands must be decomposed into `argv` arrays.
- **Bash_policy functor** — 3 presets (`ReadOnly`, `ReadOnlyNoNet`, `Coder`); injected at `Runtime.create` time. No policy = no execution.
- **31-entry Bash_blacklist** — regex patterns for dangerous commands (`rm -rf /`, `dd if=`, `mkfs`, fork bombs, etc.).
- **Environment sanitization** — strips `*_SECRET*`, `*_KEY*`, and similar patterns from subprocess environment by default.
- **CWD locking** — `sandboxed_path` abstract type enforces working-directory-relative paths.
- **Risk scoring** — `assess_risk` evaluates command risk at ADT construction time; emitted via `Bash_invoked` event.

See [docs/sdk/tools.md](docs/sdk/tools.md) for the full bash tool reference.

### MCP client (v0.3.1)

Connecting to an MCP server is a trust decision:

- The runtime spawns the server as a child process over stdio; it does not auto-trust `serverInfo.name` from the protocol.
- `command` should point to a trusted absolute path (relative paths are ambiguous).
- `args` and `env` must not contain secrets (they appear in `ps` output).
- `Fail_fast` startup policy is the default — any server that fails to start prevents the runtime from starting.

See [docs/sdk/mcp.md](docs/sdk/mcp.md) for the full MCP security checklist.

### Event bus audit trail

The event bus emits typed events for every security-relevant transition:

- `Bash_invoked` / `Bash_completed` — full command lifecycle with risk scores and exit codes.
- `Mcp_server_started` / `Mcp_server_failed` / `Mcp_server_stopped` — MCP server lifecycle.
- `Mcp_tool_invoked` / `Mcp_tool_completed` — MCP tool call audit with duration tracking.

Events are persisted to SQLite or Postgres and can be queried for post-incident analysis.

## Threat Model

### What PAR protects against

- Shell injection via the type system (no raw string execution).
- Accidental exposure of secrets in subprocess environments.
- Unbounded subprocess execution (60-second default timeout, process group cleanup).
- Overly broad file access (CWD-relative path enforcement).

### What PAR does NOT protect against (yet)

- **OS-level sandboxing** — PAR does not use bwrap, landlock, or seccomp. A compromised subprocess can still access the network and filesystem within the user's permissions. OS-level sandboxing is planned for a future `par_sandbox` opam package (v0.4+ evaluation).
- **Malicious MCP servers** — PAR spawns and communicates with MCP servers, but does not audit what a server does with tool call arguments beyond standard JSON-RPC error handling. Choose MCP servers from trusted sources.
- **LLM prompt injection** — PAR provides the `Pii_mask` middleware and `Sanitize_tool_output` middleware as defense-in-depth, but does not guarantee protection against adversarial LLM outputs.
