<!-- language: en -->

**English** · [简体中文](../zh-CN/sdk/tools.md)

> Translated to English for v0.3.2. Source-of-truth: the OCaml modules in lib/tools/.

# Tool API Reference

This document describes the 20 built-in tools provided by the P-A-R SDK. New tools are registered through `Runtime.register_tool`; the tool description gets injected into the LLM's system prompt so the model knows when to call which tool.

**Version**: v0.3.1
**Total tools**: 20 (19 from v0.3.0 plus `bash` added in v0.3.1)

## Overview

Each tool carries the following metadata at registration time:

```ocaml
type tool_descriptor = {
  name : string;                         (* tool name, referenced by the agent call *)
  description : string;                  (* description, injected into the LLM system prompt *)
  input_schema : Yojson.Safe.t;          (* JSON Schema *)
  permission : tool_permission;          (* Allow / Confirm / Deny / ... *)
  timeout : float option;                (* seconds; None means no timeout *)
  concurrency_limit : int option;        (* max concurrent invocations *)
  on_update : (string -> unit) option;   (* v0.3+ progress callback *)
}
```

The tools fall into four categories by purpose:

| Category | Count | Tools |
|------|------|------|
| math | 1 | `calculator` |
| utility | 9 | `get_time` / `echo` / `generate_uuid` / `hash_text` / `generate_password` / `string_stats` / `json_format` / `convert_temperature` / `url_encode` |
| web | 3 | `fetch_url` / `read_webpage` / `web_search` |
| fs (read) | 4 | `read` / `ls` / `find` / `grep` |
| fs (write) | 2 | `write` / `edit` |
| exec | 1 | `bash` (added in v0.3.1, **the only one with a security policy**) |

All tools except `bash` use `permission = Allow`. The file-path tools (`read` / `ls` / `find` / `grep` / `write` / `edit`) reject absolute paths and any path containing `:`.

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
| **`bash`** | **exec** | **high** | **60s** | **added in v0.3.1, 9-layer safety mechanism** |

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
- Path must be CWD-relative

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
- `cwd`: CWD-relative path, default `"."`
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
    match Runtime.create ~config:my_config sw with
    | Error _ -> failwith "runtime create failed"
    | Ok rt ->
      (match Runtime.install_bash_tool ~process_mgr:mgr ~clock rt with
       | Ok () -> () (* bash tool is ready *)
       | Error e -> Printf.failwithf "bash install failed: %a"
           Yojson.Safe.pp (Types.error_category_to_yojson e))
  ))
```

**Idempotent**: a second call returns `Error (Invalid_input "bash tool already installed")`.

**Required parameters**:
- `process_mgr`: `Eio.Stdenv.process_mgr env`, used for `Eio.Process.spawn`
- `clock`: `Eio.Stdenv.clock env`, used to enforce the timeout (without a clock, timeouts do nothing)

### The 9-layer safety mechanism

| # | Mechanism | Implementation |
|---|------|------|
| 1 | CWD lockdown | `sandboxed_path` abstract type; the constructor rejects `..`, absolute paths, `:`, and sensitive prefixes like `/etc` and `~/.ssh` |
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

## See also

- [`agent.md`](agent.md) -- Agent definitions, Runtime API, tool registration
- [`overview.md`](overview.md) -- SDK architecture overview
- `lib/tools/bash_safe_command.mli` -- Full `Safe_command` ADT API
- `lib/tools/bash_policy.mli` -- POLICY interface plus the 3 presets
- `lib/tools/bash_blacklist.mli` -- the 31 blacklist regex rules
