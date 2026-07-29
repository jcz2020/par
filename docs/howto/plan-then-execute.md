# Plan-then-Execute pattern

How to implement a "plan-then-execute" agent pattern (like Claude Code's TodoWrite) using PAR's `memory_service` with `get_fn` and `upsert_fn`.

## The pattern

An agent creates a plan before acting, then updates it as work progresses. Each step has a status (`pending`, `in_progress`, `completed`). The plan persists across invokes so the agent can resume after interruptions.

## Prerequisites

- A `Runtime` with `memory_service` configured (SQLite backend)
- An agent registered with custom tools

## Step 1: Register plan tools

Register two tools — `plan_write` and `plan_read` — that use `memory_service.upsert_fn` and `get_fn`:

```ocaml
(* plan_write: create or update a plan with a stable ID *)
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
       let json = Memory_object.to_yojson m in
       (match mem.Types.upsert_fn json with
        | Ok _ -> Types.Success (`Assoc [("status", `String "ok")])
        | Error e -> Types.Error { category = e; message = "upsert failed";
                                   retryable = false; metadata = [] }))
  in
  (descriptor, handler)

(* plan_read: fetch the current plan by its stable ID *)
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
        | Ok (Some json) ->
          let m = Memory_object.of_yojson json |> Result.get_ok in
          Types.Success (Yojson.Safe.from_string m.content)
        | Error e -> Types.Error { category = e; message = "get failed";
                                   retryable = false; metadata = [] }))
  in
  (descriptor, handler)
```

## Step 2: Register the tools on your agent

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

## Step 3: Use in system prompt

Tell the agent to use these tools:

```ocaml
let agent = Runtime.make_agent
  ~id:"planner"
  ~system_prompt:(stable_prompt
    "You have plan_read and plan_write tools. \
     Always create a plan before starting work. \
     Update step status as you complete each step.")
  ~model ~tools:[plan_write_desc; plan_read_desc] ()
```

## Why this works

| Property | How |
|---|---|
| **Stable ID** | `upsert_fn` keeps `"plan:current"` as the ID across updates (unlike `add` which generates new UUIDs, or `update` which changes the ID) |
| **Exact lookup** | `get_fn "plan:current"` returns the single plan — no FTS5 fuzzy search |
| **Cross-session persistence** | Memory is stored in SQLite, surviving process restarts |
| **Multi-agent sharing** | All agents on the same runtime share the same `memory_service` |

## See also

- [Memory API](../sdk/memory.md) — `memory_service` full reference
- [Skills as behavioral modes](../sdk/skills.md#skills-as-behavioral-modes) — per-call mode switching
- [DECISIONS.md](../DECISIONS.md) — why PAR uses app-layer tools instead of a runtime Plan type
