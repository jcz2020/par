<!-- language: zh -->
**[English](../sdk/streaming.md)** · 简体中文

# Streaming API 参考

> **Note (v0.6.7):** 对 `bin/main.ml` 第 386 行的引用是历史性的 — CLI 在 v0.6.7 中被移除，流式逻辑现在位于 SDK 和 FFI 中。当前入口点见 [SDK 概览](overview.md)。

> 在 v0.5.1 中添加。真实来源：`lib/core/types.ml` 中的 OCaml 类型 `Types.llm_response_chunk`。Phase C.1 设计契约；Phase C.2（FFI 桥接）和 C.3（Python generator）实现本文档。

本页面是 PAR Python 绑定流式 LLM 输出的 API 契约。它定义了 `invoke_stream` 的形状、`Event` 标签联合（tagged union）、背压（backpressure）策略和线程模型。如果你正在编写逐 token 消费输出的 Python 代码，请阅读"使用示例"部分。如果你正在实现 FFI 桥接，请跳到末尾的"实现说明"。

## 概览

流式输出让调用方可以逐 token 消费 LLM 的输出，而不用等待完整响应。对于交互式 UI，这将感知延迟从"等 8 秒，然后倾倒 500 个词"降低到"200 ms 内出现第一个 token，然后稳定滴流"。对于长时间运行的工具调用流程，这也意味着调用方在看到足够信息后可以提前取消。

PAR 在 v0.5.1 中通过新的 Python 方法 `invoke_stream` 暴露了 `Runtime.invoke` 上已有的 `?on_chunk` 参数来添加流式支持。OCaml 端自 v0.4.0 起就支持分块输出（见 `lib/core/types.ml` 第 509 行的 `llm_response_chunk` ADT），但 FFI 层和 Python 封装尚未发布。本文档在任何实现代码编写之前定义了它们应有的样子。

Provider 支持情况各不相同，详见下方"Provider 支持"部分。OpenAI、Anthropic 和 Mock 都支持文本增量和工具调用增量流式输出；只有 Anthropic 和 Mock 还会发出用量更新。

## 考虑过的三种方案

在设计 Python 接口时，有三种方案摆在桌面上。这里记录它们以便审查可追溯，也让未来的维护者不会在没有上下文的情况下重新争论。

### 方案 1：Generator

运行时暴露一个返回惰性迭代器的方法。每次 `next()` 调用产出一个 `Event`。调用方用 `for` 循环驱动消费。

```python
def invoke_stream(self, agent_id: str, message: str) -> Iterator[Event]: ...

for event in rt.invoke_stream("agent", "hello"):
    ...
```

**优点**

- 符合 OpenAI Python SDK 的惯例（`stream=True` 返回 `ChatCompletionChunk` 迭代器）。有 OpenAI 流式开发经验的开发者第一次就能写出符合 PAR 风格的代码。
- 与 Python 生态无缝组合：`list(stream)`、`itertools.islice(stream, n)`、`asyncio.run_in_executor` 封装、基于 generator 的管道。
- 背压是免费的。OCaml 端只在 generator 恢复时才产出下一个 chunk，因此慢消费者不会淹没队列。
- 资源清理清晰映射到 `generator.close()` 和 `with` 语句。generator 主体中的 `finally` 子句可以取消底层 OCaml fiber。
- 取消只需 `break`。Python 的迭代器协议已经处理了 `GeneratorExit` 传播。

**缺点**

- 调用方必须消费迭代器。如果他们调用 `invoke_stream` 后丢弃结果，OCaml 端可能继续运行直到下一次 chunk 尝试永远阻塞。缓解措施：generator 中的 `finally` 子句取消 fiber，加上 `__del__` 警告。
- 错误面被分散。某些故障从 `next()` 抛出（chunk 级别错误），另一些从初始的 `invoke_stream` 调用抛出（参数验证）。这与 OpenAI 的 SDK 相同，但值得注意。
- 需要跨线程交接。OCaml 运行时在自己的 fiber 上调用 C 回调；generator 在调用方的线程上运行。必须用队列桥接它们。对于任何允许调用方在自己线程上消费的流式方案，这都是不可避免的。
- 更难在后续层叠额外的回调式钩子（日志、指标）。每一层都必须是 generator 封装而非函数。

**适用场景。** 当调用方是 Python 风格的，想要自然的 `for` 循环，且不需要将事件扇出给多个订阅者时。

### 方案 2：回调

运行时暴露带 `on_event` 关键字参数的 `invoke`，对每个 chunk 触发。调用方传入一个可调用对象。

```python
def invoke(self, agent_id: str, message: str,
           on_event: Callable[[Event], None]) -> None: ...

rt.invoke("agent", "hello", on_event=print)
```

**优点**

- 直接匹配 OCaml 端的形状。`Runtime.invoke` 上的 `?on_chunk`（`lib/core/runtime.ml` 第 336 行）已经是回调参数；FFI 可以直接透传，无需队列。
- FFI 更简单。Python 端没有迭代器状态机、没有哨兵值、没有 `_DONE` 协议。一个回调指针，一个 C 入口点。
- 易于层叠。日志记录器或指标钩子只是通过小封装组合的另一个可调用对象。
- 对 JavaScript 和 Java 转过来的开发者来说很熟悉，他们习惯事件驱动的 API。

**缺点**

- 不符合 Python 风格。Python 开发者首先想到迭代器；回调感觉像 2012 年代的 `tornado.gen.engine`。
- 难以在流式过程中取消。回调无法在没有副作用通道（异常、运行时必须检查的标志）的情况下告诉运行时停止。基于异常的取消很脆弱，因为回调可能在 OCaml fiber 的栈上运行。
- 没有背压。如果回调慢，OCaml 端会阻塞，但调用方无法向上游施加背压，因为他们不控制循环。
- 难以收集结果。调用方必须在闭包捕获的列表中维护自己的缓冲区，当同一个回调被复用时这很丑陋。
- 与 `for` 循环、列表推导和 `asyncio` 的组合要求调用方将回调封装在自己的队列加 generator 适配器中。他们最终会重新实现方案 1。

**适用场景。** 当调用方是已经使用回调风格的非 Python 环境（Electron 宿主、Java 桥接），或者 FFI 简洁性比调用方体验更重要时。

### 方案 3：两者兼有

同时暴露两种接口。generator 内部封装回调。

```python
def invoke(self, ..., on_event: Optional[Callable[[Event], None]] = None) -> None: ...
def invoke_stream(self, ...) -> Iterator[Event]: ...
```

**优点**

- 对使用过 OpenAI SDK（`chat.completions.create` 上的 `stream=True`）和 Anthropic SDK（`client.messages.stream()` 返回上下文管理器）的人来说都很熟悉。
- 没有错误入口。两种风格都可以；调用方选择适合自己的。

**缺点**

- 两个 API 需要测试、文档化和保持同步。v0.5.1 接口很小；仅为风格偏好翻倍是不合理的。
- 回调变体有方案 2 中提到的取消和背压问题。发布它等于认可这些问题。
- 版本风险。如果 generator 演进（per-chunk 元数据、async 变体），回调必须同步演进或增加第二套参数。

**适用场景。** 当项目足够大，存在两种不同的调用方群体（Python 应用开发者加上非 Python 宿主桥接），且维护预算能覆盖两者时。

## 推荐：generator（方案 1）

PAR 的主要 Python 受众是编写 agent 驱动服务的后端工程师。他们期望迭代器，默认使用 `for event in ...`，而且已经用过 OpenAI SDK 的 `stream=True`。方案 1 匹配这种肌肉记忆。

方案 2 作为主要接口被否决，因为它的取消和背压问题是真实存在的，而 FFI 简洁性的收益是一次性成本。方案 3 在 v0.5.1 中被否决，因为维护预算不覆盖两个接口，而且如果有真实调用方需要，在 v0.6 中添加回调式封装也没有阻碍。一个 generator 可以用五行代码封装成回调适配器；反过来则需要本文档指定的完整队列加哨兵机制。

本文档其余部分完整指定方案 1。

## Event 类型

`Event` 是一个冻结数据类联合，镜像 `lib/core/types.ml` 第 509 行的 OCaml `llm_response_chunk` ADT。每个构造器映射到一个 Python 类。字段名完全匹配 OCaml 的记录标签，使 JSON 往返可预测。

```python
from dataclasses import dataclass
from typing import Union

@dataclass(frozen=True)
class TextDelta:
    """A chunk of text from the LLM. Concatenate `text` across deltas."""
    text: str

@dataclass(frozen=True)
class ToolCallStart:
    """The LLM is beginning a tool call. Followed by zero or more ToolCallDelta."""
    tool_call_id: str
    name: str

@dataclass(frozen=True)
class ToolCallDelta:
    """A fragment of the tool call's JSON arguments. Concatenate `args_json`."""
    tool_call_id: str
    args_json: str

@dataclass(frozen=True)
class UsageUpdate:
    """Token usage so far. Emitted at most once per stream, near the end."""
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int

@dataclass(frozen=True)
class Done:
    """The stream is complete. `finish_reason` is one of: stop, tool_calls, length, content_filter, max_iterations."""
    finish_reason: str

Event = Union[TextDelta, ToolCallStart, ToolCallDelta, UsageUpdate, Done]
```

不变量：

- `TextDelta` 事件按序到达。拼接 `text` 以重建完整的 assistant 消息。
- 一个 `ToolCallStart` 后面跟着零个或多个具有相同 `tool_call_id` 的 `ToolCallDelta` 事件。拼接 `args_json` 并将结果解析为 JSON 以恢复工具调用参数。
- `UsageUpdate` 是可选的。OpenAI 不发出它；Anthropic 和 Mock 会。显示 token 用量的调用方必须容忍它的缺失。
- `Done` 总是最后一个事件。generator 在产出它后退出。如果流在没有 `Done` 的情况下结束（网络错误、取消），generator 从 `next()` 抛出 `PARInvokeError`。

## API 签名

```python
from typing import Iterator

def invoke_stream(
    self,
    agent_id: str,
    message: str,
) -> Iterator[Event]: ...
```

说明：

- 方法名承载流式语义。`invoke` 上没有 `stream=True` 标志；想要非流式行为的调用方使用 `invoke`，想要流式的使用 `invoke_stream`。两个方法，两种意图，没有布尔陷阱。
- 返回类型是 `Iterator[Event]`，不是 `List[Event]`。迭代器在 LLM 产出事件时逐个产出。
- 第一次 `next()` 调用启动一个后台守护线程运行 `par_invoke_stream`。如果调用失败，迭代时抛出 `PARInvokeError`。
- v0.5.3：chunk 实时增量到达 — 第一个 token 在 LLM 产出后的毫秒内到达调用方，而非在完整响应完成后。（v0.5.1–v0.5.2 使用缓冲交付；v0.5.3 将 FFI 重新连接到后台线程 + 队列模型。）
- 仅关键字参数的扩展（取消令牌、对话 ID、RAG 选项）将在后续版本中以各自的关键字参数添加。v0.5.3 的签名有意保持最小。

## 增量 chunk 交付（v0.5.3）

`par_invoke_stream` 在后台守护线程中运行。OCaml SSE 解析器在 LLM 产出每个 chunk 时触发 ctypes 回调（`caml_dispatch_chunk_to_c`）。回调将 JSON 编码的 chunk 推入 `queue.Queue`。Python 迭代器的 `__next__` 并发消费队列，因此事件实时交付。

这意味着：
- 第一个 token 在 LLM 产出后的毫秒内到达，而非在完整响应完成后。对于 30 秒的生成，感知延迟从"30 秒黑屏"降低到"首个 token < 1 秒"。
- 后台线程在流的持续时间内持有进程全局的 C `ocaml_lock`。如果调用方提前从迭代器 break，线程会继续运行直到 LLM 流自然完成，在此窗口期间后续的 `par_*` 调用会阻塞。完整注意事项见 `invoke_stream` 文档字符串。
- 缓冲的 JSON 信封（最终响应中的 `"chunks": [...]`）仍然返回以保持向向后兼容 — 直接读取 `parsed["chunks"]` 的调用方不受影响。

## Provider 支持

| Provider | 文本流式 | 工具调用流式 | 用量更新 | 备注 |
|----------|----------|-------------|----------|------|
| `` `Openai `` | 是 | 是 | 否 | OpenAI 在流式期间不发出 token 计数；`UsageUpdate` 事件不会出现。需要用量的调用方必须回退到非流式 `invoke`。 |
| `` `Anthropic `` | 是 | 是 | 是 | 实现 C.2 时请对照 `lib/llm/anthropic_provider.ml` 验证。Anthropic 的流消息包含带 `usage` 块的 `message_delta`。 |
| `` `Mock `` | 是 | 是 | 是 | Mock provider 发出所有五种事件类型。用作流式测试夹具。 |
| `` `Ollama `` | 是 | 未知 | 未知 | 在 v0.5.1 中未验证流式支持。依赖前请先测试。 |

如果 provider 不原生支持流式，运行时回退为发出单个包含完整响应的 `TextDelta` 后跟 `Done`。调用方不应假设 chunk 是小的。

## 使用示例

三个可运行的示例，覆盖你实际需要的模式：基本 token 流、重建调用参数的工具调用流、以及在不泄漏部分输出的前提下捕获 provider 故障的错误处理封装。

### 示例 1：逐 token 打印

最常见的形式。迭代 generator，匹配 `TextDelta` 打印每个到达的片段，当 `Done` 到达时停止。`flush=True` 对终端和管道转发的 UI 很重要；没有它，Python 会缓冲 stdout，流式体验就消失了。

```python
from par_runtime import Runtime, TextDelta, Done

with Runtime(config_json) as rt:
    for event in rt.invoke_stream("agent", "Tell me a joke"):
        if isinstance(event, TextDelta):
            print(event.text, end="", flush=True)
        elif isinstance(event, Done):
            print()  # newline after the final token
            # event.finish_reason is one of: stop, tool_calls, length,
            # content_filter, max_iterations
```

如果你只需要完整消息而不在乎延迟，`"".join(e.text for e in rt.invoke_stream(...) if isinstance(e, TextDelta))` 可以重建它。你失去了流式的好处，但 API 不会强迫你增量消费。

### 示例 2：流式工具调用并重建其参数

LLM provider 将工具调用作为 `ToolCallStart`（调用 ID 和工具名）发送，后跟零个或多个 `ToolCallDelta` 片段，其 `args_json` 字符串拼接起来就是完整的 JSON 参数。按 `tool_call_id` 缓冲片段，然后在流结束时解析拼接结果。

```python
import json
from collections import defaultdict
from par_runtime import (
    Runtime, TextDelta, ToolCallStart, ToolCallDelta, Done,
)

with Runtime(config_json) as rt:
    text_parts = []
    tool_buffers = defaultdict(list)
    tool_names = {}

    for event in rt.invoke_stream("agent", "What's the weather in Tokyo?"):
        if isinstance(event, TextDelta):
            text_parts.append(event.text)
        elif isinstance(event, ToolCallStart):
            tool_names[event.tool_call_id] = event.name
        elif isinstance(event, ToolCallDelta):
            tool_buffers[event.tool_call_id].append(event.args_json)
        elif isinstance(event, Done):
            break

    for tool_call_id, fragments in tool_buffers.items():
        args = json.loads("".join(fragments))
        print(f"Tool call: {tool_names[tool_call_id]}({args})")
```

同样的模式适用于并行工具调用：每个调用有自己的 `tool_call_id`，因此按 id 键控的缓冲区无需竞态条件就能保持它们分离。

### 示例 3：处理错误并干净取消

用 `try/except` 封装迭代器以捕获 provider 故障（网络、认证、内容过滤）和 fiber 错误。从循环中 break 或让 `with` 块退出会运行 generator 的 `finally` 子句，它会 join OCaml fiber 并释放队列。永远不要让异常在没有关闭迭代器的情况下逃逸。

```python
from par_runtime import Runtime, TextDelta, PARError

try:
    with Runtime(config_json) as rt:
        try:
            for event in rt.invoke_stream("agent", "hello"):
                if isinstance(event, TextDelta):
                    print(event.text, end="", flush=True)
        except PARError as e:
            # Provider-side failure surfaced via the FFI: bad model name,
            # rate limit, content filter, etc. Partial output may already
            # have been printed; that is expected for streaming.
            print(f"\n[stream failed: {e}]")
        except KeyboardInterrupt:
            # Ctrl-C during iteration. GeneratorExit fires, the finally
            # block cancels the OCaml fiber, and the runtime shuts down.
            print("\n[cancelled by user]")
            raise
finally:
    # rt.close() runs automatically when the `with` block exits.
    pass
```

`PARError` 覆盖了跨越 FFI 边界的每条错误路径：格式错误的配置、未知的 agent ID、provider HTTP 错误、以及 chunk 回调内部抛出的任何异常。`KeyboardInterrupt` 分支值得显式保留，这样用户发起的取消会干净地记录日志，而不是打印回溯。

## 限制

- **不支持 async/await。** 迭代器是同步的。`async for` 封装是未来候选；它可能是围绕同步迭代器的薄 `asyncio` 适配器，而非单独的代码路径。
- **没有嵌套事件层次结构。** PAR 不在流式事件上发出 LangChain 风格的 `parent_run_id` 或 `run_id` 元数据。如果你需要将流与工具调用或子 agent 调用关联，使用事件总线（`par_event_subscribe`，在 C.2 中连接）获取结构化事件。
- **没有 `invoke_with_rag_streaming`。** RAG 入口（`Runtime.invoke_with_rag`）将在未来版本中获得自己的流式变体。
- **背压是阻塞的。** 如果消费者比生产者慢得多，OCaml fiber 会在 `queue.put` 上阻塞。相对于无界内存增长，这是一个可接受的权衡，但它确实意味着一个挂起的消费者会占用 OCaml fiber 直到流完成或被取消。
- **仅限单消费者。** 迭代器不是广播的。如果多个订阅者需要同一个流，请在应用层扇出（将迭代器封装在你自己的发布-订阅中）。
- **提前 break 会阻塞后续调用（v0.5.3 已知限制）。** 在 `Done` 之前从迭代器 break 会让后台守护线程持有 `ocaml_lock` 直到 LLM 流完成。详见 `invoke_stream` 文档字符串和 CHANGES.md 的"已知限制"。`par_cancel_stream` FFI（在 v0.5.4-beta 中发布）通过标志检查模式缓解了这个问题 — 取消在下一个 chunk 边界（典型 50–300 毫秒）生效，之后 `ocaml_lock` 释放，后续 `par_*` 调用继续执行。

## 实现说明（面向 C.2 和 C.3 维护者）

本节是信息性的。它不定义公共 API；它记录 FFI 桥接应使用的钩子。

- **复用现有的 `?on_chunk` 参数。** `lib/core/runtime.ml` 第 336 行的 `Runtime.invoke` 已经接受 `?on_chunk : (Types.llm_response_chunk -> unit) option`。通过此参数连接 C 回调；不要在 OCaml 端添加新的代码路径。
- **不要通过事件总线路由 chunk。** 事件总线（`Event_bus` 模块）没有流式事件构造器，也不应该添加。流式 chunk 是同步回调，不是发布-订阅事件。将两者混合会将流消费者耦合到事件总线的保留策略。
- **参考消费者实现。** OCaml SDK 的规范 chunk 消费者是 `lib/core/runtime.ml` 第 336 行的 `?on_chunk` 回调连接（被 `Runtime.invoke` 使用），它将 `Text_delta` / `Tool_call_delta`（见 `lib/core/types.ml` 第 509 行的 `llm_response_chunk` ADT）分派到调用方的回调。C.2/C.3 实现应镜像相同的判别逻辑。（之前 `bin/main.ml` 中的 CLI 消费者是历史参考，但该文件在 v0.6.7 中被移除。）
- **新的 C 入口点。** 在 `lib/ffi/par_ffi.h` 和 `lib/ffi/par_ffi.c` 中添加 `par_invoke_stream(par_runtime_t* rt, const char* agent_id, const char* message, par_event_callback cb, void* user_data)`。以 `par_invoke` 和 `lib/ffi/par_ffi.h` 第 64 行现有的 `par_event_callback` typedef 为模型。`user_data` 指针原封不动转发给回调，以便 Python 绑定可以传递其队列引用。
- **现有的 subscribe 桩。** `par_event_subscribe` 在 `lib/ffi/par_ffi.h` 第 64 行声明，在 `lib/ffi/par_ffi.c` 第 336 行有桩实现（返回 `-1`）。它与流式无关，但使用相同的回调形状。连接它是 C.2 的可选项，可能推迟到后续阶段；流式入口点不依赖它。
- **现有的 Python 先例。** `bindings/python/par_runtime/_ffi.py` 第 62 行定义了 `_PYTHON_TOOL_CALLBACK = CFUNCTYPE(c_char_p, c_int, c_char_p)`。为流式回调镜像此模式：定义 `_STREAM_CALLBACK = CFUNCTYPE(None, c_char_p, c_char_p)`（event_type, event_json），在运行时生命周期内将闭包保持在 `self._cb_keepalive` 上，在回调内解析 JSON，并将构造好的 `Event` 推入队列。

## 另请参阅

- [Agent API](agent.md) - `Runtime.invoke`、`agent_config`、`invoke_stream` 镜像的非流式入口
- [概览](overview.md) - SDK 架构和模块映射
- [工作流 API](workflow.md) - 工作流编排；工作流步骤尚不支持流式
- [工具 API](tools.md) - 20 个内置工具，包括类型安全的 bash
