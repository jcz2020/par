# Plan-then-Execute 模式

如何用 PAR 的 `memory_service`（`get_fn` + `upsert_fn`）实现"先规划后执行"的 agent 模式（类似 Claude Code 的 TodoWrite）。

## 模式说明

Agent 在行动前创建计划，然后随工作进展更新它。每个步骤有状态（`pending`、`in_progress`、`completed`）。计划跨 invoke 持久化，agent 中断后可恢复。

## 前提条件

- 配置了 `memory_service`（SQLite 后端）的 `Runtime`
- 注册了自定义工具的 Agent

## 步骤 1：注册 plan 工具

注册两个工具——`plan_write` 和 `plan_read`——使用 `Runtime.memory_service` 访问 `upsert_fn` 和 `get_fn`：

```ocaml
(* plan_write: 创建或更新计划，保持稳定 ID *)
let plan_write_tool rt =
  let descriptor = {
    Types.name = "plan_write";
    description = "Create or update the current plan. Pass the full plan JSON.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("plan", `Assoc [("type", `String "string")])
      ]);
      ("required", `List [`String "plan"])
    ];
    output_schema = None;
    permission = Allow;
    timeout = Some 5.0;
    concurrency_limit = None;
    on_update = None;
    cache_control = None;
  } in
  let handler (input : Yojson.Safe.t) _tok =
    let plan_json = input |> Yojson.Safe.Util.member "plan" in
    let plan_str = Yojson.Safe.to_string plan_json in
    (match Runtime.memory_service rt with
     | None -> Types.Error { category = Types.Internal "no memory_service";
                             message = ""; retryable = false; metadata = [] }
     | Some mem ->
       let now = Unix.gettimeofday () in
       let m = {
         Memory_object.id = "plan:current";
         content = plan_str;
         summary = None;
         scope = Some "plan";
         metadata = [];
         categories = ["plan"];
         created_at = now;
         updated_at = now;
         last_used_at = None;
         usage_count = 0;
         source = "agent";
        } in
       (match mem.Types.upsert_fn m with
        | Ok _ -> Types.Success (`Assoc [("status", `String "ok")])
        | Error e -> Types.Error { category = e; message = "upsert failed";
                                   retryable = false; metadata = [] }))
  in
  (descriptor, handler)

(* plan_read: 按稳定 ID 获取当前计划 *)
let plan_read_tool rt =
  let descriptor = {
    Types.name = "plan_read";
    description = "Read the current plan. Returns the plan JSON or null if no plan exists.";
    input_schema = `Assoc [("type", `String "object"); ("properties", `Assoc [])];
    output_schema = None;
    permission = Allow;
    timeout = Some 5.0;
    concurrency_limit = None;
    on_update = None;
    cache_control = None;
  } in
  let handler (_input : Yojson.Safe.t) _tok =
    (match Runtime.memory_service rt with
     | None -> Types.Error { category = Types.Internal "no memory_service";
                             message = ""; retryable = false; metadata = [] }
     | Some mem ->
       (match mem.Types.get_fn "plan:current" with
        | Ok None -> Types.Success `Null
        | Ok (Some m) ->
          Types.Success (`String m.content)
        | Error e -> Types.Error { category = e; message = "get failed";
                                   retryable = false; metadata = [] }))
  in
  (descriptor, handler)
```

## 步骤 2：在 Agent 上注册工具

对步骤 1 构建的每个工具调用 `Runtime.register_tool`，传入描述符字段和处理函数：

```ocaml
let (plan_write_desc, plan_write_handler) = plan_write_tool rt in
let _ = Runtime.register_tool rt
  ~name:plan_write_desc.Types.name
  ~description:plan_write_desc.description
  ~input_schema:plan_write_desc.input_schema
  ~handler:plan_write_handler in

let (plan_read_desc, plan_read_handler) = plan_read_tool rt in
let _ = Runtime.register_tool rt
  ~name:plan_read_desc.Types.name
  ~description:plan_read_desc.description
  ~input_schema:plan_read_desc.input_schema
  ~handler:plan_read_handler in
```

## 步骤 3：在系统提示词中引导

```ocaml
let agent = Runtime.make_agent
  ~id:"planner"
  ~system_prompt:(stable_prompt
    "You have plan_read and plan_write tools. \
     Always create a plan before starting work. \
     Update step status as you complete each step.")
  ~model ~tools:[plan_write_desc; plan_read_desc] ()
```

## 为什么可行

| 属性 | 实现方式 |
|---|---|
| **稳定 ID** | `upsert_fn` 保持 `"plan:current"` 作为 ID（不像 `add` 生成新 UUID，也不像 `update` 改变 ID） |
| **精确查询** | `get_fn "plan:current"` 返回单个计划——不做 FTS5 模糊搜索 |
| **跨 session 持久化** | Memory 存储在 SQLite，进程重启后仍可用 |
| **多 agent 共享** | 同一 runtime 上的所有 agent 共享 `memory_service` |

## 另请参阅

- [Memory API](../sdk/memory.md) — `memory_service` 完整参考
- 「Skill 作为行为模式」（见 `sdk/skills.md`）— 按调用切换模式
- DECISIONS.md — 为什么 PAR 用 app 层工具而非 runtime Plan 类型
