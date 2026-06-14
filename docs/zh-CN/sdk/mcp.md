# MCP 客户端 API 参考
[English](../sdk/mcp.md) · **简体中文**

本文档描述 P-A-R SDK 的 MCP（Model Context Protocol）stdio 客户端。PAR agent 可以连接到任意 MCP server（filesystem、git、sqlite、github 等），直接消费它们暴露的 tools、resources 和 prompts。

**版本**: v0.3.1
**传输层**: stdio

## 概述

MCP 是 Anthropic 提出的 LLM 工具集成协议，server 端把工具（tools）、数据资源（resources）、提示词模板（prompts）以 JSON-RPC 2.0 形式暴露在 stdio 上。PAR v0.3.1 实现 client 侧，让 PAR agent 可以透明地调用任何符合 MCP 规范的 server。

为什么先做 stdio：本地进程通信是零网络依赖、零配置 TLS、零反代负担的方案，覆盖 90% 现有 MCP server 场景。

### 三个公开模块

`open Par` 后可用：

| 模块 | 职责 |
|------|------|
| `Par.Mcp_types` | 协议类型：配置、能力、tool/resource/prompt 记录、JSON-RPC 类型 |
| `Par.Mcp_server` | 低阶 server 生命周期：spawn、stop、call_method、notify |
| `Par.Mcp_client` | 高阶 typed API：connect、list_tools、call_tool、read_resource、get_prompt |

绝大多数用户只需要 `Mcp_client`；`Mcp_server` 用于需要手动管理生命周期的场景（如动态增删 server）。

### v0.3.1 范围

| 能力 | 状态 |
|------|------|
| stdio transport | ✅ |
| initialize / initialized 握手 | ✅ |
| tools/list, tools/call | ✅ |
| resources/list, resources/read | ✅ |
| prompts/list, prompts/get | ✅ |
| ping | ✅ |
| notifications（list_changed、progress、cancelled） | ✅ |
| 启动策略：fail-fast / log-and-continue | ✅ |
| 优雅 shutdown（SIGTERM → SIGKILL 降级） | ✅ |
| HTTP / SSE transport | 未实现 |
| sampling（server → LLM 反向调用） | 未实现 |
| roots / elicitation | 未实现 |

---

## 快速开始

最小例子：连接 `npx`-style 的 MCP filesystem server。

```ocaml
open Par

let config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
}

let mcp_fs_config : Mcp_types.server_config = {
  name = "fs";
  command = "npx";
  args = [ "-y"; "@modelcontextprotocol/server-filesystem"; "/tmp" ];
  env = [];
  cwd = None;
  startup_timeout = 10.0;
}

let () = Eio_main.run (fun env ->
  Eio.Switch.run (fun sw ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clock = Eio.Stdenv.clock env in
    match
      Runtime.create
        ~mcp_servers:[mcp_fs_config]
        ~mcp_process_mgr:mgr
        ~mcp_clock:clock
        ~config sw
    with
    | Error e ->
      Printf.eprintf "Runtime create failed: %a\n"
        Yojson.Safe.pp (Types.error_category_to_yojson e)
    | Ok rt ->
      (* 通过 server_id 取出 client 句柄 *)
      (match Runtime.mcp_server rt (Mcp_types.server_id_of_string "fs" |> Result.get_ok) with
       | Error _ -> Printf.eprintf "Server not found\n"
       | Ok _client -> ());
      ignore (Runtime.close rt)
  )
)
```

`Runtime.create` 在内部为每个配置 spawn 子进程、执行 initialize 握手，等所有 server 都进入 `Ready` 状态后才返回 `Ok rt`（fail-fast 策略下）。

---

## Runtime 集成

### 创建参数

```ocaml
val Runtime.create :
  ?persistence:persistence_service ->
  ?event_bus:Types.event_bus_service ->
  ?llm:llm_service ->
  ?bash_policy:(module Bash_policy.POLICY) ->
  ?mcp_servers:Mcp_types.server_config list ->
  ?mcp_process_mgr:_ Eio.Process.mgr ->
  ?mcp_clock:_ Eio.Time.clock ->
  ?mcp_startup_policy:Mcp_types.startup_policy ->
  config:runtime_config ->
  Eio.Switch.t ->
  (runtime, error_category) result
```

MCP 相关参数：

| 参数 | 类型 | 默认 | 必填条件 |
|------|------|------|----------|
| `?mcp_servers` | `server_config list` | `[]` | 否 |
| `?mcp_process_mgr` | `Eio.Process.mgr` | 无 | `mcp_servers` 非空时必填 |
| `?mcp_clock` | `Eio.Time.clock` | 无 | `mcp_servers` 非空时必填 |
| `?mcp_startup_policy` | `startup_policy` | `Fail_fast` | 否 |

习惯写法：从 Eio 环境一次性取出。

```ocaml
Eio_main.run (fun env ->
  Eio.Switch.run (fun sw ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clock = Eio.Stdenv.clock env in
    let rt = Runtime.create
      ~mcp_servers:[fs_cfg; git_cfg]
      ~mcp_process_mgr:mgr
      ~mcp_clock:clock
      ~mcp_startup_policy:Mcp_types.Log_and_continue
      ~config sw
      |> Result.get_ok
    in
    ...
  )
)
```

### 启动策略

```ocaml
type startup_policy =
  | Fail_fast          (* 任何一个 server 启动失败，立即返回 Error *)
  | Log_and_continue   (* 失败的 server 记入 event bus，其余继续运行 *)
```

- **`Fail_fast`**（默认）：适合生产环境，所有 server 都必须可用。
- **`Log_and_continue`**：适合开发环境或可选能力（如 linter server），通过 `Mcp_server_failed` 事件感知。

### 关闭

`Runtime.close` 是总开关：先关闭所有 MCP server，再关闭 event bus 和持久化层。每个 server 关闭时各发一条 `Mcp_server_stopped` 事件。

```ocaml
let _exit_code = Runtime.close rt
```

无需手动调用 `Mcp_client.disconnect` 或 `Mcp_server.stop`，`Runtime.close` 会负责所有派生资源。

### 访问 server 表

```ocaml
`Runtime.mcp_servers` 返回当前 runtime 持有的 server 集合（`server_id → server` 映射）。`Runtime.mcp_server` 按 id 查找单个 server。

`server_id` 来源：默认用 `server_config.name` 字段。如果重名，自动加后缀（`-1`、`-2`），由 `server_id_with_suffix` 实现。`server_id_compare` 用于排序。

```ocaml
(* 按 id 查找 *)
let sid = Mcp_types.server_id_of_string "fs" |> Result.get_ok in
match Runtime.mcp_server rt sid with
| Ok srv -> Mcp_server.status srv
| Error _ -> ...
```

---

## Mcp_client API

高阶 typed API。大多数场景下用 `Mcp_client`，比直接操作 `Mcp_server` 简单：解析 JSON、提取 `result` 字段这些都被隐藏掉。

### 类型

```ocaml
type t  (* 包装了一个 ready 的 Mcp_server.t *)
```

### 连接与关闭

```ocaml
val connect :
  sw:Eio.Switch.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  Mcp_types.server_config ->
  (t, error_category) result

val disconnect : t -> (unit, error_category) result
```

`connect` 等价于 `Mcp_server.spawn` + 客户端包装。`disconnect` 委托给 `Mcp_server.stop`，幂等。

### 访问器

```ocaml
val id           : t -> Mcp_types.server_id
val name         : t -> string
val capabilities : t -> Mcp_types.capabilities
val status       : t -> Mcp_server.status
```

`status` 返回 `Starting | Ready of capabilities | Failed of error | Stopped`。正常运行时总是 `Ready`。

### Tools

```ocaml
val list_tools : t -> (Mcp_types.mcp_tool list, error_category) result
val call_tool  : t -> name:string -> arguments:Yojson.Safe.t ->
                 (Yojson.Safe.t, error_category) result
```

`list_tools` 返回 server 端注册的所有工具元数据。`call_tool` 的 `arguments` 是 server 工具要求的 JSON 输入；返回的也是原始 JSON，由调用方按 `input_schema` 解析。

```ocaml
let print_tools (client : Mcp_client.t) =
  match Mcp_client.list_tools client with
  | Error e ->
    Printf.eprintf "list_tools failed: %a\n"
      Yojson.Safe.pp (Types.error_category_to_yojson e)
  | Ok tools ->
    List.iter (fun t ->
      Printf.printf "- %s : %s\n"
        t.Mcp_types.name
        (Option.value t.Mcp_types.description ~default:""))
      tools

(* 调用 *)
let args = `Assoc [ ("path", `String "/tmp/hello.txt") ] in
match Mcp_client.call_tool client ~name:"read_file" ~arguments:args with
| Ok result -> print_endline (Yojson.Safe.to_string result)
| Error e -> ...
```

### Resources

```ocaml
val list_resources : t -> (Mcp_types.mcp_resource list, error_category) result
val read_resource  : t -> uri:string -> (Yojson.Safe.t, error_category) result
```

`read_resource` 接收 MCP 风格的 URI（`file://...`、`git://...` 等），由 server 解析。

```ocaml
match Mcp_client.list_resources client with
| Ok resources ->
  List.iter (fun r ->
    Printf.printf "  %s (%s)\n" r.uri
      (Option.value r.mime_type ~default:"?"))
    resources
| Error _ -> ()

(* 读一个 resource *)
match Mcp_client.read_resource client ~uri:"file:///tmp/x.txt" with
| Ok body -> print_endline (Yojson.Safe.to_string body)
| Error _ -> ()
```

### Prompts

```ocaml
val list_prompts : t -> (Mcp_types.mcp_prompt list, error_category) result
val get_prompt  : t -> name:string -> ?arguments:(string * string) list -> unit ->
                  (Yojson.Safe.t, error_category) result
```

`get_prompt` 返回 server 渲染好的 prompt messages（JSON 数组形式）。`?arguments` 是命名参数；缺省时使用 server 端默认值。

```ocaml
match Mcp_client.get_prompt client
        ~name:"commit_message"
        ~arguments:[("diff", "..."); ("style", "concise")] () with
| Ok rendered ->
  (* 通常是 messages 数组 *)
  print_endline (Yojson.Safe.pretty_to_string rendered)
| Error _ -> ()
```

### 工具

```ocaml
val ping : t -> (Yojson.Safe.t, error_category) result
```

健康检查。返回 server 端的 `pong` 响应。

---

## Mcp_server 低阶 API

适用于需要手动控制生命周期的场景：动态增删 server、自定义 RPC 方法、注入额外通知。

### 状态

```ocaml
type status =
  | Starting
  | Ready of Mcp_types.capabilities
  | Failed of Types.error_category
  | Stopped
```

### Spawn

```ocaml
val spawn :
  sw:Eio.Switch.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  Mcp_types.server_config ->
  (t, Types.error_category) result
```

- `sw`：父 switch；子进程生命周期绑定到它。
- `process_mgr`：用于 `Eio.Process.spawn`。
- `clock`：用于 `startup_timeout` 强制。
- `config`：见下方配置参考。

成功 spawn 后已自动完成 initialize 握手，状态为 `Ready caps`。

### 访问器

```ocaml
val id           : t -> Mcp_types.server_id
val name         : t -> string
val pid          : t -> int
val capabilities : t -> Mcp_types.capabilities
val status       : t -> status
```

`pid` 是子进程 PID（POSIX），便于运维关联 `ps` 输出。

### 通用 RPC

```ocaml
val call_method :
  t -> method_:string -> params:Yojson.Safe.t ->
  (Yojson.Safe.t, Types.error_category) result

val notify :
  t -> method_:string -> params:Yojson.Safe.t ->
  (unit, Types.error_category) result
```

`call_method` 发送 JSON-RPC request 并阻塞等响应；`notify` 发送 notification（无 id，server 不回应）。

大多数场景应使用 `Mcp_client` 的 typed 方法。`call_method` 留给以下场景：

- 调用 MCP 规范中存在但 `Mcp_client` 未覆盖的方法（如自定义扩展）
- 实现 MCP 协议新版本时的早期实验

### 关闭

```ocaml
val stop : t -> (unit, Types.error_category) result
```

停止时序：先发 `shutdown` request，等 2 秒优雅退出，未退出发 SIGTERM（`killpg` 进程组），再等 2 秒仍未退出发 SIGKILL。幂等；多次调用安全。

`Runtime.close` 会在内部为每个 server 调用一次 `stop`。

---

## 事件类型

7 个新事件，加入 `Par.Types.event` 变体。所有事件都从 event bus 流出，可用 `Runtime.subscribe` 监听。

| 事件 | 触发时机 | 关键字段 |
|------|----------|----------|
| `Mcp_server_started` | server initialize 成功 | `server_id`, `server_name` |
| `Mcp_server_failed` | spawn 失败 / 握手失败 / 进程崩溃 | `server_id`, `error` |
| `Mcp_server_stopped` | `Runtime.close` 或显式 `disconnect` 完成 | `server_id` |
| `Mcp_tool_invoked` | `call_tool` 入口 | `server_id`, `tool_name` |
| `Mcp_tool_completed` | `call_tool` 出口 | `server_id`, `tool_name`, `duration_ms` |
| `Mcp_resource_read` | `read_resource` 成功 | `server_id`, `uri` |
| `Mcp_prompt_rendered` | `get_prompt` 成功 | `server_id`, `prompt_name` |

### 订阅示例

```ocaml
open Par

let log_mcp_event (ev : Types.event) =
  match ev with
  | Mcp_server_started { server_id; server_name } ->
    Printf.printf "[mcp] started %s (%s)\n" server_id server_name
  | Mcp_server_failed { server_id; error } ->
    Printf.eprintf "[mcp] failed %s: %a\n"
      server_id Yojson.Safe.pp (Types.error_category_to_yojson error)
  | Mcp_tool_invoked { server_id; tool_name } ->
    Printf.printf "[mcp] call %s/%s\n" server_id tool_name
  | Mcp_tool_completed { server_id; tool_name; duration_ms } ->
    Printf.printf "[mcp] done  %s/%s in %.1fms\n"
      server_id tool_name duration_ms
  | _ -> ()

(* 主循环里 *)
let bus = Runtime.bus rt in
Event_bus.subscribe bus log_mcp_event
```

### 错误事件

`Mcp_server_failed` 的 `error` 是 `Types.error_category`，常见取值：

- `External_failure "spawn: ..."` ：子进程启动失败（可执行文件不存在）
- `Timeout "startup handshake"` ：initialize 握手超时（`startup_timeout` 到了 server 还没回 `initialize`）
- `Invalid_input "initialize returned error: ..."` ：server 主动报错（如协议版本不匹配）
- `Internal_error "transport closed"` ：子进程在握手阶段就退出了

`Mcp_server_failed` 不会让 `Runtime.create` 直接返回 `Error`（fail-fast 模式下除外）。`Log_and_continue` 策略下，事件先出，runtime 继续运行。

---

## 配置参考

`Mcp_types.server_config` 字段：

```ocaml
type server_config = {
  name            : string;            (* 显示名，同时作为 server_id 基础 *)
  command         : string;            (* 可执行文件路径 *)
  args            : string list;       (* 参数 *)
  env             : (string * string) list;  (* 追加环境变量 *)
  cwd             : string option;     (* 子进程工作目录 *)
  startup_timeout : float;             (* initialize 握手超时秒数 *)
}
```

| 字段 | 说明 | 常见值 |
|------|------|--------|
| `name` | 必填。同名时自动加后缀 | `"fs"`、`"git"`、`"github"` |
| `command` | 必填。绝对路径或 `PATH` 里的可执行名 | `"npx"`、`"/usr/local/bin/mcp-server-fs"` |
| `args` | 默认 `[]` | `[ "-y"; "@modelcontextprotocol/server-filesystem"; "/tmp" ]` |
| `env` | 追加到子进程环境；缺省不覆盖 | `[ ("GITHUB_TOKEN", "ghp_...") ]` |
| `cwd` | `None` 时用 PAR 进程的 cwd | `Some "/var/data"` |
| `startup_timeout` | 秒；握手超时返回错误 | `5.0` ~ `30.0` |

### 命名规则

- `name` 为 `"fs"` → `server_id` 为 `"fs"`
- 第二个 `"fs"` → 自动加后缀 `"fs-1"`
- 第三个 → `"fs-2"`，依此类推
- 比较语义在 `Mcp_types.server_id_compare` 中定义（字符串字典序）

### 环境变量隔离

`env` 字段是**追加**，不是替换。子进程会继承 PAR 父进程的完整环境，再叠加你提供的键值对。安全建议：

- secret 走文件，不要在 `env` 里传（PAR bash 工具会脱敏 env，但 MCP 子进程没有这层防护）
- 调试用 `env` 注入 `DEBUG=1`、`LOG_LEVEL=debug` 这类非敏感标志
- 想清空某个变量，写空字符串：`("FOO", "")`

---

## 类型参考

### capabilities

```ocaml
type capabilities = {
  tools     : bool;
  resources : bool;
  prompts   : bool;
  logging   : bool;
  sampling  : bool;
}
```

由 server 在 initialize 响应中声明。PAR v0.3.1 读取后存入 server 状态，可通过 `Mcp_client.capabilities` 查。PAR 不消费 `logging` 和 `sampling`，但保留在结构里用于协议兼容。

### 工具 / 资源 / 提示词

```ocaml
type mcp_tool = {
  name         : string;
  description  : string option;  (* LLM 看的说明 *)
  title        : string option;
  input_schema : Yojson.Safe.t;  (* JSON Schema *)
}

type mcp_resource = {
  uri         : string;
  name        : string;
  description : string option;
  mime_type   : string option;
  title       : string option;
}

type mcp_prompt = {
  name        : string;
  description : string option;
  title       : string option;
  arguments   : mcp_prompt_arg list;  (* 参数元数据 *)
}

type mcp_prompt_arg = {
  name        : string;
  description : string option;
  required    : bool;
}
```

### 其他公开类型

```ocaml
type prefix_style =
  | Hierarchical
  | Flat
```

`prefix_style` 是为 v0.3.2+ 工具命名规则预留的类型。v0.3.1 已定义但未对外暴露配置项。

```ocaml
type server_info = {
  name    : string;
  version : string;
}
```

server 在 initialize 响应里回报的标识。`Mcp_server.spawn` 成功后可通过日志或自定义 RPC 拿到。

---

## 最佳实践

### 选择启动策略

- **生产环境**：`Fail_fast`。如果一个 server 不可用，runtime 就不该启动成功。
- **开发 / 本地环境**：`Log_and_continue`，让可选 server（linter、formatter）缺失不影响主流程。
- **CI 环境**：`Log_and_continue` 避免因为某个 MCP server 没装就让测试套件全红。

### 超时设置

`startup_timeout` 太短会让启动慢的 server 误判失败，太长又会让失败的 server 阻塞 `Runtime.create`：

- 本地 npx 启动：10s 足够
- 拉取镜像的远端 server：30s
- 调试态首次启动（冷启动 + 依赖下载）：60s

### 事件监控

把 `Mcp_server_failed` 和 `Mcp_tool_completed` 接进你的监控系统：

- `Mcp_server_failed` 频率高 = 配置或环境出问题
- `Mcp_tool_completed` 的 `duration_ms` 可用于 P99 延迟告警

### 不要在 env 里传 secret

MCP 子进程**不会**经过 PAR 的 `Bash_policy.sanitize_env` 脱敏。`env` 字段是直通的。如果需要 token，写到文件里，让 MCP server 自己 `read` 或通过启动参数传入。

---

## 当前限制

v0.3.1 是 MCP 集成的最小可用版本。下列能力**尚未实现**：

- HTTP / SSE transport（仅支持 stdio）
- sampling（server → LLM 反向调用）
- roots / elicitation
- 多 session 并发（同 server_id 复用、session 池）
- 流式 tool 输出

如果你对上述任一能力有强需求，提交 issue 时附场景描述。

---

## 安全审计清单

新增 MCP server 配置前自检：

- [ ] `command` 指向可信可执行文件（避免 shell 注入）
- [ ] `args` 不含敏感信息（出现在 `ps` 输出里）
- [ ] `env` 不含 secret（写文件或走配置中心）
- [ ] `cwd` 是绝对路径，避免歧义
- [ ] `startup_timeout` 与 server 真实启动时间匹配
- [ ] 失败时选择正确的 `startup_policy`
- [ ] event bus 订阅 `Mcp_server_failed` 以感知异常
- [ ] `Mcp_tool_completed` 的 `duration_ms` 接入监控
- [ ] 子进程退出码通过 `Runtime.close` 的返回值审计
- [ ] 自定义 server 实现遵循 MCP 协议（用官方 SDK 或充分测试）

## See also

- [`overview.md`](overview.md) ：SDK 架构总览
- [`agent.md`](agent.md) ：Agent 定义、Runtime API、工具注册
- [`tools.md`](tools.md) ：内置工具参考
- [`middleware.md`](middleware.md) ：7 个内置中间件
- [MCP 协议规范](https://modelcontextprotocol.io) ：server 端实现参考
- [MCP server 列表](https://github.com/modelcontextprotocol/servers) ：官方与社区 server 集合
