# Python API
[English](https://github.com/jcz2020/par/blob/main/sdk/python.md) · **简体中文**

> v0.18.0-beta 新增。类型化模型与 `AsyncRuntime` 都是增量能力：旧的 JSON 字符串 API 继续可用，直到 v1.0 才移除。

`par_runtime` 是 PAR 的 Python 界面。它提供类型化请求/响应模型、同步 `Runtime` 和 asyncio `AsyncRuntime`，三者共用同一个 C bridge 与同一个 OCaml runtime。

```bash
pip install par-runtime
```

## 快速开始

```python
from par_runtime import AgentConfig, ModelConfig, Runtime, RuntimeConfig

agent = AgentConfig(
    id="assistant",
    system_prompt="You are helpful.",
    model=ModelConfig(
        provider="openai",
        model_name="gpt-4o",
        temperature=0.2,
    ),
)

with Runtime(RuntimeConfig()) as rt:
    rt.register_agent(agent)
    result = rt.invoke_result("assistant", "hello")
    print(result.text, result.usage.total_tokens)
```

`RuntimeConfig()` 默认使用内存 SQLite。需要跨进程保留会话时，指向一个文件：

```python
config = RuntimeConfig(persistence=Sqlite("par.db"))
```

LLM provider 仍使用 runtime 原本接受的 JSON 结构；类型化模型覆盖的是请求路径，不包括 provider 密钥：

```python
config = RuntimeConfig(
    llm_providers=[[
        "default",
        ["Openai", {
            "api_key": "sk-...",
            "base_url": "https://api.openai.com/v1",
            "organization": None,
            "embedding_model": None,
        }],
    ]],
)
```

## 类型化模型

所有模型位于 `par_runtime.models`，并从 `par_runtime` 重新导出。每个模型都有 `to_json()`（返回 JSON 字符串）与 `from_json()`（接受字符串或 dict），因此类型化对象随时可以按旧格式持久化或传输。

| 模型 | 用途 | 主要默认值 |
|---|---|---|
| `RuntimeConfig` | Runtime 配置 | `persistence=Sqlite(":memory:")`、`parallel_tool_execution=True` |
| `Sqlite` | 持久化后端 | `path=":memory:"` |
| `ModelConfig` | 模型与采样参数 | `provider="openai"`、`temperature=0.7` |
| `ToolSpec` | 工具描述符 | `input_schema={"type": "object"}` |
| `AgentConfig` | Agent 定义 | `tools=[]`、`max_iterations=1_000_000` |
| `InvokeResult` | 解码后的 invoke 信封 | `finish_reason="stop"` |
| `Usage` | Token 统计 | 全部计数为 `0` |
| `ToolCall` | 模型请求的一次工具调用 | — |
| `Error` | 错误信封 | — |

这些默认值不是装饰。它们与两个真正消费 payload 的解码器一致：`Runtime._normalize_config` 和 `lib/ffi/par_capi.ml`。测试会断言 `RuntimeConfig().to_json()` 规范化后的 OCaml 配置，与手写的最小 JSON 对象完全一致。

`RuntimeConfig` 还接受 `mcp_sampling=MCPSampling(model=..., max_tokens=...,
max_requests_per_invoke=..., timeout=...)`；默认 `None`（禁用）。参见 [MCP Client](mcp.md)。

四个尚无类型化表面的配置块（`event_bus`、`default_quota`、`shutdown`、`eval_limits`）接受 dict 覆盖，并与默认值合并：

```python
config = RuntimeConfig(default_quota={"max_concurrent_tasks": 2})
```

## 方法 `invoke_result()` 与已弃用的 `invoke()`

`Runtime.invoke_result()` 返回 `InvokeResult`：

```python
result = rt.invoke_result("assistant", "hello")
result.text            # str | None
result.tool_calls      # list[ToolCall]
result.finish_reason   # "stop" | "tool_calls" | "max_tokens" | "content_filter"
result.usage           # Usage
result.model           # provider 返回的 model id
```

`Runtime.invoke()` 仍返回原始 JSON 信封（`{"status": "ok", "content": {...}}`），并发出 `DeprecationWarning`。它将在 v1.0 移除；新代码请使用 `invoke_result()`。

## 异步

`AsyncRuntime` 包装同一个 runtime handle。启动是惰性的；进入异步上下文时，OCaml runtime 在事件循环线程上初始化，C bridge 要求如此。

```python
import asyncio
from par_runtime import AsyncRuntime, TextDelta

async def main():
    async with AsyncRuntime(RuntimeConfig()) as rt:
        await rt.register_agent(agent)
        result = await rt.invoke("assistant", "hello")
        print(result.text)

        async for event in rt.stream("assistant", "hello"):
            if isinstance(event, TextDelta):
                print(event.text, end="")

asyncio.run(main())
```

- `await rt.invoke(...)` 使用 handle API（`invoke_start` / `invoke_poll` / `invoke_cancel`）。取消 task 会设置 runtime 的取消标志；运行在下一个取消点停止，后台 drain 会消费 handle，避免取消的调用泄漏槽位。
- `rt.stream(...)` 产生与同步 `Runtime.invoke_stream` 相同的 `TextDelta` / `ToolCallDelta` 等事件。跳出 `async for` 会取消并释放 stream handle。
- 事件循环最多被一次短 C poll 阻塞 10ms。runtime 仍运行自己的 Eio domain；Python 只负责调度轮询。
- `rt.sync` 暴露底层 `Runtime`，用于尚未包装的方法。

## 从 JSON 字符串迁移

旧写法继续有效，因此可以增量迁移：

```python
# 迁移前
config = json.dumps({"persistence": {"tag": "sqlite", "contents": ":memory:"}})
with Runtime(config) as rt:
    rt.register_agent(json.dumps({
        "id": "assistant",
        "system_prompt": "You are helpful.",
        "model": {"provider": "openai", "model_name": "gpt-4o", "temperature": 0.2},
        "tools": [],
    }))
    raw = rt.invoke("assistant", "hello")

# 迁移后
with Runtime(RuntimeConfig()) as rt:
    rt.register_agent(AgentConfig(
        id="assistant",
        system_prompt="You are helpful.",
        model=ModelConfig(provider="openai", model_name="gpt-4o",
                          temperature=0.2),
    ))
    result = rt.invoke_result("assistant", "hello")
```

`Runtime(...)` 与 `register_agent(...)` 接受类型化模型、dict 或 JSON 字符串，三种形式产生相同的 runtime 行为。

## 类型检查

包内置 `py.typed`，并在 CI 中通过 `mypy --strict par_runtime`。Python 3.10+ 用户可获得上表所有字段的补全。

## 另请参阅

- [Agent API](agent.md) -- OCaml 表面与 wire-level 行为
- [Streaming API](streaming.md) -- 事件类型与取消语义
- [Persistence API](persistence.md) -- SQLite schema 与 scope
