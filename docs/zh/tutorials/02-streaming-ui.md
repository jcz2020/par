<!-- language: zh -->
**[English](../tutorials/02-streaming-ui.md)** · 简体中文

# 教程 2：将 Token 流式输出到 TTY 终端界面

> 本教程遵循 Diataxis 教程形式：边做边学。
> 配合 [Streaming API 参考](../sdk/streaming.md) 阅读，可获取完整的事件契约、线程模型和背压说明。

Token 流式输出把感知延迟从"等八秒，然后一股脑吐出五百字"变成了"两百毫秒出第一个 token，然后稳定持续输出"。本教程教你如何消费 PAR 的 `invoke_stream` 生成器，区分不同事件类型，用彩色 ANSI 转义码渲染到终端，以及处理用户按下 Ctrl-C 时不泄漏底层流。

你将构建聊天式 REPL 所需的渲染层：一个读取事件、重建助手消息、区分工具调用与普通文本、并在中断时干净退出的循环。所有代码块无需 LLM API key 即可运行。讲解事件处理和渲染的代码块不需要任何 provider。最后一个接入实时流的代码块会在缺少 key 时自动跳过。

## 你将构建什么

一个小型 Python 程序，功能包括：

1. 遍历 PAR 从 `invoke_stream` 返回的流生成器。
2. 区分 `TextDelta`、`ToolCallStart`、`ToolCallDelta`、`UsageUpdate` 和 `Done` 五种事件并分别处理。
3. 用不同的 ANSI 颜色渲染助手文本、工具调用和用量信息。
4. 捕获 `KeyboardInterrupt`，使 Ctrl-C 能干净退出循环而不打印堆栈跟踪。
5. 在有 API key 时接入实时 provider。

事件词表由 OCaml 类型 `Types.llm_response_chunk` 定义，Python 绑定将其映射为 frozen dataclass 联合类型。学会这五种类型后，你编写的每个流式消费者都遵循同样的模式。

## 前置条件

Python 绑定可正常导入。

```bash
pip install par-runtime
python -c "from par_runtime import Runtime, TextDelta, Done; print('ok')"
```

如果输出 `ok`，继续阅读。前四个步骤不需要 API key。步骤 5 读取 `OPENAI_API_KEY`，缺失时会跳过。

## 步骤 1：认识五种事件类型

`invoke_stream` 产出的每个值都是以下五种 frozen dataclass 之一。它们的名称与 OCaml 构造器一一对应，保证 JSON 序列化/反序列化行为可预测。

```python
from par_runtime import (
    TextDelta,
    ToolCallStart,
    ToolCallDelta,
    UsageUpdate,
    Done,
)

# 助手文本片段。跨 delta 拼接 `text` 即可重建完整消息。
assert TextDelta(text="hel").text == "hel"

# 模型开始发起工具调用。id 将后续携带参数的 delta 串联起来。
assert ToolCallStart(tool_call_id="tc1", name="get_weather").name == "get_weather"

# 工具调用 JSON 参数的片段。按 tool_call_id 缓冲，流结束后解析拼接结果。
assert ToolCallDelta(tool_call_id="tc1", args_json='{"city":').args_json == '{"city":'

# 可选的 token 用量信息。OpenAI 在流式输出中不发送；Anthropic 和 Mock 会发送。
# 展示用量的代码必须容忍其缺失。
assert UsageUpdate(prompt_tokens=5, completion_tokens=10, total_tokens=15).total_tokens == 15

# 始终是最后一个事件。finish_reason 取值为 stop、tool_calls、
# length、content_filter、max_iterations 之一。
assert Done(finish_reason="stop").finish_reason == "stop"

print("all five event types understood")
```

两个值得牢记的不变量。第一，`TextDelta` 事件按顺序到达，因此拼接 `text` 可以精确重建助手消息。第二，`Done` 事件始终是最后一个。如果流在没有 `Done` 的情况下结束，生成器会抛出异常，这是网络故障或取消操作的体现方式。

## 步骤 2：手动解码流

在消费实时流之前，先学习按绑定的方式解码 chunk。`_decode_event` 辅助函数将 OCaml 端发出的 JSON 格式转换为上面的 dataclass。直接调用它正是 PAR 自身测试套件检查所有构造器的方式，无需启动 provider。

OCaml 编码器将 polymorphic variants 输出为 `[Constructor, {fields}]` 格式。解码器同时接受这种格式和较新的 `{"tag": ...}` 格式，所以下面的代码具有前向兼容性。

```python
from par_runtime import TextDelta, ToolCallStart, ToolCallDelta, UsageUpdate, Done
from par_runtime.runtime import _decode_event

# FFI 传递的格式：[Constructor, {fields}]。
delta = _decode_event(["Text_delta", {"text": "hello"}])
assert isinstance(delta, TextDelta) and delta.text == "hello"

start = _decode_event(["Tool_call_start", {"tool_call_id": "tc1", "name": "get_weather"}])
assert isinstance(start, ToolCallStart) and start.name == "get_weather"

frag = _decode_event(["Tool_call_delta", {"tool_call_id": "tc1", "args_json": '{"city":"Tokyo"}'}])
assert isinstance(frag, ToolCallDelta) and frag.args_json == '{"city":"Tokyo"}'

usage = _decode_event(["Usage_update", {
    "prompt_tokens": 5, "completion_tokens": 10, "total_tokens": 15}])
assert isinstance(usage, UsageUpdate)
assert (usage.prompt_tokens, usage.completion_tokens, usage.total_tokens) == (5, 10, 15)

# finish_reason 以单元素 polymorphic variant 列表的形式到达，
# 被规范化为小写字符串。
done = _decode_event(["Done", {"finish_reason": ["Tool_calls"]}])
assert isinstance(done, Done) and done.finish_reason == "tool_calls"

print("decoded all five variants")
```

这就是事件处理的核心。你编写的每个流式消费者都是一个遍历这些解码事件的循环，再加上一两个缓冲区。

## 步骤 3：从片段重建工具调用

一个工具调用到达时，先是一个 `ToolCallStart`，随后是零个或多个 `ToolCallDelta` 事件，它们共享同一个 `tool_call_id`。参数 JSON 分片到达。按 id 缓冲这些片段，在结束时解析拼接结果。

这种模式是纯 Python 实现，不需要 provider，并且天然支持并行工具调用：每次调用有自己的 id，因此用一个以 id 为键的字典即可区分它们。

```python
import json
from collections import defaultdict

# 模拟 provider 发出的事件序列。每个元组为 (kind, call_id, name_or_text, args_or_reason)。
# 位置设计使得一次解包即可匹配下方的分支逻辑。
events = [
    ("ToolCallStart", "tc1", "get_weather", None),
    ("ToolCallDelta", "tc1", None, '{"city":'),
    ("ToolCallDelta", "tc1", None, '"Tokyo","units":"c"}'),
    ("TextDelta", None, "Looking up the weather in Tokyo.", None),
    ("Done", None, None, "tool_calls"),
]

tool_names = {}
tool_args = defaultdict(list)
text_parts = []
finish = None

for kind, call_id, name_or_text, args_or_reason in events:
    if kind == "ToolCallStart":
        tool_names[call_id] = name_or_text
    elif kind == "ToolCallDelta":
        tool_args[call_id].append(args_or_reason)
    elif kind == "TextDelta":
        text_parts.append(name_or_text)
    elif kind == "Done":
        finish = args_or_reason

print("assistant:", "".join(text_parts))
for call_id, fragments in tool_args.items():
    args = json.loads("".join(fragments))
    print("tool call: %s(%s)" % (tool_names[call_id], args))
print("finish_reason:", finish)
```

输出会显示助手文本、重建的工具调用以及结束原因。在实时流中，你会把解析后的参数交给工具注册表进行分发。缓冲逻辑本身不需要改动。

## 步骤 4：用 ANSI 颜色渲染

终端聊天界面通过颜色区分不同角色。助手用一种颜色，用户用另一种，工具输出用第三种。下面的代码块是一个独立的渲染器，可以直接嵌入 REPL 循环。它使用模拟事件运行，无需 provider 即可看到着色效果。

如果你的终端不支持 ANSI 转义码，文本内容依然可读。颜色代码是附加的，不改变结构。

```python
ASSISTANT = "\033[36m"  # cyan
TOOL = "\033[33m"       # yellow
USAGE = "\033[2m"       # dim
RESET = "\033[0m"

events = [
    ("TextDelta", "PAR is an OCaml agent runtime."),
    ("TextDelta", " It uses Eio for structured concurrency."),
    ("Usage", "prompt=12 completion=9 total=21"),
    ("Done", "stop"),
]

print(ASSISTANT + "assistant: " + RESET, end="", flush=True)
for kind, payload in events:
    if kind == "TextDelta":
        print(ASSISTANT + payload + RESET, end="", flush=True)
    elif kind == "Usage":
        print("\n" + USAGE + "[usage] " + payload + RESET, end="", flush=True)
    elif kind == "Done":
        print("\n" + USAGE + "[done] finish=" + payload + RESET)
print("rendered")
```

`flush=True` 很关键。不加的话 Python 会缓冲 stdout，流式体验就没了，完全违背初衷。用 `cat` 管道运行脚本会看到最后一次性输出；加上 flush 后每个 token 在生产者发出时立即显示。

## 步骤 5：处理 Ctrl-C 而不打印堆栈跟踪

用户按下 Ctrl-C 时期望干净退出，而不是看到一堆堆栈跟踪。在循环外捕获 `KeyboardInterrupt`，打印换行符，让生成器的 `finally` 子句关闭后台线程。以下控制流是你在任何流式 REPL 中都需要的模式。

这个代码块使用假的迭代器运行，无需 provider。在步骤 6 中将其替换为 `rt.invoke_stream(...)` 即可无缝迁移。

```python
class _FakeStream:
    """Mimics invoke_stream's iterator protocol for the interrupt demo."""

    def __init__(self, tokens, interrupt_at=None):
        # interrupt_at: index at which to raise KeyboardInterrupt, or None.
        self._tokens = list(tokens)
        self._interrupt_at = interrupt_at
        self._i = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self._interrupt_at is not None and self._i == self._interrupt_at:
            raise KeyboardInterrupt
        if not self._tokens:
            raise StopIteration
        self._i += 1
        return ("TextDelta", self._tokens.pop(0))


def consume(stream):
    collected = []
    try:
        for kind, payload in stream:
            if kind == "TextDelta":
                collected.append(payload)
    except KeyboardInterrupt:
        # 真正的 Ctrl-C 会进入这里。在实时流中，生成器的 finally
        # 子句（for 循环退出时执行）会 join 后台线程。
        # 打印干净的换行符然后返回；不要 re-raise，
        # 调用方看到的应该是干净退出而非堆栈跟踪。
        print("[cancelled by user]")
        return collected
    return collected


# 正常运行：收集所有 token。
print("normal run:", "".join(consume(_FakeStream(["Hello", ", ", "world"]))))

# 中断运行：流在索引 1 处抛出 KeyboardInterrupt，
# consume() 捕获它并干净地返回已收集的部分缓冲区。
print("interrupted:", "".join(consume(_FakeStream(["first", "second", "third"], interrupt_at=1))))
print("interrupt trap works")
```

要点：把 `try/except KeyboardInterrupt` 紧紧包裹在循环外，清理工作放在生成器的 `finally` 中，永远不要让异常逃离而没有关闭迭代器。PAR 的 `invoke_stream` 文档字符串详细说明了 v0.5.3 的已知限制：提前中断会导致后台守护线程持有运行时锁，直到 LLM 流自然完成。v0.5.4-beta 引入的 `par_cancel_stream` FFI 可以在 chunk 间隔内（典型值约 50~300 ms）中断进行中的流；调用 `reader.cancel()`（或让 reader 超出作用域）即可发出取消信号并释放运行时锁，无需依赖硬中断。

## 步骤 6：接入实时流

前面的步骤都是准备工作。这个代码块点亮真正的实时流。它读取 `OPENAI_API_KEY`，存在时注册一个 agent、打开生成器、逐 token 打印输出。key 缺失时打印明确的跳过信息并以退出码 0 退出，保证代码片段在任何环境下都能干净运行。

```python
import json
import os
import sys
from par_runtime import Runtime, TextDelta, Done, PARError

api_key = os.environ.get("OPENAI_API_KEY")
if not api_key:
    print("skipped: set OPENAI_API_KEY to run the live stream")
    sys.exit(0)

config = json.dumps({
    "persistence": ["Sqlite", ":memory:"],
    "event_bus": {
        "buffer_capacity": 10,
        "delivery": {
            "max_delivery_attempts": 3,
            "initial_retry_delay": 0.1,
            "retry_backoff": ["Fixed", 0.5],
            "delivery_timeout": 5.0,
        },
        "dlq_enabled": False,
        "critical_event_types": [],
    },
    "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2},
    "shutdown": {"drain_timeout": 3.0, "cancel_grace_period": 1.0, "flush_batch_size": 100},
    "llm_providers": [
        ["default", ["Openai", {
            "api_key": api_key,
            "base_url": None,
            "organization": None,
            "embedding_model": None,
        }]]
    ],
    "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
    "parallel_tool_execution": True,
})

agent = json.dumps({
    "id": "stream_agent",
    "system_prompt": "You are a concise assistant.",
    "model": {"provider": "openai", "model_name": "gpt-4o-mini"},
    "max_iterations": 1,
    "tools": [],
})

with Runtime(config) as rt:
    rt.register_agent(agent)
    try:
        for event in rt.invoke_stream("stream_agent", "Explain structured concurrency in one sentence."):
            if isinstance(event, TextDelta):
                print(event.text, end="", flush=True)
            elif isinstance(event, Done):
                print()  # 最后一个 token 后换行
    except PARError as exc:
        print("\n[stream failed: %s]" % exc, file=sys.stderr)
    except KeyboardInterrupt:
        print("\n[cancelled by user]", file=sys.stderr)
```

设置 key 后运行。第一个 token 在模型产出后几毫秒内到达。这就是 v0.5.3 增量交付模型的实际效果：OCaml SSE 解析器对每个 chunk 触发回调，回调将数据推入队列，Python 迭代器并发消费队列。感知延迟从一片空白变成了稳定的持续输出。

## 故障排查

| 症状 | 原因 | 解决方案 |
|------|------|---------|
| Token 全部一次性出现，而非逐个输出 | Python 在缓冲 stdout | 在循环内的每个 `print` 调用中添加 `flush=True`，参见步骤 4 |
| `next()` 抛出 `PARInvokeError` | Provider 拒绝了请求，或 agent id 不存在 | 用 `try/except PARError` 包裹迭代，错误消息中包含 provider 的详细信息 |
| 提前 `break` 后流挂起 | v0.5.3 已知限制：后台守护线程持有运行时锁直到 LLM 流完成 | 让流自然完成，或设置 provider 级别的超时。v0.5.4+ 引入 `par_cancel_stream` FFI 可在 chunk 间隔内中断 |
| `UsageUpdate` 始终不出现 | 你正在使用 OpenAI，它在流式输出中不发送 token 计数 | 改用非流式的 `invoke` 获取精确用量，或根据观察到的 token 数自行计算 |
| 退出时出现守护线程警告 | 解释器退出时运行时的后台线程尚未结束 | 使用 `with Runtime(...) as rt:` 块，确保 `rt.close()` 在进程结束前执行 |

## 下一步

你现在可以消费流、渲染流并干净地关闭它。接下来有两条线可以探索。

- 在 [教程 1：RAG 问答机器人](01-rag-qa-bot.md) 中结合流式输出与检索。那里基于回答的调用在未来版本中会有流式对应版本；你刚学会的事件词表将原样复用。
- 阅读 [Streaming API 参考](../sdk/streaming.md)，了解线程模型、PAR 在确定生成器形态前考虑的三种设计替代方案，以及背压策略。

当 skill 作为 CLI 功能落地后，后续教程会展示一个包装流式工具的 skill。它在 skill CLI 工作完成后发布，因此上面的目录索引尚未链接到它。
