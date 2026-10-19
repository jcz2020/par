<!-- language: en -->

**English** · [简体中文](https://github.com/jcz2020/par/blob/main/zh/sdk/tools.md)

> Translated to English for v0.3.2. Source-of-truth: the OCaml modules in lib/tools/.

# Tool API Reference

This document describes the 24 built-in tools provided by the P-A-R SDK. New tools are registered through `Runtime.register_tool`; the tool description gets injected into the LLM's system prompt so the model knows when to call which tool.

**Version**: v0.7.1
**Total tools**: 24 (19 from v0.3.0 + `bash` in v0.3.1 + 3 memory tools in v0.7.1 + `apply_patch` in v0.11.0)

## Overview

Each tool carries the following metadata at registration time:

```ocaml
type tool_descriptor = {
  name : string;                         (* tool name, referenced by the agent call *)
  description : string;                  (* description, injected into the LLM system prompt *)
  input_schema : Yojson.Safe.t;          (* JSON Schema *)
  output_schema : Yojson.Safe.t option;  (* optional JSON Schema for structured output *)
  permission : tool_permission;          (* Allow / Confirm / Deny / ... *)
  timeout : float option;                (* seconds; None means no timeout *)
  concurrency_limit : int option;        (* max concurrent invocations *)
  on_update : (string -> unit) option;   (* v0.3+ progress callback *)
  cache_control : cache_control option;  (* optional provider-side cache hint, e.g. Anthropic prompt caching *)
}
```

The tools fall into five categories by purpose:

| Category | Count | Tools |
|------|------|------|
| math | 1 | `calculator` |
| utility | 9 | `get_time` / `echo` / `generate_uuid` / `hash_text` / `generate_password` / `string_stats` / `json_format` / `convert_temperature` / `url_encode` |
| web | 3 | `fetch_url` / `read_webpage` / `web_search` |
| fs (read) | 4 | `read` / `ls` / `find` / `grep` |
| fs (write) | 2 | `write` / `edit` |
| patch | 1 | `apply_patch` |
| exec | 1 | `bash` (added in v0.3.1, **the only one with a security policy**) |
| memory | 3 | `recall_memory` / `remember_memory` / `search_history` (added in v0.7.1, **require `Memory_service`**) |

All tools except `bash` use `permission = Allow`. The file-path tools (`read` / `ls` / `find` / `grep` / `write` / `edit`) reject absolute paths and any path containing `:`. The memory tools (`recall_memory` / `remember_memory` / `search_history`) require a configured `Memory_service` and read scope from `Invoke_context.get_current_exn().session_id`.

## Quick Index

| Tool | Category | Risk | Timeout | Notes |
|------|------|------|------|------|
| `calculator` | math | low | 5s | `+`/`-`/`*`/`/` expression evaluation |
| `get_time` | utility | low | 2s | returns UTC time in ISO 8601 |
| `echo` | utility | low | 2s | echoes back the input string |
| `generate_uuid` | utility | low | 1s | UUID v4 |
| `hash_text` | utility | low | 2s | md5 / sha1 / sha256 (default sha256) |
| `generate_password` | utility | low | 1s | length 4-128, symbols optional |
| `string_stats` | utility | low | 1s | character / word / line count |
| `json_format` | utility | low | 2s | validate + pretty-print |
| `convert_temperature` | utility | low | 1s | C / F / K conversion |
| `url_encode` | utility | low | 1s | encode / decode |
| `fetch_url` | web | medium | 15s | HTTP GET, 10MB cap |
| `read_webpage` | web | medium | 15s | fetch + HTML parse, strip script/style |
| `web_search` | web | medium | 15s | DuckDuckGo lite |
| `read` | fs (read) | low | 30s | 10MB cap; binary returns base64 |
| `ls` | fs (read) | low | 10s | directory listing, sorted by name |
| `find` | fs (read) | low | 30s | glob pattern, skips .git / _build etc. |
| `grep` | fs (read) | low | 30s | regex match, output `path:line:text` |
| `write` | fs (write) | medium | 30s | optional `create_dirs` for auto mkdir -p |
| `edit` | fs (write) | medium | 30s | batch replace; overlapping ranges are rejected |
| `apply_patch` | patch | medium | 30s | atomic unified-diff application across files |
| **`bash`** | **exec** | **high** | **60s** | **added in v0.3.1, 9-layer safety mechanism** |
| `recall_memory` | memory | low | 10s | search memories by keyword, scoped by session |
| `remember_memory` | memory | low | 10s | store a new memory, scoped by session |
| `search_history` | memory | low | 10s | search conversation history across sessions |

---

## math category

### calculator

Evaluates arithmetic expressions, supports `+`, `-`, `*`, `/`, and parentheses.

**Input**:
```json
{ "expression": "2 + 3 * 4" }
```

**Output** (number; irrationals are kept as float):
```json
14
```

**Note**: the implementation is a hand-written lexer plus recursive descent (no external eval library). It accepts only numbers and the four basic operators. Whitespace is ignored, but **negative number prefixes are not supported** (`"-1+2"` parses as `1 + 2`; write it as `"0-1+2"` instead).

---

## utility category

### get_time

Returns the current UTC time in ISO 8601 format.

**Input**: `{}` (no parameters)

**Output**:
```json
"2026-06-04T12:34:56Z"
```

### echo

Echoes back the input text (useful for debugging or inter-agent communication).

**Input**:
```json
{ "text": "hello" }
```

**Output**:
```json
"hello"
```

### generate_uuid

Generates a random UUID v4.

**Input**: `{}`

**Output**:
```json
"550e8400-e29b-41d4-a716-446655440000"
```

### hash_text

Hashes text. Supports `md5` / `sha1` / `sha256` (default `sha256`; case-insensitive algorithm name).

**Input**:
```json
{ "text": "hello", "algorithm": "sha1" }
```

**Output**:
```json
{ "hash": "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d", "algorithm": "sha1" }
```

**Security note**: MD5 and SHA1 are no longer collision-resistant. Use them only for non-security purposes (deduplication, cache keys).

### generate_password

Generates a random password, length 4-128 (values outside this range are clamped automatically). Symbols are included by default.

**Input**:
```json
{ "length": 24, "include_symbols": true }
```

**Output**:
```json
"a8K!mZ3xQ9wL7nV2"
```

**Note**: uses `Random.State.make_self_init`, so there's no cryptographic-strength guarantee. For production, use a dedicated library.

### string_stats

Counts characters, words, and lines. Words are split on whitespace.

**Input**:
```json
{ "text": "hello world\nfoo bar" }
```

**Output**:
```json
{ "characters": 22, "words": 4, "lines": 2 }
```

### json_format

Validates and pretty-prints a JSON string.

**Input**:
```json
{ "json": "{\"a\":1,\"b\":2}" }
```

**Output**:
```json
"{\n  \"a\": 1;\n  \"b\": 2\n}"
```

**Note**: parse failure returns `Error (Invalid_input "Invalid JSON: ...")` with `retryable = false`.

### convert_temperature

Converts between C, F, and K.

**Input**:
```json
{ "value": 100, "from": "C", "to": "F" }
```

**Output**:
```json
{ "value": 212, "unit": "F", "original_value": 100, "original_unit": "C" }
```

### url_encode

URL-encodes or URL-decodes. Encode is the default; pass `decode: true` to reverse. On decode, `+` is treated as a space (form-encoding compatible).

**Input**:
```json
{ "text": "hello world", "decode": false }
```

**Output**:
```json
"hello%20world"
```

---

## web category

The three network tools share `validate_url` (only `http://` and `https://` are allowed), a `max_download_size` of 10MB, system CA certificates, and TLS hostname verification.

### fetch_url

HTTP GET, returns the raw text.

**Input**:
```json
{ "url": "https://example.com", "max_length": 50000 }
```

**Output**:
```json
{
  "url": "https://example.com",
  "status": 200,
  "content": "...",
  "content_length": 1234,
  "truncated": false
}
```

### read_webpage

Fetches the URL, parses the HTML, strips `<script>` / `<style>` / `<noscript>`, and returns the plain text.

**Input**:
```json
{ "url": "https://example.com", "max_length": 10000 }
```

**Output**:
```json
{
  "url": "https://example.com",
  "title": "Example Domain",
  "text": "...",
  "text_length": 567,
  "truncated": false
}
```

**Note**: depends on `lambdasoup`. HTTP 4xx / 5xx returns `Error (External_failure "HTTP <code>")`; 5xx and 429 are flagged with `retryable = true`.

### web_search

DuckDuckGo lite search.

**Input**:
```json
{ "query": "ocaml lwt tutorial", "max_results": 5 }
```

**Output**:
```json
{
  "query": "ocaml lwt tutorial",
  "results": [
    { "title": "...", "url": "...", "snippet": "..." }
  ],
  "result_count": 5
}
```

**Note**: scrapes DuckDuckGo lite HTML (no API key required). Network or parse failure returns `Error (External_failure ...)`.

---

## fs (read) category

The four read tools reject absolute paths and any path containing `:` (Windows drive-letter guard). `find` / `grep` skip `.git` / `node_modules` / `_build` / `_opam` by default.

### read

Reads file contents with an optional line offset and line limit.

**Input**:
```json
{ "path": "src/main.ml", "offset": 0, "limit": 100 }
```

**Output** (line-numbered, similar to `cat -n`):
```json
"   1\topen Par\n   2\t...\n"
```

**Limits**:
- File size <= 10MB (exceeding the cap returns `Error (Invalid_input "File too large")`)
- Path must be relative to workspace root, or an absolute path under workspace root

### ls

Lists directory contents.

**Input**:
```json
{ "path": "." }
```

**Output**:
```json
{
  "path": ".",
  "entries": [
    { "name": "src", "type": "dir", "size": null, "modified": 1717... },
    { "name": "README.md", "type": "file", "size": 4321, "modified": 1717... }
  ]
}
```

**Note**: entries are sorted by name ascending. `type` is one of `dir` / `file` / `link` / `other` / `unknown`. A non-directory path returns `Error (Invalid_input "Not a directory")`.

### find

Glob match on filenames (`**` crosses directories; `*` crosses a single path component and does not include `/`).

**Input**:
```json
{ "pattern": "**/*.ml", "path": "." }
```

**Output**:
```json
["src/main.ml", "src/agent.ml", "test/test.ml"]
```

### grep

Regex search across file contents. The `path` directory is searched recursively; `glob` filters by filename.

**Input**:
```json
{ "pattern": "TODO", "path": "lib", "glob": "*.ml", "context_lines": 2 }
```

**Output** (one `path:line:match` per entry):
```json
["lib/runtime.ml:142:(* TODO: handle ... *)"]
```

**Note**: the regex syntax is OCaml `Str` (POSIX extended regex). The current implementation ignores `context_lines` (the parameter is kept for future extension).

---

## fs (write) category

### write

Writes a file. Pass `create_dirs: true` to run `mkdir -p` automatically.

**Input**:
```json
{ "path": "out/result.txt", "content": "hello", "create_dirs": true }
```

**Output**:
```json
"Wrote 5 bytes to out/result.txt"
```

**Note**: overwrites an existing file. If the directory is missing and `create_dirs` is `false`, the tool returns an error.

### edit

Batch exact-string replace. **Overlapping ranges are rejected** (this avoids ambiguity in edit ordering).

**Input**:
```json
{
  "path": "src/main.ml",
  "edits": [
    { "old": "let x = 1", "new": "let x = 2" },
    { "old": "foo", "new": "bar" }
  ]
}
```

**Output**:
```json
"Applied 2 edit(s) to src/main.ml"
```

**Note**:
- Every `old` value must be an **exact substring** of the file (including spaces, newlines, and indentation)
- Uses `Str.replace_first`, so it does not modify later occurrences of the same string
- Overlap detection: if two `old` ranges overlap in the file, the tool rejects them with `Error (Invalid_input "Overlapping edits")`

---

## patch category (added in v0.11.0)

### apply_patch

Applies a standard unified diff to workspace files atomically. Either all files in the patch succeed, or none are modified. Useful when an LLM generates a multi-file changeset and you want all-or-nothing semantics instead of sequential `edit` calls that can leave a partially-applied state.

**Input**:
```json
{
  "patch": "--- a/src/main.ml\n+++ b/src/main.ml\n@@ -1,5 +1,5 @@\n open Par\n-let x = 1\n+let x = 2\n",
  "dry_run": false
}
```

Field reference:
- `patch` (required): a standard unified diff string. Supports multi-file patches. Uses `--- a/path` / `+++ b/path` headers. Follows the `git apply` convention: context offset matching tolerates minor offset shifts.
- `dry_run` (optional, default `false`): when `true`, validates the patch and reports what would change without writing any files.

**Output** (on success):
```json
{
  "files_changed": 1,
  "files": [
    { "path": "src/main.ml", "status": "applied", "insertions": 1, "deletions": 1 }
  ]
}
```

**Dry-run output**:
```json
{
  "files_changed": 1,
  "dry_run": true,
  "files": [
    { "path": "src/main.ml", "status": "would_apply", "insertions": 1, "deletions": 1 }
  ]
}
```

**File creation and deletion**: A diff where the old file is `/dev/null` creates a new file. A diff where the new file is `/dev/null` deletes an existing file. Binary files are detected and skipped with a warning, never silently corrupted.

**Atomicity guarantee**: the tool validates every file in the patch before writing to any. If any hunk fails to apply (reject), no files are written and the tool returns an error with the full list of rejections. This prevents partial application that could leave the workspace in an inconsistent state.

**Known limitation**: a crash or process kill mid-write may leave individual files in a partially-written state. The atomicity guarantee covers the logical patch (all-or-nothing across files), not crash-safety of individual file writes. For crash-resilient workflows, combine with a version control system.

**Concurrency semantics**: overlapping patches on the same file follow last-writer-wins, the same convention as `write` and `edit`.

**Error messages**: patch rejections use the `[patch]` marker prefix:

```
[patch] Hunk #1 at line 15 failed: context does not match.
File: src/main.ml. The patch may have been generated against a different revision.
Read the file first, then regenerate the patch against the current content.
```

Path rejections (absolute paths outside workspace, traversal, etc.) reuse the standard `[workspace]` markers from the file-path validation layer.

**When to prefer over `edit` / `write`**:
- Multi-file changesets where partial application is unacceptable
- Patches generated by `git diff` or `git format-patch`
- Situations where the LLM produces a unified diff rather than explicit old/new pairs

---

## bash (added in v0.3.1)

An LLM calling a shell is **the most dangerous built-in tool**. v0.3.0 deliberately skipped bash, then v0.3.1 designed it as a standalone piece. **The core idea**: move from "raw shell string + blacklist" to "**typed `Safe_command` ADT + policy functor + blacklist**", pushing safety checks from runtime back toward compile time.

### Purpose

Executes shell commands with three layers of defense:

1. **Type layer**: `argv` is forced to be `string list`, with **no `Exec_raw_shell` constructor** (shell injection is unrepresentable in the type)
2. **Policy layer**: `POLICY.filter` validates at runtime. Pick `Coder` / `ReadOnly` / `ReadOnlyNoNet` to fit the use case
3. **Blacklist layer**: 31 regex rules in `Bash_blacklist` as a final safety net (catches `rm -rf /`, `dd of=/dev/sda`, fork bombs, and similar)

### Input

```json
{
  "argv": ["ls", "-la"],
  "cwd": "src",
  "timeout": 30
}
```

Field reference:
- `argv` (required): argument array, **not a shell string**
- `cwd`: Working directory (relative to workspace root, or absolute path under workspace root). Default: `"."`
- `timeout`: max execution seconds, default `30`, hard cap `600`

### Output

```json
{
  "stdout": "...",
  "stderr": "...",
  "exit_code": 0,
  "duration": 0.123,
  "truncated": false
}
```

`truncated: true` means the output was clipped at 50KB / 2000 lines (a marker is appended at the end).

The installed `bash` handler waits for child exit **and** completion of stdout/stderr
copying before returning this result. This prevents short commands from returning
empty or partial output merely because copying lagged behind process exit. The
configured timeout covers both execution and output draining; a timed-out child is
terminated before the handler returns a timeout error.

### Three preset policies

| Policy | Network | Write | Use case |
|------|------|--------|------|
| `Coder` (default) | yes | yes | "AI writes code", only blacklist hits are blocked |
| `ReadOnly` | yes | no | pure read-only tools (`ls` / `cat` / `find` / `grep`) |
| `ReadOnlyNoNet` | no | no | maximum safety (sensitive code base review) |

### Custom policies

Implement the `Bash_policy.POLICY` module type and pass it to `Runtime.create`:

```ocaml
module type POLICY = sig
  val name : string
  val filter :
    Bash_safe_command.command ->
    (Bash_safe_command.command, Types.error_category) result
  val max_cpu_seconds : float
  val max_memory_kb : int
  val allow_network : bool
  val allow_write : bool
end

module MyStrictPolicy : Bash_policy.POLICY = struct
  let name = "MyStrict"
  let allow_network = false
  let allow_write = false
  let max_cpu_seconds = 10.0
  let max_memory_kb = 524288
  let filter cmd =
    (* your extra checks: blacklist, whitelist, argv limits, ... *)
    Ok cmd
end

(* Runtime.create ~bash_policy:(module MyStrictPolicy) *)
```

### Installation

The bash tool is **not** registered automatically with `Runtime.create`. You need to call `install_bash_tool` after `Runtime.create`:

```ocaml
let () = Eio_main.run (fun env ->
  Eio.Switch.run (fun sw ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clock = Eio.Stdenv.clock env in
    let fs = Eio.Stdenv.fs env in
    match Runtime.create ~config:my_config sw with
    | Error _ -> failwith "runtime create failed"
    | Ok rt ->
      (match Runtime.install_bash_tool ~process_mgr:mgr ~clock ~fs rt with
       | Ok () -> () (* bash tool is ready *)
       | Error e -> Printf.failwithf "bash install failed: %a"
           Yojson.Safe.pp (Types.error_category_to_yojson e))
  ))
```

**Idempotent**: a second call returns `Error (Invalid_input "bash tool already installed")`.

**Required parameters**:
- `process_mgr`: `Eio.Stdenv.process_mgr env`, used for `Eio.Process.spawn`
- `clock`: `Eio.Stdenv.clock env`, used to enforce the timeout (without a clock, timeouts do nothing)
- `fs`: `Eio.Stdenv.fs env`, the filesystem capability used to set the child process's cwd. Without it, bash commands would run in the PAR process's cwd, defeating the workspace sandbox.

### The 9-layer safety mechanism

| # | Mechanism | Implementation |
|---|------|------|
| 1 | Workspace-anchored sandbox | `Workspace.sandboxed_path` abstract type; the constructor rejects `..`, `:`, and sensitive prefixes (`/etc`, `~/.ssh`, etc.). Absolute paths under workspace root are admitted |
| 2 | Blacklist | 31 regex rules in `Bash_blacklist` (`rm -rf /`, `dd of=/dev/sda`, `:(){:|:&};:`, and similar) |
| 3 | Whitelist (optional) | implement whitelist logic in a custom `POLICY` |
| 4 | Timeout | `Eio.Process.spawn` + `Eio.Fiber.first` race; hard cap 600s |
| 5 | Process group cleanup | `Eio.Process` + `setpgid`; the timeout sends `killpg` to the whole group |
| 6 | Environment scrubbing | `Bash_policy.sanitize_env` strips `*_SECRET*` / `*_KEY*` / `AWS_*` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `GITHUB_TOKEN` and similar |
| 7 | Output truncation | 50KB byte cap + 2000 line cap; a marker is appended when triggered |
| 8 | ANSI stripping | removes CSI (`ESC[...]`) and OSC (`ESC]...BEL`) sequences |
| 9 | Audit log | the event bus emits `Bash_invoked` / `Bash_completed` events (carrying a `risk` rating and `argv`) |

### Security recommendations

- The default `Coder` policy is the right choice for "AI writes code" workflows (it matches pi's default behavior)
- For code review where the LLM should only inspect, use `ReadOnly`
- For sensitive code bases, use `ReadOnlyNoNet`
- **Never disable the timeout**. It's the last line of defense against fork bombs and network hangs
- Environment variables are scrubbed automatically. If you need to pass a secret, write it to a file and have the agent use the `read` tool (don't put it in the `env` field)
- The blacklist is a **last resort**, not the main defense. For safety-critical setups, set `allow_write:false` and `allow_network:false` in a custom `POLICY`
- **OS-level sandboxing** (bwrap / landlock) is not provided in v0.3.1

### Risk scoring

`Bash_safe_command.assess_risk` returns `Low` / `Medium` / `High` / `Critical`, attached to the `risk` field of the `Bash_invoked` event.

---

## memory category (added in v0.7.1)

The three memory tools require a configured `Memory_service`. They are auto-registered when `Runtime.create` receives a `?memory` parameter. All tools read scope from `Invoke_context.get_current_exn().session_id`, so memories are automatically isolated by session.

### recall_memory

Search stored memories by keyword query. Uses FTS5 full-text search with BM25 ranking.

**Input**:
```json
{ "query": "ocaml concurrency", "limit": 5 }
```

**Output**:
```json
{
  "results": [
    { "id": "...", "content": "...", "summary": "...", "scope": "...", "categories": [...], "created_at": 1717... }
  ],
  "count": 2
}
```

**Note**: `limit` defaults to 5, capped at 50. The `scope` is read from the current `invoke_context.session_id`.

### remember_memory

Store a new memory for future recall. Memories are scoped to the current session.

**Input**:
```json
{ "content": "The project uses OCaml 5.4 with Eio for concurrency", "summary": "OCaml concurrency stack", "categories": ["architecture", "tech-stack"] }
```

**Output** (the created `memory_object`):
```json
{ "id": "550e8400-...", "content": "...", "summary": "...", "scope": "...", "categories": ["architecture", "tech-stack"], "created_at": 1717... }
```

**Parameters**:
- `content` (required): the full text to remember
- `summary` (optional): short summary, indexed by FTS5
- `categories` (optional): tags for categorization

### search_history

Search conversation history from recent sessions. Performs a case-insensitive substring match across message text.

**Input**:
```json
{ "query": "Eio concurrency", "limit": 10 }
```

**Output**:
```json
{
  "results": [
    { "session_id": "...", "role": "user", "content": "Tell me about Eio..." }
  ],
  "count": 3
}
```

**Note**: `limit` controls the number of sessions to search (default 10, capped at 50). Matching text is truncated at 500 characters. The current session is searched first.

---

## Progressive tool loading (added in v0.11.0)

Once you register 50+ tools, tool JSON schemas dominate the prompt. Every invocation pays the full schema cost whether or not the model needs most of those tools. Progressive tool loading trades one round trip for a much smaller visible tool set: on demand, the model searches the hidden tools and pulls in only what it needs.

**Config**: set `max_tool_schema_tokens` on `runtime_config` (type `int option`, default `None`). Recommended starting value: `2000` when registering 50+ tools.

**Auto-switch semantics**: for each invocation, the engine estimates the token cost of the visible tool descriptor list (chars/4 heuristic via `Tool_budget.estimate_tokens`, a documented estimate, not an exact tokenizer). If the estimate exceeds the threshold, that invocation switches to progressive mode: only Always-layer builtin/core tools plus the `tool_search` meta-tool are exposed to the LLM. Deferred tools stay hidden but become reachable through search.

**Always-layer floor**: registry-internal layering splits tools into `Always | Searchable`. The Always layer is a guaranteed floor, never trimmed. If the floor alone exceeds the threshold, a warning is logged and the floor is still sent in full. MCP tools registered through the existing pull model are searchable once registered.

**tool_search usage**:

Input:
```json
{ "query": "temperature convert", "category": "utility" }
```

Output sketch (matched tools arrive with their full JSON schema):
```json
{
  "results": [
    { "name": "convert_temperature", "description": "C / F / K conversion", "input_schema": { "type": "object", "...": "..." } }
  ],
  "count": 1
}
```

Scoring is keyword-based: a name match weighs above a description match.

**Per-invocation promotion**: after a search, the matched tools are promoted for the current invocation only (per-call shadow list). The model can call them directly in subsequent turns of the same invocation. Promotion does not persist across invocations. Tools that were never exposed or promoted cannot be called at all; a hallucinated tool name fails with an unknown-tool error and never dispatches.

**Metrics**: the metrics snapshot now exposes `tool_schema_tokens_estimate` plus visible and deferred tool counts while running under progressive mode.

**Default is no behavior change**: leaving `max_tool_schema_tokens` unset (`None`) preserves exact current behavior. The feature is fully opt-in.

---

## Registering a custom tool

A tool is a simple `{ descriptor; handler }` pair. `Runtime.register_tool` is the convenience function; under the hood, you can register directly through `Tool_registry.register`:

```ocaml
let my_tool = { descriptor; handler } in
Tool_registry.register rt.tool_registry descriptor handler
```

The full example (with `tool_descriptor` field reference) is in [`agent.md`](agent.md).

## Security audit checklist

Self-check before submitting a new tool:

- [ ] The `permission` field is set (`Allow` / `Confirm` / `Deny` / `Role_based` / `Condition_based`)
- [ ] Long-running tools have a `timeout` set
- [ ] Resource-constrained tools have a `concurrency_limit` set
- [ ] Network / write tools emit audit events through the event bus
- [ ] File-path tools reject absolute paths and paths containing `:`
- [ ] Dangerous tools go through `Bash_policy` (when applicable)
- [ ] The `description` includes an input example (so the LLM knows how to call the tool)

## Actionable validation errors

Tool rejections in PAR don't just say "rejected." They explain *what went wrong* and *how to fix it*. This is a design principle: the error message is the model's only feedback signal in the ReAct loop. Putting rules in the system prompt made models refuse to attempt work; teaching at the point of rejection lets the model learn and retry correctly.

### Marker vocabulary

Three marker prefixes appear in tool error messages. Tool descriptions reference these same constants, so descriptions and rejections cannot drift apart (both are sourced from `lib/tools/tool_error.ml`).

| Marker | Meaning |
|--------|---------|
| `[workspace]` | Path validation failure (workspace sandbox rejection) |
| `[bash-policy]` | Bash command rejected by a policy (`Coder` / `ReadOnly` / custom) |
| `[patch]` | Patch hunk rejection (context mismatch, corrupt diff, or binary file) |
| `[cancelled]` | Tool call aborted because the run was cancelled |

### Workspace path rejections

All file tools (`read` / `ls` / `find` / `grep` / `write` / `edit`) share the same path validation. Four distinct rejection kinds exist, each with a specific message and metadata code:

**Path traversal** (code `workspace_parent_traversal`):
```
[workspace] Path rejected: '../etc/passwd' contains '..' (path traversal is not allowed).
Use a clean relative path like 'src/main.ml', or an absolute path under the workspace root.
```

**Colon in path** (code `workspace_colon`):
```
[workspace] Path rejected: 'C:\Users' contains ':' (reserved/ambiguous in tool arguments).
Use a path without ':'.
```

**Absolute path outside workspace** (code `workspace_absolute_outside`):
```
[workspace] Path rejected: '/etc/passwd' is an absolute path outside the workspace (2 root(s)).
Use a relative path like 'src/main.ml' (resolved against the workspace root)
or an absolute path under a workspace root.
```

Note the root count: the message tells the model how many workspace roots exist, so it can reason about which absolute paths are allowed.

**Protected location** (code `workspace_protected_location`):
```
[workspace] Path rejected: '~/.ssh/id_rsa' matches a protected location.
Choose a path outside protected system areas.
```

Two additional metadata codes exist for missing arguments:

| Code | When |
|------|------|
| `workspace_path_required` | Required `path` argument is missing |
| `pattern_required` | Required `pattern` argument is missing (for `find` / `grep`) |

### Bash policy rejections

When the bash tool's policy filter rejects a command, the error names the policy and the command:

```
[bash-policy] Command rejected by ReadOnly policy: ["rm", "-rf", "node_modules"].
This policy does not allow write operations. Use a read-only command or switch to a different policy.
```

The marker `[bash-policy]` matches what the bash tool description teaches the model, so the model knows this is a policy constraint, not a bug.

### Edit tool: old_text not found

Previously, the `edit` tool silently succeeded when `old_text` was not found in the file. This was the worst defect class: the model believed it made a change when nothing happened. Now it returns an error:

```
Edit failed: old_text was not found in 'src/main.ml'. The file may have changed
since it was last read, or the text does not match exactly (including whitespace).
Read the file first, then retry with the exact current text.
```

Metadata code: `edit_old_text_not_found`.

### Metadata codes reference

| Code | Tool | Meaning |
|------|------|---------|
| `workspace_parent_traversal` | read/ls/find/grep/write/edit | Path contains `..` |
| `workspace_colon` | read/ls/find/grep/write/edit | Path contains `:` |
| `workspace_absolute_outside` | read/ls/find/grep/write/edit | Absolute path outside workspace roots |
| `workspace_protected_location` | read/ls/find/grep/write/edit | Path matches a protected system area |
| `workspace_path_required` | read/ls/find/grep/write/edit | Missing required path argument |
| `pattern_required` | find/grep | Missing required pattern argument |
| `edit_old_text_not_found` | edit | `old_text` substring not found in file |
| `patch_hunk_reject` | apply_patch | Hunk context does not match file content |
| `patch_binary_skipped` | apply_patch | Binary file detected and skipped |

### Design principle: teach at the point of rejection

The markers and instructive messages exist because the error message is the *only* feedback signal a model receives during the ReAct loop. System-prompt rules ("never use absolute paths") caused models to refuse attempts entirely. In contrast, a rejection like `[workspace] Path rejected: '/tmp/out.txt' is an absolute path outside the workspace (1 root(s)). Use a relative path like 'src/main.ml' ...` gives the model enough context to retry with the correct form.

The constants in `lib/tools/tool_error.ml` are the single source of truth: tool descriptions TEACH the markers and tool handlers EMIT them. Both reference the same constants, so they cannot drift apart.

## See also

- [`agent.md`](agent.md) -- Agent definitions, Runtime API, tool registration
- [`overview.md`](overview.md) -- SDK architecture overview
- `lib/tools/bash_safe_command.mli` -- Full `Safe_command` ADT API
- `lib/tools/bash_policy.mli` -- POLICY interface plus the 3 presets
- `lib/tools/bash_blacklist.mli` -- the 31 blacklist regex rules
