<!-- language: zh -->

# Generate API 参考

[English](../sdk/generate.md) · **简体中文**

> v0.6.x 新增。源真相：OCaml 函数 `Runtime.invoke_generate`（`lib/core/runtime.ml`）、`Generate.run`（`lib/core/generate.ml`）、`generate_result` 类型（`lib/core/types.ml`）。

本页是 PAR 纯长输出生成路径的 API 契约。锁定 `invoke_generate` 的形态、`generate_result` 返回类型、自动续写行为以及调用方可观察到的事件。如果你在写长输出 agent（PRD、HTML mockup、计划、文档），想停止手工直连 LLM 调用，请读"使用示例"一节。如果你在接 FFI 或移植当前绕开 `Runtime.invoke` 的存量 agent，请先读"自动续写行为"和"限制"。

## 概览

长输出生成和 ReAct 推理是两种不同的负载。一个 PRD 写手一次性产出 3,000 到 6,000 token 的 Markdown。一个 HTML mockup agent 产出单个大体积 artifact。这些都不涉及工具调用，也都不能从迭代预算中获益。把 `Max_tokens` 截断当成消耗循环的失败（ReAct 的默认行为）在这类工作上是错的。截断是 transport 细节。模型完成了它能完成的部分；runtime 的工作是交付完整输出，而不是因为模型碰到上限就惩罚它。

来自下游 an integrator 项目的反馈确认了这个缺口：长输出 agent 全部绕开 `Runtime.invoke`，手工调用 `llm_chat_raw`，只把 PAR 当作 session 和 event 管理用。长输出生成模式计划 §1 记录了对四家主流 coding agent（Claude Code、Codex CLI、OpenCode、a comparable coding agent）的调研：没有一家把 `Max_tokens` 当作消耗迭代的事件。PAR 是异类。`Runtime.invoke_generate` 通过为纯生成暴露一等入口来收尾这个转型。它完全跳过 ReAct 循环，遇到 `Max_tokens` 截断时自动续写，并复用 `invoke` 已经在用的 session 存储、事件总线、LLM 服务抽象和 skill 叠加机制。

生成路径是刻意收窄的。它不在 ReAct 边界跑中间件，不查 `max_iterations`，也不每次迭代查 `max_execution_time`（由一个可选的 `total_timeout` 替代）。它和 `invoke` 共享的是所有应该共享的部分：provider 抽象、session 持久化、事件发布、skill 组合、流式回调形态。

## 何时用 invoke_generate，何时用 invoke

- 当任务是产出长文本 artifact 且不需要工具调用时，用 `invoke_generate`：PRD、HTML mockup、计划、文档、报告、模型一次性写出整个文件的代码清单。它会在 `Max_tokens` 截断时自动续写，调用方不必自己实现 chunk 拼接胶水。
- 当任务需要工具调用、多步推理、或 ReAct 循环语义时，用 `invoke`：搜索、计算、跑 bash、查询数据库、或交接给其他 agent 的 agent。当 LLM 和工具边界上的中间件重要时，`invoke` 也是正确选择，因为 `invoke_generate` 跳过那条管道。

粗略规则：如果 agent 的 `tools` 列表为空且输出很长，用 `invoke_generate`。如果 agent 有工具，用 `invoke`。`invoke_generate` 在注册时强制这条规则的前半句：`tools` 列表非空的 agent 会被以 `Invalid_input` 拒绝。

## 类型定义

### generate_result

由 `Runtime.invoke_generate` 返回。与 `invoke_result` 不同，因为生成路径不跑 ReAct 循环，所以这个形态暴露的是续写和 token 计数，而非迭代计数。

```ocaml
type generate_result = {
  text          : string;              (* 初始响应和所有续写 chunk 拼接出的完整
                                          输出。仅在完全失败时为空。 *)
  finish_reason : finish_reason;       (* Stop | Tool_calls | Max_tokens |
                                          Content_filter。Stop 是正常路径。
                                          Max_tokens 表示递减收益保护停止了
                                          续写。Content_filter 表示 provider
                                          阻挡了响应。 *)
  continuations : int;                 (* 触发的 Continue 子循环 chunk 数。
                                          0 表示模型首次响应就发出 Stop。 *)
  total_tokens  : int option;          (* provider 上报 usage 时跨续写累积的
                                          用量。不上报 token 计数的 provider
                                          （如 OpenAI 流式）返回 None。 *)
  session_id    : string;              (* 生成写入的 session。如果想后续恢复，
                                          请连同 conversation 一起持久化。 *)
  elapsed       : float;               (* 从进入到返回的 wall-clock 秒数，
                                          包含所有续写。 *)
}
```

`finish_reason` 复用 `lib/core/types.ml` 中已有的 ADT：

```ocaml
type finish_reason = Stop | Tool_calls | Max_tokens | Content_filter
```

## API 签名

```ocaml
val Runtime.invoke_generate :
  runtime ->
  agent_id:string ->
  message:string ->
  ?max_output_tokens:int ->
  ?total_timeout:float ->
  ?on_tool_event:(Types.event -> unit) ->
  ?on_chunk:(Types.llm_response_chunk -> unit) ->
  unit ->
  (Types.generate_result, Types.error_category * Types.conversation) result
```

参数说明：

- `agent_id` 解析一个已注册的 agent。该 agent 必须有 `tools = []`。带工具的 agent 会被以 `Invalid_input` 拒绝。
- `message` 是提示词或用户消息。
- `max_output_tokens` 是可选的每次调用初始响应上限。续写在超过这个值后继续累积，直到触发 Stop 条件。省略时使用 agent 的 `model.max_tokens`（或 provider 默认值）。
- `total_timeout` 是可选的对整个生成（包含续写）的 wall-clock 上限。省略时生成无界运行（只受递减收益保护和自然 Stop 约束）。
- `on_tool_event` 是观察回调。它在 `Llm_request_sent`、`Llm_response_received`、`Llm_response_truncated`、`Generate_continuation` 时触发。不会触发任何工具事件，因为生成路径不分发工具。
- `on_chunk` 是可选的流式回调。它在 provider 发出的每个 `llm_response_chunk` 上触发，形态与 `Runtime.invoke` 的 `?on_chunk` 一致。用于想让文本落地时实时渲染的 UI。

`Error` 变体携带 `(error_category, conversation)`，这样调用方即使失败也能持久化部分对话，与 `Runtime.invoke` 的返回形态一致。

## 自动续写行为

Continue 子循环是让 `invoke_generate` 适合长输出的关键。runtime 发起一次普通 LLM 调用。如果 provider 返回 `finish_reason = Max_tokens`，runtime 为可观测性触发一次 `Llm_response_truncated` 事件，然后注入一条续写提示，让模型从停下的地方继续，并发起下一次 LLM 调用。新 chunk 的文本拼到累加器上。循环在以下任一条件触发时终止：

- provider 返回 `finish_reason = Stop`（模型自然完成）。
- provider 返回 `finish_reason = Content_filter`（provider 阻挡了响应）。
- 递减收益保护触发：某个续写 chunk 新增少于 500 字符，说明模型在重述自己而不是在推进。
- `?total_timeout` 到点。如果已经落地至少一个 chunk，runtime 把累积文本作为部分结果返回。如果什么都没落地，返回 `Error (Timeout, conversation)`。

每次成功的续写都会发出一个 `Generate_continuation` 事件，带 chunk 索引（0 基：初始响应后的第一次续写是索引 0）和新增字符数。调用方可以基于这个事件接进度 UI，不必检查文本。

这与 ReAct 路径使用的 `Continue` 语义相同（见 [Agent API](../sdk/agent.md) 中的 `agent_config.on_max_tokens = Continue`），但被抽取成一条专用循环。区别在于：ReAct 路径上 `Continue` 是 per-agent opt-in 且受 `max_continuation_chunks`（默认 3）约束；生成路径上续写是默认行为，cap 被取消，递减收益保护是唯一预算。计划 §1 记录了促成此设计的四家 agent 调研：Claude Code、Codex CLI、OpenCode、a comparable coding agent 没有一家把 `Max_tokens` 当作循环预算事件，PAR 在纯生成场景下对齐了这个不变量。

## 触发的事件

`?on_tool_event` 回调可以观察到以下变体：

- `Llm_request_sent of { task_id; model }`：每次 LLM 往返前，包含续写。
- `Llm_response_received of { task_id; usage }`：每次 LLM 往返后。
- `Llm_response_truncated of { task_id; model; finish_reason }`：当 provider 返回 `Max_tokens` 时。这里 `finish_reason` 总是 `Max_tokens`。
- `Generate_continuation of { task_id; chunk_index; chars_added }`：每次成功续写 chunk 后。`chunk_index` 对续写 chunk 是 0 基的；初始响应不算续写。

此路径不会触发 `Tool_invoked`、`Tool_completed`、`Bash_invoked` 或交接事件。生成循环不分发工具。

## 使用示例

### 示例 1：基本生成（OCaml）

注册一个无工具 agent，然后调用 `invoke_generate` 生成长 PRD。runtime 透明地处理续写，调用方看到的是完整拼接文本。

```ocaml
open Par

let () = Eio_main.run (fun _env ->
  Eio.Switch.run (fun switch ->
    match Runtime.create ~config:<runtime_config> switch with
    | Error e -> prerr_endline (Types.string_of_error_category e)
    | Ok rt ->
      (* Tool-less agent: the only kind invoke_generate accepts. *)
      let agent = {
        Types.id = "prd-agent";
        system_prompt = Types.stable_prompt "You write detailed product requirement documents.";
        system_prompt_template = None;
        model = { provider = `Openai; model_name = "gpt-4";
                  api_base = None; temperature = 0.4;
                  max_tokens = Some 4096; top_p = None; stop_sequences = None };
        tools = [];
        max_iterations = 1;        (* unused on the generate path *)
        middleware = [];
        retry_policy = None;
        context_strategy = None;
        resource_quota = None;
        max_execution_time = None; (* unused; total_timeout replaces it *)
        early_stopping_method = Types.Force;
        on_max_tokens = None;      (* None = Auto: tool-less resolves to Continue *)
        max_continuation_chunks = None; (* None = Auto: unbounded for tool-less *)
        tool_timeout = None;
      } in
      (match Runtime.register_agent rt agent with
       | Error e -> prerr_endline (Types.string_of_error_category e)
       | Ok () ->
         match Runtime.invoke_generate rt
           ~agent_id:"prd-agent"
           ~message:"Write a PRD for offline-first sync in a notes app."
           ()
         with
         | Error (e, _conv) ->
           prerr_endline (Types.string_of_error_category e)
         | Ok result ->
           Printf.printf "%s\n" result.Types.text;
           Printf.printf "finish_reason: %d continuations, %f s\n"
             result.Types.continuations result.Types.elapsed));
      ignore (Runtime.close rt))
)
```

不传 `?max_output_tokens` 和 `?total_timeout` 时，默认值分别是 agent 的 model cap 和无界。

### 示例 2：Python 使用

`Runtime.invoke_generate` 暴露在 Python 的 `Runtime` 类上。返回值是一个 dict，含 `generate_result` 字段以及 FFI 用于所有 `result` 类型的 `Ok` / `Error` 判别形态。

```python
import json
from par_runtime import Runtime

config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "llm_providers": [["openai", {"tag": "openai",
                                   "contents": {"api_key": "sk-..."}}]],
    "default_quota": {"max_tokens": 4096, "max_iterations": 10,
                      "timeout_seconds": 120.0},
})

with Runtime(config) as rt:
    rt.register_agent(json.dumps({
        "id": "prd-agent",
        "system_prompt": "You write detailed PRDs.",
        "model": {"provider": "openai", "model_name": "gpt-4",
                  "temperature": 0.4, "max_tokens": 4096},
        "tools": [],
        "max_iterations": 1,
        "early_stopping_method": "Force",
    }))
    result = rt.invoke_generate("prd-agent", "Write a PRD for feature X.")
    print(result["text"])
    print(f"finish_reason={result['finish_reason']}, "
          f"continuations={result['continuations']}, "
          f"elapsed={result['elapsed']:.2f}s")
```

agent 配置里 `tools = []`，因为 `invoke_generate` 拒绝带工具的 agent。Python 绑定返回的字段与 OCaml `generate_result` 记录一致。

### 示例 3：带流式回调

传入 `?on_chunk` 以在文本落地时实时渲染。回调接收与 `Runtime.invoke` 和 `invoke_stream` 相同的 `llm_response_chunk` ADT。拼接 `Text_delta` 载荷即可增量渲染。

```python
import json
from par_runtime import Runtime, TextDelta

def on_chunk_json(chunk_json: str) -> None:
    chunk = json.loads(chunk_json)
    if chunk.get("tag") == "Text_delta":
        print(chunk["contents"]["text"], end="", flush=True)

with Runtime(config) as rt:
    rt.register_agent(json.dumps({
        "id": "mockup-agent",
        "system_prompt": "You produce self-contained HTML mockups.",
        "model": {"provider": "anthropic",
                  "model_name": "claude-sonnet-4-20250514",
                  "temperature": 0.3, "max_tokens": 8192},
        "tools": [],
        "max_iterations": 1,
        "early_stopping_method": "Force",
    }))
    result = rt.invoke_generate(
        "mockup-agent",
        "Mock up a settings page with light and dark modes.",
        on_chunk=on_chunk_json,
        total_timeout=90.0,
    )
    print()  # 流式文本后的换行
    print(f"[done: {result['continuations']} continuations, "
          f"{result['elapsed']:.2f}s]")
```

`total_timeout` 对整个生成（包含续写）设上限。如果模型在截止时间仍在运行，runtime 返回已累积的内容。

## 限制

- **agent 必须有 `tools = []`。** 带工具的 agent 在 `invoke_generate` 调用点被以 `Invalid_input` 拒绝。这是强制的，而非静默忽略，因为生成路径没有工具分发。如果你的 agent 需要工具，请用 `Runtime.invoke` 配合 `on_max_tokens = Continue`。
- **没有 fallback 链。** 生成路径只使用 agent 的主 provider。runtime 上配置的跨 provider `fallback_policy` 不生效。需要 provider 多样性的长生成应该跑多次 `invoke_generate`，在上游挑选最佳输出。
- **wall-clock 超时在累积文本上返回部分结果。** 当 `?total_timeout` 在至少一个 chunk 落地后触发，runtime 返回 `Ok`，`finish_reason` 反映最后一次 provider 响应，并附累积文本。当超时在任何 chunk 落地前触发（初始 LLM 调用挂死），返回 `Error (Timeout, conversation)`。
- **递减收益保护固定为 500 字符。** 新增少于 500 字符的续写 chunk 会终止循环。这能捕获陷入重述的模型。v0.6.x 不可配置。
- **LLM 边界没有中间件。** `agent_config.middleware` 管道不在生成路径上触发。你在 `invoke` 上依赖的日志、重试、限流中间件在这里不会跑。需要等价行为请在调用点自己接。
- **`max_iterations` 和 `max_execution_time` 被忽略。** 它们存在于 `agent_config` 是为了 ReAct 兼容。生成路径用 `?total_timeout` 替代它们。续写次数没有固定 cap，递减收益保护是唯一上限。

## See also

- [Agent API](agent.md) - `agent_config`、`Runtime.invoke`、ReAct 入口以及与 generate 续写逻辑对应的 `on_max_tokens` 策略
- [Streaming API](../../sdk/streaming.md) - `invoke_stream`、chunk 化交付，以及 `?on_chunk` 在这里暴露的 `llm_response_chunk` ADT（英文，暂无中文版）
- [Overview](overview.md) - SDK 架构和模块图
