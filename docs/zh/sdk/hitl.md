# Human-in-the-Loop (HITL) API 参考

[English](https://github.com/jcz2020/par/blob/main/sdk/hitl.md) · **简体中文**

> 源码真相：`lib/core/approval.ml`、`lib/core/types.ml`、`lib/core/engine.ml`、`lib/core/runtime.ml`。

本文档涵盖 PAR 的挂起-恢复审批框架。Agent 在执行过程中可以暂停，等待人工审批后再继续。审批状态持久化到 SQLite，即使进程重启也能恢复。

## 何时使用 HITL

当 Agent 执行的操作需要人工监督时，使用 HITL：

- 发送邮件、调用外部 API 或修改外部系统
- 访问敏感数据或执行金融交易
- 任何错误的工具调用可能导致不可逆损害的场景

没有 HITL 时，工具要么运行要么不运行。有了 HITL，工具可以暂停并询问"是否继续？"，等待响应。

## 核心类型

### `approval_outcome`

人工（或自动化）审批决策的结果：

```ocaml
type approval_outcome =
  | Approved                                    (* 继续执行工具调用 *)
  | Rejected of { reason : string }             (* 拒绝操作，说明原因 *)
  | Modified of { new_input : Yojson.Safe.t }   (* 继续，但使用不同的参数 *)
  | Escalated of { target : string }            (* 转发给其他 Agent 或处理器 *)
  | Timeout                                     (* 在允许的时间窗口内未收到响应 *)
```

每个变体的具体语义：

| 变体 | 后续行为 |
|------|---------|
| `Approved` | 原始工具使用原始输入执行。 |
| `Rejected` | 工具结果标记为已拒绝。Agent 循环继续，Agent 会看到拒绝并调整。 |
| `Modified` | 工具使用 `new_input` 重新执行，而非原始参数。 |
| `Escalated` | 控制权转移到指定的 `target` Agent，类似 handoff。 |
| `Timeout` | 工具结果标记为已拒绝，同时发出 `Approval_timeout` 事件。 |

### `approval_context`

当工具触发审批时，传递给审批处理器的信息：

```ocaml
type approval_context = {
  agent_id      : string;
  tool_name     : string;
  tool_input    : Yojson.Safe.t;
  conversation  : Conversation.t;
  pending_action: Yojson.Safe.t;
  metadata      : (string * Yojson.Safe.t) list;
}
```

处理器会收到做出决策所需的全部信息：正在调用的工具名称、工具输入参数、完整的对话历史，以及调用时附加的元数据。

### `approval_handler`

处理器 ADT 支持三种部署模式：

```ocaml
type 'a approval_handler =
  | Sync_local of (approval_context -> approval_outcome)
  | Async_callback of (approval_context -> approval_outcome Eio.Promise.t)
  | Webhook of {
      url         : string;
      secret      : string;
      timeout_sec : float;
    }
```

#### `Sync_local`

同步 OCaml 函数。引擎直接调用并等待结果。适合开发、测试和单进程部署，当审批逻辑比较简单时使用。

```ocaml
let my_handler (ctx : Types.approval_context) =
  (* 简单策略：批准非破坏性工具，拒绝其余 *)
  match ctx.tool_name with
  | "read_file" | "search" -> Approval.Approved
  | _ -> Approval.Rejected { reason = "需要手动审批" }
```

#### `Async_callback`

返回一个 `Eio.Promise.t`，稍后解析。引擎挂起执行并将待审批状态持久化到 SQLite。审批可以从 Agent 执行上下文外部解决。这是生产环境 OCaml 部署的标准选择。

```ocaml
let async_handler (ctx : Types.approval_context) promise =
  (* 在生产环境中：推送到 UI 队列、发送审批邮件等。
     解析时，promise 携带审批结果。 *)
  ignore (ctx, promise)
```

#### `Webhook`

HTTP 端点，接收包含审批上下文 JSON 的 POST 请求。引擎挂起并等待外部系统调用 `Runtime.resume_approval`。这是跨进程部署、Python FFI 使用和远程审批 UI 的标准选择。

```ocaml
let webhook_handler =
  Approval.Webhook {
    url         = "https://approval.example.com/hooks/par";
    secret      = "my-hmac-secret";
    timeout_sec = 600.0;  (* 10 分钟 *)
  }
```

### `handler_result.Approval_required`

当工具需要请求审批时，它从处理器返回 `Approval_required` 变体：

```ocaml
type handler_result =
  | Success of { output : Yojson.Safe.t; ... }
  | Error of { message : string; ... }
  | Handoff of { target_agent_id : string; ... }
  | Approval_required of {
      tool_name     : string;
      tool_input    : Yojson.Safe.t;
      prompt        : string;           (* 给审批者的可读消息 *)
      timeout       : float option;     (* 覆盖处理器默认超时 *)
      allowed_roles : string list;      (* 谁可以审批 *)
    }
```

`prompt` 字段为审批者提供工具即将执行的操作的上下文。Agent 的 `approval_handler`（在 `agent_config` 上设置）决定如何分发此请求。

## 设置审批处理器

### `agent_config.approval_handler`

每个 Agent 都有一个可选的 `approval_handler` 字段。设置后，返回 `Approval_required` 的工具会通过此处理器分发。当为 `None` 时，返回 `Approval_required` 的工具会导致硬错误（工具不会执行）。

通过 `make_agent` 设置：

```ocaml
let agent =
  Par.Runtime.make_agent
    ~id:"assistant"
    ~model:"openai/gpt-4o-mini"
    ~approval_handler:(Approval.Sync_local my_handler)
    ()
```

在 Python 绑定中：

```python
from par_runtime import Runtime

with Runtime(config) as rt:
    agent = rt.make_agent(
        id="assistant",
        model="openai/gpt-4o-mini",
    )
    # 注册审批处理器（Callable → 同步，str → webhook URL）
    rt.register_approval_handler(my_handler_fn)
```

## 挂起-恢复流程

审批请求的完整生命周期：

```
1. Agent 调用工具
2. 工具返回 Approval_required { prompt = "是否批准发送邮件？"; ... }
3. 引擎读取 agent.approval_handler
4. 处理器分发（Sync_local → 直接调用，Async/Webhook → 挂起）
5. 如果是 async/webhook：
   a. 待审批状态写入 SQLite approvals 表
   b. 发出 Approval_requested 事件
   c. Agent 状态持久化，包含对话快照
   d. 返回 invoke_result，status = Awaiting_approval
6. 外部解析器调用 Runtime.resume_approval ~run_id ~outcome ~approver
7. 从 SQLite 加载待审批状态，验证，删除
8. 将审批结果注入到挂起点的 ReAct 循环
9. Agent 使用审批结果继续执行
```

### `Runtime.resume_approval`

通过传递审批结果来恢复挂起的 Agent：

```ocaml
val Runtime.resume_approval :
  rt:runtime ->
  run_id:string ->
  outcome:Approval.approval_outcome ->
  approver:string ->
  (unit, error_category) result
```

参数：

| 参数 | 描述 |
|------|------|
| `run_id` | Agent 挂起时返回的运行 ID。 |
| `outcome` | 要注入的 `approval_outcome`（Approved、Rejected、Modified、Escalated、Timeout）。 |
| `approver` | 提供决策的标识符（用于审计跟踪）。 |

可能的错误：

- `Invalid_input`：`run_id` 未知或待审批已过期。
- `Internal`：对话快照哈希不匹配（状态已漂移）。

### 跨进程持久化

待审批存储在 SQLite `approvals` 表中：

| 列 | 类型 | 描述 |
|----|------|------|
| `run_id` | TEXT (PK) | 此挂起运行的唯一标识符。 |
| `agent_id` | TEXT | 哪个 Agent 被挂起。 |
| `payload` | TEXT | 序列化的审批上下文和对话快照。 |
| `created_at` | REAL | 创建审批时的 Unix 时间戳。 |
| `expires_at` | REAL | 审批过期时的 Unix 时间戳。 |

如果进程崩溃并重启，`resume_approval` 会从 SQLite 加载挂起的状态并重新分发。这就是审批能在重启后恢复的机制。

## Wave 3 简化：重新分发

当 `resume_approval` 恢复挂起的 Agent 时，它会将工作项重新分发到 Agent 的 ReAct 循环。对于需要返回存储结果的 `Sync_local` 处理器（例如，回放先前已批准的审批），处理器可以直接返回存储的 `approval_outcome`：

```ocaml
(* 回放存储结果的处理器 *)
let replay_handler (stored : Approval.approval_outcome) =
  Approval.Sync_local (fun _ctx -> stored)
```

这个模式在引擎内部用于恢复后的重新分发。它将原始处理器替换为返回存储结果的 `Sync_local`，避免第二次审批提示。

## 事件

HITL 框架发出七种事件变体用于可观测性：

| 事件 | 何时触发 |
|------|---------|
| `Approval_requested` | Agent 挂起，等待外部解析。 |
| `Approval_granted` | 结果为 `Approved`。 |
| `Approval_rejected` | 结果为 `Rejected`。 |
| `Approval_modified` | 结果为 `Modified`。 |
| `Approval_escalated` | 结果为 `Escalated`。 |
| `Approval_timeout` | 结果为 `Timeout`。 |
| `Approval_handler_missing` | 工具返回 `Approval_required` 但未配置处理器。 |

## 完整示例：同步处理器 + resume

```ocaml
open Par

let approval_policy (ctx : Types.approval_context) =
  match ctx.tool_name with
  | "send_email" ->
   Printf.printf "是否批准发送邮件？(y/n): %!";
    let response = read_line () in
    if String.lowercase_ascii response = "y"
    then Approval.Approved
    else Approval.Rejected { reason = "用户拒绝" }
  | _ -> Approval.Approved  (* 其余全部批准 *)

let () = Eio_main.run (fun env ->
  Eio.Switch.run (fun switch ->
    let config = Runtime.default_config ~persistence:(`Sqlite ":memory:") () in
    match Runtime.create ~config switch with
    | Error e -> prerr_endline (Runtime.string_of_error_category e)
    | Ok rt ->
      let agent =
        Runtime.make_agent
          ~id:"mailer"
          ~model:"openai/gpt-4o-mini"
          ~approval_handler:(Approval.Sync_local approval_policy)
          ()
      in
      let result = Runtime.invoke ~rt ~agent "给 alice@example.com 发送问候邮件" in
      print_endline result.Types.response.text;
      ignore (Runtime.close rt)))
```

## 完整示例：webhook 处理器

```ocaml
let webhook_config =
  Approval.Webhook {
    url         = "https://approval.example.com/hooks/par";
    secret      = "hmac-secret-key";
    timeout_sec = 600.0;
  }

let agent =
  Runtime.make_agent
    ~id:"production-agent"
    ~model:"openai/gpt-4o"
    ~approval_handler:webhook_config
    ()
```

当 Agent 触发审批时：

1. 引擎挂起并将待审批状态写入 SQLite。
2. 向 `https://approval.example.com/hooks/par` 发送 POST 请求，包含审批上下文 JSON。
3. 你的外部服务处理请求，准备就绪后调用 `Runtime.resume_approval`。
4. Agent 使用审批结果恢复执行。

## Python 交叉引用

Python 绑定通过 ctypes 暴露相同的 HITL 能力。详见 [Python FFI 文档](https://github.com/jcz2020/par/blob/main/bindings/python/)：

- `Runtime.register_approval_handler(handler)`，`handler` 为 `Callable`（同步）或 `str`（webhook URL）。
- `Runtime.resume_approval(run_id, outcome_dict)` 传递审批结果。
- `Runtime.invoke_parallel(specs)` 支持每 Agent 的审批覆盖。

## 迁移

如果你有现有的代码对 `handler_result` 进行模式匹配，需要为 `Approval_required` 添加一个分支：

```ocaml
(* v0.8.0 之前 *)
match result with
| Success _ -> ...
| Error _ -> ...
| Handoff _ -> ...

(* v0.8.0 之后 *)
match result with
| Success _ -> ...
| Error _ -> ...
| Handoff _ -> ...
| Approval_required _ -> (* 处理审批请求 *)
```

OCaml 编译器会对缺失的分支发出警告（非错误），因此现有代码可以编译，但你应该添加分支来正确处理审批请求。
