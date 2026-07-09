<!-- language: zh -->

**[English](../tutorials/01-rag-qa-bot.md)** · 简体中文

# 教程 1：构建 RAG 问答机器人

> 遵循 Diataxis 教程形式：边做边学，而非参考手册。
> 需要完整的类型签名时，参阅 [RAG API 参考](../sdk/rag.md)；
> 需要更广泛的环境搭建说明时，参阅 [快速入门](../quickstart.md)。

本教程带你从空目录开始，在大约三十分钟内构建一个可运行的检索增强生成（RAG, Retrieval-Augmented Generation）问答机器人。你将启动一个 PAR 运行时，把文本转成向量（embedding），存入本地索引，然后提问并从索引上下文中获得回答。完成后，你会理解 RAG 管道的四个组成部分，以及 PAR 如何暴露它们。

RAG 让 LLM 基于你自己的文档来回答，而不是依赖模型的参数记忆。做法是：把文本嵌入为向量，存入本地索引，查询时取出与问题最接近的文本块（chunk），将它们作为上下文注入 prompt，再让模型据此作答。PAR 负责这条管道的全部基础设施；你只需要提供文档。

## 你将构建什么

一个 Python 脚本，功能包括：

1. 启动一个带 SQLite 持久化的 PAR 运行时。
2. 将几段短文本嵌入为向量。
3. 将向量存入 PAR 的本地索引。
4. 提出一个问题，获得基于索引上下文的回答。

本教程中的每个代码块都无需 LLM API key 即可运行。在最终回答步骤需要真实 provider 时，代码块会检查 key 是否存在，不存在则优雅跳过。你可以直接复制粘贴并运行每段代码。

## 前置条件

你需要安装并可以导入 Python 绑定。

```bash
pip install par-runtime
python -c "from par_runtime import Runtime; print('ok')"
```

如果第二条命令输出 `ok`，说明环境就绪。如果报 `ImportError`，说明缺少对应平台的 wheel，需要从源码构建：`make install`（参见[快速入门](../quickstart.md)）。

嵌入和索引步骤不需要 OpenAI 或 Anthropic 的 key。key 仅用于最终的检索增强回答步骤，且需要它的代码块在缺失 key 时会优雅降级。

## 第 1 步：启动运行时

PAR 的运行时（Runtime）负责管理持久化层、事件总线（event bus）和 provider 注册表。通过一个 JSON 配置字符串来构造它。配置结构很关键：缺少字段会导致 `PARInitError`，所以下面的代码块是最小可用配置。

```python
import json
from par_runtime import Runtime

def make_config():
    return json.dumps({
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
        "default_quota": {
            "max_concurrent_tasks": 4,
            "max_concurrent_tools_per_agent": 2,
        },
        "shutdown": {
            "drain_timeout": 3.0,
            "cancel_grace_period": 1.0,
            "flush_batch_size": 100,
        },
        "llm_providers": [],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
    })

with Runtime(make_config()) as rt:
    health = rt.health()
    assert health.get("runtime_alive") is True, health
    print("runtime started:", health)
```

运行它。你应该看到 `runtime started: {... 'runtime_alive': True ...}`。

有两点值得注意。第一，`persistence` 的值是 `["Sqlite", ":memory:"]`，这是多态变体（polymorphic variant）`` `Sqlite `` 的元组形式，使用内存数据库。如果传入文件路径如 `"par.db"`，则会持久化到磁盘。第二，`llm_providers` 这里为空，因为这一步只检查运行时能否正常启动。第 4 步会在需要生成回答时挂载真实的 provider。

## 第 2 步：将文本嵌入为向量

Embedding（嵌入）将字符串转换为固定长度的浮点数组。PAR 的向量存储对 embedding 模型没有偏好：它存储你传入的任意浮点向量，按余弦相似度（cosine similarity）排序。运行时的 `embed` 方法用于从支持 chat 和 embedding 的 provider（如 OpenAI）获取这些浮点向量。

下面的代码块会在本地随机端口启动一个小型 OpenAI 兼容 HTTP 服务器，然后把运行时指向它。这正是 PAR 自身测试套件在不消耗 API 额度的情况下测试 embedding 路径的方式。通过真实的 FFI 调用返回真实的向量，无需 API key。

```python
import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from par_runtime import Runtime


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _MockEmbeddings(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            payload = json.loads(body)
        except Exception:
            payload = {}
        inputs = payload.get("input", [])
        if isinstance(inputs, str):
            inputs = [inputs]
        data = [
            {"object": "embedding", "index": i, "embedding": [0.1 * i, 0.2 * i, 0.3]}
            for i in range(len(inputs))
        ]
        body_out = json.dumps(
            {"object": "list", "data": data, "usage": {"prompt_tokens": 5, "total_tokens": 5}}
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_out)))
        self.end_headers()
        self.wfile.write(body_out)


def start_mock_embeddings_server():
    port = _free_port()
    server = HTTPServer(("127.0.0.1", port), _MockEmbeddings)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{port}/v1"


def provider_config(base_url):
    return json.dumps({
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
                "api_key": "sk-mock-not-a-real-key",
                "base_url": base_url,
                "organization": None,
                "embedding_model": None,
            }]]
        ],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
    })


server, base_url = start_mock_embeddings_server()
try:
    with Runtime(provider_config(base_url)) as rt:
        vectors = rt.embed(["PAR is an OCaml runtime", "PAR ships twenty tools"])
        print("embedded %d strings" % len(vectors))
        print("each vector has %d dimensions" % len(vectors[0]))
finally:
    server.shutdown()
```

输出会显示两个向量，每个三维。维度来自 mock 服务器而非真实的 embedding 模型。当你换用 OpenAI 时，`text-embedding-3-small` 模型的维度会跳到 1536，浮点值携带实际的语义信号。但调用方式不变。

有一点值得现在就理清。在 PAR 中，同一个 provider 配置块同时处理 embedding 和 chat。你不需要分开配置。同一条 `[name, [tag, fields]]` 条目既满足 `embed` 调用，也满足 `invoke_with_rag` 中的 chat 步骤。把 embedding 模型名称放在一个地方，让索引和查询都通过它来路由。这是防止 embedding 模型漂移（model drift）最简单的手段——如果你用模型 A 建索引、用模型 B 查询，检索结果会悄然失效。

## 第 3 步：索引文档

有了 embedding 之后，索引只需一次调用。`add_documents` 接受一个字符串列表或字典列表，通过已配置的 provider 将每条记录嵌入为向量，然后插入运行时的本地存储。

```python
import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from par_runtime import Runtime


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _MockEmbeddings(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            payload = json.loads(body)
        except Exception:
            payload = {}
        inputs = payload.get("input", [])
        if isinstance(inputs, str):
            inputs = [inputs]
        data = [
            {"object": "embedding", "index": i, "embedding": [0.1 * i, 0.2 * i, 0.3]}
            for i in range(len(inputs))
        ]
        body_out = json.dumps(
            {"object": "list", "data": data, "usage": {"prompt_tokens": 5, "total_tokens": 5}}
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_out)))
        self.end_headers()
        self.wfile.write(body_out)


def start_mock_embeddings_server():
    port = _free_port()
    server = HTTPServer(("127.0.0.1", port), _MockEmbeddings)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{port}/v1"


def provider_config(base_url):
    return json.dumps({
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
                "api_key": "sk-mock-not-a-real-key",
                "base_url": base_url,
                "organization": None,
                "embedding_model": None,
            }]]
        ],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
    })


server, base_url = start_mock_embeddings_server()
try:
    with Runtime(provider_config(base_url)) as rt:
        documents = [
            "PAR is an OCaml agent runtime built on Eio structured concurrency.",
            "PAR's vector store uses sqlite-vec under the hood and is embedding-agnostic.",
            "PAR ships twenty built-in tools, including a type-safe bash tool.",
            "The ReAct loop bounds iterations and runs middleware at every boundary.",
        ]
        added = rt.add_documents(documents)
        print("add_documents returned:", added)
finally:
    server.shutdown()
```

`add_documents` 的返回值是 FFI 层传递回来的计数。使用 mock 服务器时显示 `0`；使用真实 provider 时则反映实际索引的数量。把这次调用视为"文档已交付"的确认依据，而通过检索查询来验证质量，而不是检查计数。

当文档数量较多时，应传入带显式 id 和 metadata 的字典。id 允许在重新索引时原地更新（upsert）而非重复插入，metadata 会附在每条搜索结果上，方便 UI 展示来源。在 embedding 之前对长文档进行分块（chunking）是一个独立话题，参见 [RAG API 参考](../sdk/rag.md) 中的 `Chunking` 模块和重新索引规则。

## 第 4 步：提问并获得有依据的回答

这是四个部分组合在一起的环节。`invoke_with_rag` 会嵌入你的查询，检索 top-k 个文本块，将它们注入系统提示词，然后调用 agent。一次调用搞定。

Agent 需要一个 chat provider 来生成最终回答。下面的代码块读取你的 `OPENAI_API_KEY`，如果存在就对真实 API 发起完整的检索增强查询。如果 key 缺失，会打印清晰的跳过提示并以 exit 0 退出，确保代码段在任何环境下都能干净运行。这是教程中依赖付费 provider 时的诚实写法。

```python
import json
import os
import sys
from par_runtime import Runtime, PARError

api_key = os.environ.get("OPENAI_API_KEY")
if not api_key:
    print("skipped: set OPENAI_API_KEY to run the grounded query")
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
    "id": "rag_agent",
    "system_prompt": "Answer the question using only the provided context.",
    "model": {"provider": "openai", "model_name": "gpt-4o-mini"},
    "max_iterations": 1,
    "tools": [],
})

with Runtime(config) as rt:
    rt.register_agent(agent)
    rt.add_documents([
        "PAR is an OCaml agent runtime built on Eio structured concurrency.",
        "PAR's vector store uses sqlite-vec and is embedding-agnostic.",
        "PAR ships twenty built-in tools, including a type-safe bash tool.",
    ])
    try:
        raw = rt.invoke_with_rag("rag_agent", "How many built-in tools does PAR ship?", k=2)
        parsed = json.loads(raw)
        print("answer:", parsed)
    except PARError as exc:
        print("query failed:", exc)
```

设置 key 后运行。使用真实 provider 时，回答基于索引上下文而非模型记忆。`k=2` 参数检索最相似的两个文本块。调大可以获得更宽泛的上下文，调小则更聚焦。默认值是 `k=4`。

与索引代码块相比，有三处变化。第一，provider 现在指向真实的 OpenAI base URL（`base_url: None` 表示使用 provider 默认地址）。第二，注册了一个 agent，因为 `invoke_with_rag` 像普通 `Runtime.invoke` 一样，通过 agent 路由增强后的 prompt。第三，返回值是一个 JSON 字符串，结构与其他 invoke 结果相同，解析方式也一样。

## 故障排查

| 症状 | 原因 | 解决方案 |
|---|---|---|
| `PARInitError: Failed to initialize PAR runtime` | 配置中缺少必填字段或字段类型错误。 | 对照第 1 步的配置块。`event_bus`、`default_quota` 和 `shutdown` 都需要完整的嵌套字段。 |
| `embed` 报 `Embedding_unsupported` | 你指向了一个不支持 embedding API 的 provider（目前只有 Anthropic）。 | 嵌入步骤请使用 OpenAI、Ollama 或 Mock。Anthropic 仍可用于 `invoke_with_rag` 中的 chat 步骤。 |
| `External_failure` 提到 `vec0.so` 或 `sqlite-vec` | sqlite-vec 扩展加载失败，通常是平台不匹配或路径缺失。 | Python wheel 会自动解析扩展路径。如果从源码构建，请为你的平台传入正确的 `vec_extension_path`。 |
| 检索返回垃圾内容或空结果 | Embedding 模型漂移。用一个模型建索引，用另一个模型查询，或者改变了维度。 | 用同一个模型重新索引所有文档。参见 [RAG API 参考](../sdk/rag.md) 中的持久化和重新索引。 |
| `invoke_with_rag` 对手写 mock 返回 `Internal` Yojson 错误 | Mock 的 chat completion 响应缺少 provider 解析器期望的字段。 | 回答步骤请使用真实 provider，或者参照真实的 OpenAI chat completion 载荷来构建 mock。 |
| 大 PDF 内存溢出 | 将整篇文档作为一个向量嵌入，信号被平均掉且 prompt 膨胀。 | 先用 `Chunking.chunk_recursive` 分块，再对每个块进行嵌入和索引。 |

## 下一步

你现在拥有了完整的 RAG 循环：嵌入、索引、检索、回答。两个自然的后续方向：

- 在[教程 2：流式 UI](02-streaming-ui.md) 中查看 token 逐个生成的过程。回答你问题的同一个运行时，可以逐 token 流式输出回复。
- 阅读 [RAG API 参考](../sdk/rag.md) 了解分块策略、OCaml `Vector_store` 和 `Chunking` 模块签名，以及重新索引规则。

另有两个教程将在依赖就绪后发布。多 provider 故障转移（[教程 4](../../tutorials/04-multi-provider-fallback.md)）展示在 OpenAI 触发速率限制时自动切换到 Anthropic。会话恢复（[教程 5](../../tutorials/05-session-resume.md)）展示对话在进程重启后恢复。两者目前均为占位。
