# 工具 API 参考
[English](../sdk/tools.md) · **简体中文**

本文档描述 P-A-R SDK 提供的 20 个内置工具。新增工具通过 `Runtime.register_tool` 注册，工具描述会被注入 LLM 的 system prompt，让 LLM 知道何时调用哪个工具。

**版本**: v0.3.1
**工具总数**: 20（v0.3.0 的 19 个 + v0.3.1 新增的 `bash`）

## 概述

每个工具在注册时携带以下元数据：

```ocaml
type tool_descriptor = {
  name : string;                         (* 工具名，agent 调用时引用 *)
  description : string;                  (* 描述，注入 LLM system prompt *)
  input_schema : Yojson.Safe.t;          (* JSON Schema *)
  permission : tool_permission;          (* Allow / Confirm / Deny / ... *)
  timeout : float option;                (* 秒；None 表示无超时 *)
  concurrency_limit : int option;        (* 最大并发调用数 *)
  on_update : (string -> unit) option;   (* v0.3+ 进度回调 *)
}
```

工具按用途分四类：

| 类别 | 数量 | 工具 |
|------|------|------|
| math | 1 | `calculator` |
| utility | 9 | `get_time` / `echo` / `generate_uuid` / `hash_text` / `generate_password` / `string_stats` / `json_format` / `convert_temperature` / `url_encode` |
| web | 3 | `fetch_url` / `read_webpage` / `web_search` |
| fs (read) | 4 | `read` / `ls` / `find` / `grep` |
| fs (write) | 2 | `write` / `edit` |
| exec | 1 | `bash`（v0.3.1 新增，**唯一带安全策略**） |

除 `bash` 外，所有工具的 `permission = Allow`。文件路径类工具（`read` / `ls` / `find` / `grep` / `write` / `edit`）拒绝绝对路径与含 `:` 的路径。

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
| **`bash`** | **exec** | **高** | **60s** | **v0.3.1 新增，9 维安全机制** |

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
- 路径必须 CWD 相对

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
- `cwd`：CWD 相对路径，默认 `"."`
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
    match Runtime.create ~config:my_config sw with
    | Error _ -> failwith "runtime create failed"
    | Ok rt ->
      (match Runtime.install_bash_tool ~process_mgr:mgr ~clock rt with
       | Ok () -> () (* bash 工具就绪 *)
       | Error e -> Printf.failwithf "bash install failed: %a"
           Yojson.Safe.pp (Types.error_category_to_yojson e))
  ))
```

**幂等**：第二次调用返回 `Error (Invalid_input "bash tool already installed")`。

**必需参数**：
- `process_mgr`：`Eio.Stdenv.process_mgr env`，用于 `Eio.Process.spawn`
- `clock`：`Eio.Stdenv.clock env`，用于 timeout 强制（无 clock 则超时失效）

### 9 维安全机制

| # | 机制 | 实现 |
|---|------|------|
| 1 | CWD 锁定 | `sandboxed_path` 抽象类型，构造时拒绝 `..`、绝对路径、`:` 及 `/etc` `~/.ssh` 等敏感前缀 |
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

## See also

- [`agent.md`](agent.md) -- Agent 定义、Runtime API、工具注册
- [`overview.md`](overview.md) -- SDK 架构概览
- `lib/tools/bash_safe_command.mli` -- Safe_command ADT 完整 API
- `lib/tools/bash_policy.mli` -- POLICY 接口 + 3 预置
- `lib/tools/bash_blacklist.mli` -- 31 条黑名单正则
