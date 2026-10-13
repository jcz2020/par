# 工具 API 参考
[English](https://github.com/jcz2020/par/blob/main/sdk/tools.md) · **简体中文**

本文档描述 P-A-R SDK 提供的 24 个内置工具。新增工具通过 `Runtime.register_tool` 注册，工具描述会被注入 LLM 的 system prompt，让 LLM 知道何时调用哪个工具。

**版本**: v0.7.1
**工具总数**: 24（v0.3.0 的 19 个 + v0.3.1 新增的 `bash` + v0.7.1 新增的 3 个 memory 工具 + v0.11.0 新增的 `apply_patch`）

## 概览

每个工具在注册时携带以下元数据：

```ocaml
type tool_descriptor = {
  name : string;                         (* 工具名，agent 调用时引用 *)
  description : string;                  (* 描述，注入 LLM system prompt *)
  input_schema : Yojson.Safe.t;          (* JSON Schema *)
  output_schema : Yojson.Safe.t option;  (* 可选 JSON Schema，用于结构化输出 *)
  permission : tool_permission;          (* Allow / Confirm / Deny / ... *)
  timeout : float option;                (* 秒；None 表示无超时 *)
  concurrency_limit : int option;        (* 最大并发调用数 *)
  on_update : (string -> unit) option;   (* v0.3+ 进度回调 *)
  cache_control : cache_control option;  (* 可选的 provider 端缓存提示，例如 Anthropic prompt caching *)
}
```

工具按用途分五类：

| 类别 | 数量 | 工具 |
|------|------|------|
| math | 1 | `calculator` |
| utility | 9 | `get_time` / `echo` / `generate_uuid` / `hash_text` / `generate_password` / `string_stats` / `json_format` / `convert_temperature` / `url_encode` |
| web | 3 | `fetch_url` / `read_webpage` / `web_search` |
| fs (read) | 4 | `read` / `ls` / `find` / `grep` |
| fs (write) | 2 | `write` / `edit` |
| patch | 1 | `apply_patch` |
| exec | 1 | `bash`（v0.3.1 新增，**唯一带安全策略**） |
| memory | 3 | `recall_memory` / `remember_memory` / `search_history`（v0.7.1 新增，**需配置 `Memory_service`**） |

除 `bash` 外，所有工具的 `permission = Allow`。文件路径类工具（`read` / `ls` / `find` / `grep` / `write` / `edit`）拒绝绝对路径与含 `:` 的路径。Memory 工具（`recall_memory` / `remember_memory` / `search_history`）需要配置 `Memory_service`，从 `Invoke_context.get_current_exn().session_id` 读取 scope。

## 快速索引

| 工具 | 类别 | 风险 | 超时 | 备注 |
|------|------|------|------|------|
| `calculator` | math | 低 | 5s | `+`/`-`/`*`/`/` 表达式求值 |
| `get_time` | utility | 低 | 2s | 返回 UTC ISO 8601 时间 |
| `echo` | utility | 低 | 2s | 回显输入字符串 |
| `generate_uuid` | utility | 低 | 1s | UUID v4 |
| `hash_text` | utility | 低 | 2s | md5 / sha1 / sha256（默认 sha256） |
| `generate_password` | utility | 低 | 1s | 长度 4-128，符号可选 |
| `string_stats` | utility | 低 | 1s | 字符 / 词 / 行数 |
| `json_format` | utility | 低 | 2s | 校验 + 美化 |
| `convert_temperature` | utility | 低 | 1s | C / F / K 互转 |
| `url_encode` | utility | 低 | 1s | encode / decode |
| `fetch_url` | web | 中 | 15s | HTTP GET，10MB 上限 |
| `read_webpage` | web | 中 | 15s | fetch + HTML 解析，剥离 script/style |
| `web_search` | web | 中 | 15s | DuckDuckGo lite |
| `read` | fs (read) | 低 | 30s | 10MB 上限；二进制返回 base64 |
| `ls` | fs (read) | 低 | 10s | 目录列表，按名排序 |
| `find` | fs (read) | 低 | 30s | glob 模式，跳过 .git / _build 等 |
| `grep` | fs (read) | 低 | 30s | 正则匹配，输出 `path:line:text` |
| `write` | fs (write) | 中 | 30s | 可选 `create_dirs` 自动 mkdir -p |
| `edit` | fs (write) | 中 | 30s | 批量替换；重叠区间被拒 |
| `apply_patch` | patch | 中 | 30s | 原子化 unified diff 应用，跨文件全有或全无 |
| **`bash`** | **exec** | **高** | **60s** | **v0.3.1 新增，9 维安全机制** |
| `recall_memory` | memory | 低 | 10s | 按关键词搜索记忆，按会话分区 |
| `remember_memory` | memory | 低 | 10s | 存储新记忆，按会话分区 |
| `search_history` | memory | 低 | 10s | 搜索跨会话的对话历史 |

---

## math 类

### calculator

评估算术表达式，支持 `+`、`-`、`*`、`/` 和括号。

**输入**：
```json
{ "expression": "2 + 3 * 4" }
```

**输出**（数字，无理数保留为 float）：
```json
14
```

**注意**：实现是手写词法 + 递归下降（不依赖外部 eval 库），只接受数字与四则运算符；空格被忽略但**不支持负数前缀**（`"-1+2"` 解析为 `1 + 2`，需要写为 `"0-1+2"`）。

---

## utility 类

### get_time

返回当前 UTC 时间（ISO 8601 格式）。

**输入**：`{}`（无参数）

**输出**：
```json
"2026-06-04T12:34:56Z"
```

### echo

回显输入文本（用于调试 / agent 间通信）。

**输入**：
```json
{ "text": "hello" }
```

**输出**：
```json
"hello"
```

### generate_uuid

生成随机 UUID v4。

**输入**：`{}`

**输出**：
```json
"550e8400-e29b-41d4-a716-446655440000"
```

### hash_text

对文本计算哈希，支持 `md5` / `sha1` / `sha256`（默认 `sha256`，大小写不敏感）。

**输入**：
```json
{ "text": "hello", "algorithm": "sha1" }
```

**输出**：
```json
{ "hash": "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d", "algorithm": "sha1" }
```

**安全提示**：MD5 / SHA1 已不抗碰撞攻击，仅用于非安全场景（去重、缓存键）。

### generate_password

生成随机密码，长度 4-128（输入范围外自动夹紧），符号默认包含。

**输入**：
```json
{ "length": 24, "include_symbols": true }
```

**输出**：
```json
"a8K!mZ3xQ9wL7nV2"
```

**注意**：使用 `Random.State.make_self_init`，不保证密码学强度。生产场景请用专业库。

### string_stats

统计字符数、词数、行数。词以空格切分。

**输入**：
```json
{ "text": "hello world\nfoo bar" }
```

**输出**：
```json
{ "characters": 22, "words": 4, "lines": 2 }
```

### json_format

校验 + 美化 JSON 字符串。

**输入**：
```json
{ "json": "{\"a\":1,\"b\":2}" }
```

**输出**：
```json
"{\n  \"a\": 1;\n  \"b\": 2\n}"
```

**注意**：解析失败返回 `Error (Invalid_input "Invalid JSON: ...")`，`retryable = false`。

### convert_temperature

C / F / K 互转。

**输入**：
```json
{ "value": 100, "from": "C", "to": "F" }
```

**输出**：
```json
{ "value": 212, "unit": "F", "original_value": 100, "original_unit": "C" }
```

### url_encode

URL 编码或解码。默认 encode；`decode: true` 时反向操作。解码时 `+` 视为空格（form-encoding 兼容）。

**输入**：
```json
{ "text": "hello world", "decode": false }
```

**输出**：
```json
"hello%20world"
```

---

## web 类

三个网络工具共享 `validate_url`（仅允许 `http://` 与 `https://`）+ `max_download_size = 10MB` + 系统 CA 证书 + TLS 主机名校验。

### fetch_url

HTTP GET 原始文本。

**输入**：
```json
{ "url": "https://example.com", "max_length": 50000 }
```

**输出**：
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

fetch + HTML 解析，剥离 `<script>` / `<style>` / `<noscript>`，返回纯文本。

**输入**：
```json
{ "url": "https://example.com", "max_length": 10000 }
```

**输出**：
```json
{
  "url": "https://example.com",
  "title": "Example Domain",
  "text": "...",
  "text_length": 567,
  "truncated": false
}
```

**注意**：依赖 `lambdasoup`。HTTP 4xx / 5xx 返回 `Error (External_failure "HTTP <code>")`；5xx 与 429 标记 `retryable = true`。

### web_search

DuckDuckGo lite 搜索。

**输入**：
```json
{ "query": "ocaml lwt tutorial", "max_results": 5 }
```

**输出**：
```json
{
  "query": "ocaml lwt tutorial",
  "results": [
    { "title": "...", "url": "...", "snippet": "..." }
  ],
  "result_count": 5
}
```

**注意**：抓取 DuckDuckGo lite HTML（无需 API key）。网络或解析失败返回 `Error (External_failure ...)`。

---

## fs (read) 类

四个读类工具拒绝绝对路径与含 `:` 的路径（Windows 盘符防护）。`find` / `grep` 默认跳过 `.git` / `node_modules` / `_build` / `_opam` 目录。

### read

读文件内容，可指定行偏移与行数上限。

**输入**：
```json
{ "path": "src/main.ml", "offset": 0, "limit": 100 }
```

**输出**（带行号，类似 `cat -n`）：
```json
"   1\topen Par\n   2\t...\n"
```

**限制**：
- 文件大小 ≤ 10MB（超过返回 `Error (Invalid_input "File too large")`）
- 路径必须相对于 workspace 根，或为 workspace 根下的绝对路径

### ls

列目录内容。

**输入**：
```json
{ "path": "." }
```

**输出**：
```json
{
  "path": ".",
  "entries": [
    { "name": "src", "type": "dir", "size": null, "modified": 1717... },
    { "name": "README.md", "type": "file", "size": 4321, "modified": 1717... }
  ]
}
```

**注意**：子项按文件名升序；`type` 是 `dir` / `file` / `link` / `other` / `unknown`；非目录路径返回 `Error (Invalid_input "Not a directory")`。

### find

glob 匹配文件名（`**` 跨目录，`*` 跨组件但不含 `/`）。

**输入**：
```json
{ "pattern": "**/*.ml", "path": "." }
```

**输出**：
```json
["src/main.ml", "src/agent.ml", "test/test.ml"]
```

### grep

正则搜索文件内容。`path` 目录下递归匹配，`glob` 过滤文件名。

**输入**：
```json
{ "pattern": "TODO", "path": "lib", "glob": "*.ml", "context_lines": 2 }
```

**输出**（每条 `path:line:match`）：
```json
["lib/runtime.ml:142:(* TODO: handle ... *)"]
```

**注意**：正则语法为 OCaml `Str`（POSIX 扩展正则）。当前实现忽略 `context_lines`（保留参数供未来扩展）。

---

## fs (write) 类

### write

写文件，可选 `create_dirs` 自动 `mkdir -p`。

**输入**：
```json
{ "path": "out/result.txt", "content": "hello", "create_dirs": true }
```

**输出**：
```json
"Wrote 5 bytes to out/result.txt"
```

**注意**：覆盖已存在文件；目录不存在时若 `create_dirs` 为 `false` 则报错。

### edit

批量精确字符串替换。**重叠区间被拒**（避免编辑顺序歧义）。

**输入**：
```json
{
  "path": "src/main.ml",
  "edits": [
    { "old": "let x = 1", "new": "let x = 2" },
    { "old": "foo", "new": "bar" }
  ]
}
```

**输出**：
```json
"Applied 2 edit(s) to src/main.ml"
```

**注意**：
- 每个 `old` 必须是文件的**精确子串**（包含空格、换行、缩进）
- 使用 `Str.replace_first`，不修改 `old` 之后可能出现的同名串
- 重叠检测：若两个 `old` 区间在文件中有交叠，工具拒绝并返回 `Error (Invalid_input "Overlapping edits")`

---

## patch 类（v0.11.0 新增）

### apply_patch

将标准 unified diff 原子化地应用到 workspace 文件。补丁中的所有文件要么全部成功，要么全部不修改。适用于 LLM 生成多文件变更集的场景，避免 `edit` 逐文件调用导致的部分应用状态。

**输入**：
```json
{
  "patch": "--- a/src/main.ml\n+++ b/src/main.ml\n@@ -1,5 +1,5 @@\n open Par\n-let x = 1\n+let x = 2\n",
  "dry_run": false
}
```

字段说明：
- `patch`（必需）：标准 unified diff 字符串。支持多文件补丁。使用 `--- a/path` / `+++ b/path` 头。遵循 `git apply` 约定：上下文偏移匹配容忍小幅偏移。
- `dry_run`（可选，默认 `false`）：为 `true` 时只验证补丁并报告会发生的变更，不写入任何文件。

**输出**（成功时）：
```json
{
  "files_changed": 1,
  "files": [
    { "path": "src/main.ml", "status": "applied", "insertions": 1, "deletions": 1 }
  ]
}
```

**Dry-run 输出**：
```json
{
  "files_changed": 1,
  "dry_run": true,
  "files": [
    { "path": "src/main.ml", "status": "would_apply", "insertions": 1, "deletions": 1 }
  ]
}
```

**文件创建与删除**：旧文件为 `/dev/null` 的 diff 创建新文件。新文件为 `/dev/null` 的 diff 删除已有文件。二进制文件会被检测并跳过并附带警告，不会被静默损坏。

**原子化保证**：工具在写入任何文件前先验证补丁中的所有文件。如果任何 hunk 应用失败（reject），不会写入任何文件，工具返回包含完整拒绝列表的错误。这防止了导致 workspace 不一致的部分应用。

**已知限制**：写入过程中的崩溃或进程终止可能导致单个文件处于部分写入状态。原子化保证覆盖逻辑补丁（跨文件全有或全无），而非单个文件写入的崩溃安全性。对于需要崩溃恢复的工作流，建议配合版本控制系统使用。

**并发语义**：对同一文件的重叠补丁遵循最后写入者胜出（last-writer-wins），与 `write` 和 `edit` 的约定相同。

**错误信息**：补丁拒绝使用 `[patch]` 标记前缀：

```
[patch] Hunk #1 at line 15 failed: context does not match.
File: src/main.ml. The patch may have been generated against a different revision.
Read the file first, then regenerate the patch against the current content.
```

路径拒绝（workspace 外的绝对路径、路径遍历等）复用标准的 `[workspace]` 标记。

**何时优先于 `edit` / `write`**：
- 多文件变更集，部分应用不可接受
- 由 `git diff` 或 `git format-patch` 生成的补丁
- LLM 产出 unified diff 而非显式 old/new 对的场景

---

## bash（v0.3.1 新增）

LLM 调用 shell 是**最危险的内置工具**。v0.3.0 故意没做 bash，等 v0.3.1 单独设计。**核心理念**：从"裸 shell string + 黑名单"升级为"**类型化 Safe_command ADT + Policy Functor + 黑名单**"，把安全检查从运行时前移到编译期。

### 用途

执行 shell 命令，配合三层防御：

1. **类型层**：`argv` 强制为 `string list`，**没有 `Exec_raw_shell` 构造器**（shell 注入在类型层不可表示）
2. **策略层**：`POLICY.filter` 在运行时校验，可基于用户场景选择 `Coder` / `ReadOnly` / `ReadOnlyNoNet`
3. **黑名单层**：`Bash_blacklist` 31 条正则兜底（`rm -rf /`、`dd of=/dev/sda`、fork bomb 等）

### 输入

```json
{
  "argv": ["ls", "-la"],
  "cwd": "src",
  "timeout": 30
}
```

字段说明：
- `argv`（必需）：参数数组，**不是 shell 字符串**
- `cwd`：工作目录（相对于 workspace 根，或 workspace 根下的绝对路径）。默认：`"."`
- `timeout`：最大执行秒数，默认 `30`，硬上限 `600`

### 输出

```json
{
  "stdout": "...",
  "stderr": "...",
  "exit_code": 0,
  "duration": 0.123,
  "truncated": false
}
```

`truncated: true` 表示输出被 50KB / 2000 行截断（marker 追加在末尾）。

### 三个预置策略

| 策略 | 网络 | 写操作 | 用途 |
|------|------|--------|------|
| `Coder`（默认） | ✅ | ✅ | "AI 写代码"，只拦截黑名单命中 |
| `ReadOnly` | ✅ | ❌ | 纯只读工具（`ls` / `cat` / `find` / `grep`） |
| `ReadOnlyNoNet` | ❌ | ❌ | 最大安全（敏感代码库 review 场景） |

### 自定义策略

实现 `Bash_policy.POLICY` 模块类型并传给 `Runtime.create`：

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
    (* 你的额外检查：黑名单、白名单、argv 限制... *)
    Ok cmd
end

(* Runtime.create ~bash_policy:(module MyStrictPolicy) *)
```

### 安装

bash 工具**不**随 `Runtime.create` 自动注册。需要在 `Runtime.create` 之后调用 `install_bash_tool`：

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
       | Ok () -> () (* bash 工具就绪 *)
       | Error e -> Printf.failwithf "bash install failed: %a"
           Yojson.Safe.pp (Types.error_category_to_yojson e))
  ))
```

**幂等**：第二次调用返回 `Error (Invalid_input "bash tool already installed")`。

**必需参数**：
- `process_mgr`：`Eio.Stdenv.process_mgr env`，用于 `Eio.Process.spawn`
- `clock`：`Eio.Stdenv.clock env`，用于 timeout 强制（无 clock 则超时失效）
- `fs`：`Eio.Stdenv.fs env`，文件系统 capability，用于设置子进程的 cwd。不传则 bash 命令在 PAR 进程的 cwd 运行，workspace 沙箱失效。

### 9 维安全机制

| # | 机制 | 实现 |
|---|------|------|
| 1 | Workspace 锁定 | `Workspace.sandboxed_path` 抽象类型，构造时拒绝 `..`、`:` 及敏感前缀（`/etc`、`~/.ssh` 等），**workspace 根下的绝对路径被放行** |
| 2 | 黑名单 | `Bash_blacklist` 31 条正则（`rm -rf /`、`dd of=/dev/sda`、`:(){:|:&};:` 等） |
| 3 | 白名单（可选） | 自定义 `POLICY` 实现白名单逻辑 |
| 4 | 超时 | `Eio.Process.spawn` + `Eio.Fiber.first` race；硬上限 600s |
| 5 | 进程组清理 | `Eio.Process` + `setpgid`；超时通过 `killpg` 杀整组 |
| 6 | 环境脱敏 | `Bash_policy.sanitize_env` 剥离 `*_SECRET*` / `*_KEY*` / `AWS_*` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `GITHUB_TOKEN` 等 |
| 7 | 输出截断 | 50KB 字节 + 2000 行；marker 追加 |
| 8 | ANSI 剥离 | 移除 CSI（`ESC[...]`）与 OSC（`ESC]...BEL`）序列 |
| 9 | 审计日志 | event bus 发送 `Bash_invoked` / `Bash_completed` 事件（携带 `risk` 评分与 `argv`） |

### 安全建议

- 默认 `Coder` 是"AI 写代码"场景的正确选择（与 pi 默认行为接近）
- 只想让 LLM 检视（code review 场景）用 `ReadOnly`
- 敏感代码库用 `ReadOnlyNoNet`
- **永远不要禁用 timeout**，它是 fork bomb 与网络挂起的最后防线
- 环境变量自动脱敏。如需传 secret，写到文件后用 `read` 工具读取（不在 `env` 字段里传）
- 黑名单是**最后一道**防线，不是主防御。安全关键场景请在自定义 `POLICY` 里设 `allow_write:false` + `allow_network:false`
- **OS 层沙箱**（bwrap / landlock）v0.3.1 不提供

### 风险评分

`Bash_safe_command.assess_risk` 返回 `Low` / `Medium` / `High` / `Critical`，挂在 `Bash_invoked` 事件的 `risk` 字段上。

---

## memory 类（v0.7.1 新增）

三个 memory 工具需要配置 `Memory_service`。当 `Runtime.create` 接收 `?memory` 参数时自动注册。所有工具从 `Invoke_context.get_current_exn().session_id` 读取 scope，记忆自动按会话隔离。

### recall_memory

按关键词查询搜索已存储的记忆。使用 FTS5 全文搜索和 BM25 排序。

**输入**：
```json
{ "query": "ocaml concurrency", "limit": 5 }
```

**输出**：
```json
{
  "results": [
    { "id": "...", "content": "...", "summary": "...", "scope": "...", "categories": [...], "created_at": 1717... }
  ],
  "count": 2
}
```

**注意**：`limit` 默认 5，上限 50。`scope` 从当前 `invoke_context.session_id` 读取。

### remember_memory

存储新记忆以供将来检索。记忆按当前会话分区。

**输入**：
```json
{ "content": "项目使用 OCaml 5.4 和 Eio 实现并发", "summary": "OCaml 并发技术栈", "categories": ["架构", "技术选型"] }
```

**输出**（创建的 `memory_object`）：
```json
{ "id": "550e8400-...", "content": "...", "summary": "...", "scope": "...", "categories": ["架构", "技术选型"], "created_at": 1717... }
```

**参数**：
- `content`（必需）：要记住的完整文本
- `summary`（可选）：简短摘要，被 FTS5 索引
- `categories`（可选）：分类标签

### search_history

搜索最近会话的对话历史。对消息文本执行大小写不敏感的子串匹配。

**输入**：
```json
{ "query": "Eio concurrency", "limit": 10 }
```

**输出**：
```json
{
  "results": [
    { "session_id": "...", "role": "user", "content": "跟我说说 Eio..." }
  ],
  "count": 3
}
```

**注意**：`limit` 控制搜索的会话数（默认 10，上限 50）。匹配文本截断到 500 字符。当前会话优先搜索。

---

## 渐进式工具加载（v0.11.0 新增）

注册 50+ 工具后，工具的 JSON schema 会主导 prompt 体积。每次调用都要为完整 schema 买单，无论模型是否真的需要其中大部分工具。渐进式工具加载用一次往返换取更小的可见工具集：模型按需搜索隐藏工具，只拉取当前需要的那些。

**配置**：在 `runtime_config` 上设置 `max_tool_schema_tokens`（类型 `int option`，默认 `None`）。注册 50+ 工具时推荐起始值：`2000`。

**自动切换语义**：每次调用时，engine 估算可见工具描述列表的 token 开销（chars/4 启发式，经由 `Tool_budget.estimate_tokens`，是文档声明的估算值而非精确 tokenizer）。估算值超过阈值时，该次调用切换到渐进模式：只有 Always 层的 builtin/core 工具加上 `tool_search` 元工具暴露给 LLM。被推迟的工具保持隐藏，但可以通过搜索触达。

**Always 层地板**：registry 内部把工具分为 `Always | Searchable` 两层。Always 层是保底地板，永不裁剪。如果仅地板自身就超过阈值，会记录警告日志，且地板仍然全量发送。通过现有 pull 模型注册的 MCP 工具一旦注册即为可搜索。

**tool_search 用法**：

输入：
```json
{ "query": "temperature convert", "category": "utility" }
```

输出示意（命中的工具携带完整 JSON schema）：
```json
{
  "results": [
    { "name": "convert_temperature", "description": "C / F / K conversion", "input_schema": { "type": "object", "...": "..." } }
  ],
  "count": 1
}
```

评分为关键词匹配：名称命中的权重高于描述命中。

**按调用提升**：搜索之后，命中的工具只在当前调用内被提升（per-call shadow list）。模型可以在同一调用的后续轮次直接调用它们。提升不跨调用持久化。从未暴露或提升的工具完全无法调用；模型编造的工具名会以 unknown-tool 错误失败，永远不会 dispatch。

**指标**：渐进模式下，metrics 快照现在暴露 `tool_schema_tokens_estimate` 以及可见 / 推迟工具数。

**默认无行为变化**：不设置 `max_tool_schema_tokens`（保持 `None`）时行为与现状完全一致。该功能完全 opt-in。

---

## 注册自定义工具

工具是简单的 `{ descriptor; handler }` 二元组。`Runtime.register_tool` 是便利函数；底层可通过 `Tool_registry.register` 直接注册：

```ocaml
let my_tool = { descriptor; handler } in
Tool_registry.register rt.tool_registry descriptor handler
```

完整示例（含 `tool_descriptor` 字段说明）见 [`agent.md`](agent.md)。

## 安全审计清单

新工具提交前自检：

- [ ] `permission` 字段已设置（`Allow` / `Confirm` / `Deny` / `Role_based` / `Condition_based`）
- [ ] 长时间运行工具设置了 `timeout`
- [ ] 资源受限工具设置了 `concurrency_limit`
- [ ] 网络 / 写类工具通过 event bus 输出审计日志
- [ ] 文件路径类工具拒绝绝对路径与 `:` 路径
- [ ] 危险工具走 `Bash_policy`（如适用）
- [ ] `description` 包含 input 示例（让 LLM 知道怎么调用）

## 可行动的校验错误

PAR 中的工具拒绝不只是说"已拒绝"。它们解释*出了什么问题*以及*如何修复*。这是设计原则：错误信息是模型在 ReAct 循环中唯一的反馈信号。把规则写在 system prompt 里导致模型拒绝尝试工作；在拒绝点教学让模型学会正确重试。

### 标记词汇

三种标记前缀出现在工具错误信息中。工具描述引用相同的常量，因此描述和拒绝消息不会产生偏差（两者均来源于 `lib/tools/tool_error.ml`）。

| 标记 | 含义 |
|------|------|
| `[workspace]` | 路径校验失败（workspace 沙箱拒绝） |
| `[bash-policy]` | Bash 命令被策略拒绝（`Coder` / `ReadOnly` / 自定义） |
| `[patch]` | 补丁 hunk 拒绝（上下文不匹配、diff 损坏或二进制文件） |
| `[cancelled]` | 工具调用因运行被取消而中止 |

### Workspace 路径拒绝

所有文件工具（`read` / `ls` / `find` / `grep` / `write` / `edit`）共享相同的路径校验。存在四种不同的拒绝类型，每种都有特定的消息和元数据代码：

**路径遍历**（代码 `workspace_parent_traversal`）：
```
[workspace] Path rejected: '../etc/passwd' contains '..' (path traversal is not allowed).
Use a clean relative path like 'src/main.ml', or an absolute path under the workspace root.
```

**路径中含冒号**（代码 `workspace_colon`）：
```
[workspace] Path rejected: 'C:\Users' contains ':' (reserved/ambiguous in tool arguments).
Use a path without ':'.
```

**绝对路径在 workspace 外**（代码 `workspace_absolute_outside`）：
```
[workspace] Path rejected: '/etc/passwd' is an absolute path outside the workspace (2 root(s)).
Use a relative path like 'src/main.ml' (resolved against the workspace root)
or an absolute path under a workspace root.
```

注意根数量：消息告诉模型有多少个 workspace 根，以便它推理哪些绝对路径是允许的。

**受保护位置**（代码 `workspace_protected_location`）：
```
[workspace] Path rejected: '~/.ssh/id_rsa' matches a protected location.
Choose a path outside protected system areas.
```

两个额外的元数据代码用于缺失参数：

| 代码 | 场景 |
|------|------|
| `workspace_path_required` | 缺少必需的 `path` 参数 |
| `pattern_required` | 缺少必需的 `pattern` 参数（用于 `find` / `grep`） |

### Bash 策略拒绝

当 bash 工具的策略过滤器拒绝命令时，错误会指出策略和命令：

```
[bash-policy] Command rejected by ReadOnly policy: ["rm", "-rf", "node_modules"].
This policy does not allow write operations. Use a read-only command or switch to a different policy.
```

标记 `[bash-policy]` 与 bash 工具描述教给模型的内容一致，因此模型知道这是策略约束，而非 bug。

### Edit 工具：old_text 未找到

此前，`edit` 工具在 `old_text` 未在文件中找到时静默成功。这是最严重的缺陷类别：模型以为它做了更改，但什么都没发生。现在返回错误：

```
Edit failed: old_text was not found in 'src/main.ml'. The file may have changed
since it was last read, or the text does not match exactly (including whitespace).
Read the file first, then retry with the exact current text.
```

元数据代码：`edit_old_text_not_found`。

### 元数据代码参考

| 代码 | 工具 | 含义 |
|------|------|------|
| `workspace_parent_traversal` | read/ls/find/grep/write/edit | 路径包含 `..` |
| `workspace_colon` | read/ls/find/grep/write/edit | 路径包含 `:` |
| `workspace_absolute_outside` | read/ls/find/grep/write/edit | 绝对路径在 workspace 根外 |
| `workspace_protected_location` | read/ls/find/grep/write/edit | 路径匹配受保护的系统区域 |
| `workspace_path_required` | read/ls/find/grep/write/edit | 缺少必需的 path 参数 |
| `pattern_required` | find/grep | 缺少必需的 pattern 参数 |
| `edit_old_text_not_found` | edit | 在文件中未找到 `old_text` 子串 |
| `patch_hunk_reject` | apply_patch | Hunk 上下文与文件内容不匹配 |
| `patch_binary_skipped` | apply_patch | 检测到二进制文件并跳过 |

### 设计原则：在拒绝点教学

标记和指导性消息的存在是因为错误信息是模型在 ReAct 循环中*唯一*接收的反馈信号。System prompt 规则（"永远不要使用绝对路径"）导致模型完全拒绝尝试。相比之下，像 `[workspace] Path rejected: '/tmp/out.txt' is an absolute path outside the workspace (1 root(s)). Use a relative path like 'src/main.ml' ...` 这样的拒绝给了模型足够的上下文来用正确形式重试。

`lib/tools/tool_error.ml` 中的常量是唯一的真实来源：工具描述 TEACH 标记，工具处理器 EMIT 标记。两者引用相同的常量，因此不会产生偏差。

## 另请参阅

- [`agent.md`](agent.md) -- Agent 定义、Runtime API、工具注册
- [`overview.md`](overview.md) -- SDK 架构概览
- `lib/tools/bash_safe_command.mli` -- Safe_command ADT 完整 API
- `lib/tools/bash_policy.mli` -- POLICY 接口 + 3 预置
- `lib/tools/bash_blacklist.mli` -- 31 条黑名单正则
