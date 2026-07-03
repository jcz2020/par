<!-- language: zh -->

[English](../../howto/rag-pipeline.md) · **简体中文**

# 构建 RAG 管道

> **注意（v0.6.7）：** 本指南中的 `par config` 引用是历史遗留（CLI 已移除）。SDK 等价用法见 [RAG 参考文档](../sdk/rag.md)——推荐入口是 `Runtime.invoke_with_rag`（Python/OCaml）或 [par-code](https://github.com/jcz2020/par-code) 交互式 agent。

> v0.5.2 新增。兑现 v0.5.1-ROADMAP B.6 关于可运行 RAG how-to 的承诺。

# How-to：构建基本 RAG 管道

本指南通过三个可运行的 Python 程序，演示如何使用 PAR 的检索增强生成（RAG）管道将 LLM 回答建立在你自己的文本之上。你将嵌入文本、存入 runtime 的向量索引，然后提出答案来自该文本（而非模型训练数据）的问题。每个示例都运行在本地 mock 服务器上，无需 API 密钥和网络访问。

如果你想了解设计背后的*原理*（embedding 无关存储、sqlite-vec、三阶段检索管道），请先阅读 [RAG 架构](../explanation/rag-architecture.md)。如果你想查看函数签名，请阅读 [RAG API 参考](../sdk/rag.md)。本页是*操作指南*：复制代码、运行、修改。

## 你将构建什么

三个程序，范围递增：

1. **短文本问答。** 嵌入一段文字，提一个问题，得到一个有依据的回答。约 50 行代码。展示最小可行管道：`embed`、`add_documents`、`invoke_with_rag`。
2. **长文档索引。** 拿一篇多段落文档，切分成重叠的 chunk，为每个 chunk 索引其位置元数据，然后跨所有 chunk 查询。约 80 行代码。展示分块和逐 chunk 检索。
3. **多文档语料。** 索引多个不同文档，每个带元数据（标题、章节、来源），跨整个语料查询，检查 runtime 返回了哪些文档。约 100 行代码。展示真实应用使用的多文档模式。

完成后你将拥有构建文档搜索机器人、个人笔记助手或任何需要模型推理你控制的文本的系统的基础组件。

## 前置条件

你需要安装 PAR Python 绑定：

```bash
pip install par-runtime
```

这会拉取一个打包了 OCaml 共享库的 wheel。无需 OCaml 工具链、编译器或单独的二进制文件。v0.5.2 支持 Linux x86_64 和 macOS arm64。

你还需要 Python 3.9 或更新版本。示例只使用标准库加 `par_runtime`，无其他依赖。

## Mock 服务器模式

PAR runtime 的 provider 配置中没有 `Mock` 变体。四种 provider 变体是 `Openai`、`Anthropic`、`Ollama` 和 `Custom`（见 `lib/core/types.ml`）。要在没有 OpenAI 密钥的情况下运行这些示例，我们将一个 `Openai` provider 指向一个实现了 OpenAI `/v1/embeddings` 和 `/v1/chat/completions` 协议的本地小型 HTTP 服务器。这与 PAR 测试套件在 `bindings/python/tests/test_rag_e2e.py` 中使用的模式相同，也是在没有网络调用的情况下完整执行 embed、index、retrieve 和 invoke 循环的最真实方式。

下面每个示例都假设这个辅助文件在 import 路径上。将其保存为示例脚本旁边的 `mock_server.py`。

```python
# mock_server.py
"""RAG how-to 示例用的小型 OpenAI 兼容 mock。

返回确定性 embeddings 和预设的 chat completion，使完整 RAG 循环
无需 API 密钥即可运行。不适用于生产环境。"""
import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            payload = json.loads(body)
        except Exception:
            self.send_response(400); self.end_headers()
            self.wfile.write(b'{"error":"bad json"}'); return

        if self.path.endswith("/embeddings"):
            inputs = payload.get("input", [])
            if isinstance(inputs, str):
                inputs = [inputs]
            # 确定性伪 embedding：将文本哈希为小向量。
            # 足以让余弦相似度将完全匹配排在最高；
            # 不是真正的 embedding 模型。
            data = []
            for i, text in enumerate(inputs):
                h = sum(ord(c) for c in text)
                vec = [((h >> k) & 1) * 1.0 for k in range(8)]
                data.append({"object": "embedding", "index": i,
                             "embedding": vec})
            resp = {"object": "list", "data": data,
                    "model": "text-embedding-3-small",
                    "usage": {"prompt_tokens": 5, "total_tokens": 5}}
        elif self.path.endswith("/chat/completions"):
            # 回显检索到的上下文，以便我们可以看到 RAG 生效了。
            msgs = payload.get("messages", [])
            sys_prompt = next((m.get("content", "") for m in msgs
                               if m.get("role") == "system"), "")
            user_msg = next((m.get("content", "") for m in msgs
                             if m.get("role") == "user"), "")
            answer = (f"[mock answer grounded in "
                      f"{len(sys_prompt)} chars of context] "
                      f"Question was: {user_msg[:60]}")
            resp = {"id": "chatcmpl-mock", "object": "chat.completion",
                    "choices": [{"index": 0, "message":
                        {"role": "assistant", "content": answer},
                        "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 10,
                              "total_tokens": 20}}
        else:
            self.send_response(404); self.end_headers(); return

        body_json = json.dumps(resp).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_json)))
        self.end_headers()
        self.wfile.write(body_json)

    def log_message(self, *args):
        pass  # 静默


def start_mock_server():
    port = _free_port()
    server = HTTPServer(("127.0.0.1", port), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{port}/v1"
```

共享的配置构建器让三个示例保持简短。provider 条目是一个 `[agent_id, ["Openai", {fields}]]` 对，匹配 OCaml 的 `llm_provider_config` 变体。`embedding_model` 字段为 `None`，因为 mock 会忽略它。

```python
# shared.py
import json
from mock_server import start_mock_server

MOCK_SERVER, MOCK_BASE_URL = start_mock_server()


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
            "drain_timeout": 5.0,
            "cancel_grace_period": 2.0,
            "flush_batch_size": 100,
        },
        "llm_providers": [
            ["rag_agent", ["Openai", {
                "api_key": "sk-mock-test-key",
                "base_url": MOCK_BASE_URL,
                "organization": None,
                "embedding_model": None,
            }]],
        ],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
        "event_retention_seconds": 604800.0,
    })


def make_agent_config():
    return json.dumps({
        "id": "rag_agent",
        "system_prompt": "Answer using only the provided context.",
        "model": {
            "provider": "openai",
            "model_name": "gpt-4",
            "temperature": 0.2,
        },
        "max_iterations": 1,
        "tools": [],
    })
```

runtime 的 Python 包装器会用安全默认值填充缺失字段，因此你不必列出每个配置键。`llm_providers` 列表是 RAG 的关键：它将 `rag_agent` 连接到 mock 端点并开启 embedding 支持。

## 示例 1：短文本问答

最小的完整管道。嵌入一段文字，交给 runtime，提一个问题。三次调用完成所有工作：`embed`、`add_documents`、`invoke_with_rag`。

```python
# example1_short_text.py
"""示例 1：短文本问答。嵌入一段文字，提一个问题。"""
from shared import make_config, make_agent_config
from par_runtime import Runtime, PARError

PARAGRAPH = (
    "PAR is a programmable agent runtime written in OCaml. "
    "It provides a ReAct agent loop, multi-provider LLM calls, "
    "type-safe tool dispatch, and a workflow engine for sequential, "
    "parallel, and conditional orchestration. PAR targets LLM backend "
    "engineers who want compile-time guarantees without rewriting their "
    "Python stack."
)
QUESTION = "What programming language is PAR written in?"

def main():
    with Runtime(make_config()) as rt:
        rt.register_agent(make_agent_config())

        # 步骤 1：嵌入源文本。每个输入返回一个向量。
        vectors = rt.embed([PARAGRAPH])
        print(f"Embedded 1 passage into a {len(vectors[0])}-dim vector")

        # 步骤 2：索引段落。传入字符串或带 id/content/metadata 的 dict。
        # 成功返回 0；embedding 或存储步骤失败时抛出 PARError。
        rc = rt.add_documents([
            {"id": "par-intro", "content": PARAGRAPH,
             "metadata": {"source": "readme"}},
        ])
        print(f"add_documents returned {rc} (0 means success)")

        # 步骤 3：用 RAG 提问。runtime 嵌入查询，在索引中搜索
        # top-k 段落，注入系统提示词，然后调用 agent。
        answer = rt.invoke_with_rag("rag_agent", QUESTION, k=1)
        print(f"\nQ: {QUESTION}")
        print(f"A: {answer}")

if __name__ == "__main__":
    main()
```

预期输出（具体 JSON 会变化，但结构稳定）：

```
Embedded 1 passage into a 8-dim vector
add_documents returned 0 (0 means success)

Q: What programming language is PAR written in?
A: {"content":"[mock answer grounded in 412 chars of context] Question was: What programming language is PAR written in?","finish_reason":"stop","role":"assistant"}
```

回答 JSON 是 LLM（这里是 mock）返回的内容，加上 finish reason 和 role。在配置了 OpenAI 或 Anthropic 的真实部署中，`content` 字段是模型的有依据回答。检索本身是真实的：查询被嵌入、索引被搜索、段落被注入上下文窗口。

### 刚才发生了什么

`invoke_with_rag` 内部按顺序执行三个阶段：

1. **嵌入查询。** runtime 调用与生成文档向量相同的 embedding 端点。对两者使用同一端点可以防止 embedding 模型漂移——即文档和查询来自不同模型导致相似度分数失去意义的静默失败模式。
2. **搜索索引。** runtime 在 sqlite-vec 虚拟表上运行余弦 KNN，保留 top `k` 结果。
3. **增强并调用。** 检索到的段落被折叠进系统提示词，agent 使用增强后的提示词被调用。

`k=1` 让示例保持最小。对于大多数真实工作负载，`k=3` 或 `k=4` 能给模型足够上下文而不会淹没提示词。

## 示例 2：长文档索引

真实文档比一个 embedding 长得多。一篇 3000 词的文章无法干净地放入单个向量，即使能放进去，检索也会返回整篇文章而非相关段落。解决方案是分块：将文档切成重叠窗口，嵌入每个窗口，让检索浮出具体段落。

PAR 的分块功能在 OCaml 的 `Chunking` 模块中（`chunk_by_chars`、`chunk_by_tokens`、`chunk_recursive`）。从 Python 调用时，最简单的方式是在调用 `add_documents` 之前在自己的代码中分块，这样绑定层保持轻薄，分块逻辑可检查。本示例用滑动窗口分块长文档，并为每个 chunk 索引位置元数据。

```python
# example2_long_doc.py
"""示例 2：分块长文档，索引 chunk，跨 chunk 查询。"""
from shared import make_config, make_agent_config
from par_runtime import Runtime

# 一篇合成长文档：关于 PAR 特性的五个段落。
LONG_DOC = """
PAR provides a ReAct agent loop with bounded iterations. The agent
reasons step by step, calls tools, observes results, and repeats until
it reaches a final answer or hits the iteration cap. Middleware hooks
fire at every LLM and tool boundary, so logging, retry, and rate
limiting compose cleanly.

The workflow engine orchestrates multi-step tasks. Sequential steps run
in order, parallel steps run concurrently with structured concurrency,
and conditional steps branch on intermediate results. Map-reduce fan-out
is supported for batch workloads. Workflows checkpoint to the
persistence layer, so long-running jobs survive restarts.

PAR supports multiple LLM providers. OpenAI and Anthropic are built in.
Ollama works through an OpenAI-compatible local endpoint. A Mock
provider exists for testing without network calls. Custom providers can
be registered for any OpenAI-compatible API, including self-hosted
vLLM or llama.cpp servers.

Twenty built-in tools ship with the runtime, including a type-safe bash
tool. The bash tool uses an algebraic data type for command construction,
which makes shell injection unrepresentable in the type system. Other
tools cover file I/O, HTTP fetch, web search, and arithmetic.

Seven middleware modules compose into a pipeline. Logging records every
boundary. Retry handles transient failures with exponential backoff.
Rate limit enforces per-token throttling. Timeout bounds each call.
Validation checks inputs and outputs against schemas. PII mask redacts
sensitive fields. Sanitize tool output strips dangerous content.
""".strip()

QUESTION = "How does the bash tool prevent shell injection?"

def chunk_text(text, max_size=400, overlap=80):
    """滑动窗口分块器。产出 (index, start, end, text)。"""
    chunks = []
    start = 0
    n = len(text)
    idx = 0
    while start < n:
        end = min(start + max_size, n)
        chunk = text[start:end]
        chunks.append((idx, start, end, chunk))
        if end == n:
            break
        start = end - overlap
        idx += 1
    return chunks

def main():
    with Runtime(make_config()) as rt:
        rt.register_agent(make_agent_config())

        chunks = chunk_text(LONG_DOC, max_size=400, overlap=80)
        print(f"Split document into {len(chunks)} chunks "
              f"(max_size=400, overlap=80)")

        # 用位置元数据索引每个 chunk。metadata dict 是自由格式的：
        # PAR 将其与向量一起存储，并在检索结果中返回，
        # 以便调用方可以引用来源。
        documents = []
        for idx, start, end, text in chunks:
            documents.append({
                "id": f"features-chunk-{idx}",
                "content": text,
                "metadata": {
                    "source": "features.md",
                    "chunk_index": idx,
                    "char_start": start,
                    "char_end": end,
                },
            })
        rc = rt.add_documents(documents)
        print(f"add_documents returned {rc}, indexed {len(documents)} chunks")

        # 用 k=2 查询以拉取最相关的两个 chunk。
        answer = rt.invoke_with_rag("rag_agent", QUESTION, k=2)
        print(f"\nQ: {QUESTION}")
        print(f"A: {answer}")

if __name__ == "__main__":
    main()
```

预期输出：

```
Split document into 6 chunks (max_size=400, overlap=80)
add_documents returned 0, indexed 6 chunks

Q: How does the bash tool prevent shell injection?
A: {"content":"[mock answer grounded in 893 chars of context] Question was: How does the bash tool prevent shell injection?","finish_reason":"stop","role":"assistant"}
```

### 调优 chunk 大小

两个重要参数是 `max_size`（窗口长度，字符数）和 `overlap`（连续窗口之间的共享尾部）。对于散文，默认值 800 到 1200 字符、10% 到 20% 重叠效果良好。较小的 chunk 提高检索精度但丢失跨段落上下文。较大的 chunk 携带更多上下文但当只有一句话相关时会稀释相似度分数。

对于段落边界重要的结构化文本，先按 `\n\n` 分割，仅对过长段落回退到固定大小窗口。这就是 PAR 的 OCaml `chunk_recursive` 策略内部做的事：在诉诸字符窗口之前按顺序尝试结构化分隔符。

chunk 元数据是你的引用表面。当检索返回命中时，`char_start` 和 `char_end` 字段让你能指向源文档中的确切段落，就像搜索结果高亮显示摘要片段一样。

## 示例 3：多文档语料

真实的 RAG 应用索引许多文档，而非一篇。一个文档站可能有数百页，每页带其章节、版本和产品标签。本示例索引三个不同文档，每个有自己的元数据，并展示 runtime 如何跨整个语料检索。

```python
# example3_multi_doc.py
"""示例 3：索引多个带标签文档，跨语料查询。"""
import json
from shared import make_config, make_agent_config
from par_runtime import Runtime

# 三篇短文档，各来自不同来源和章节。
DOCS = [
    {
        "id": "install-cli",
        "content": (
            "Install the PAR CLI with the bootstrap script: "
            "curl -fsSL https://example.com/install.sh | bash. "
            "The binary lands in /usr/local/bin/par. Run 'par config' "
            "once to choose a provider and enter an API key."
        ),
        "metadata": {"section": "install", "source": "cli.md",
                     "audience": "new-users"},
    },
    {
        "id": "install-python",
        "content": (
            "Install the PAR Python binding with pip: "
            "pip install par-runtime. The wheel bundles the OCaml "
            "shared library, so no compiler is needed. Import with "
            "'from par_runtime import Runtime' and construct a "
            "runtime from a JSON config string."
        ),
        "metadata": {"section": "install", "source": "python.md",
                     "audience": "developers"},
    },
    {
        "id": "troubleshoot-timeout",
        "content": (
            "If LLM calls time out, check the request_timeout setting. "
            "The default is 60 seconds. Streaming uses an idle timeout "
            "that resets on each chunk, so slow-but-steady streams "
            "survive where burst-then-stall streams do not. Raise the "
            "limit with par_set_request_timeout from Python."
        ),
        "metadata": {"section": "troubleshoot", "source": "faq.md",
                     "audience": "operators"},
    },
]

QUESTIONS = [
    "How do I install PAR from Python?",
    "The LLM keeps timing out, what do I do?",
    "What does par config do?",
]

def main():
    with Runtime(make_config()) as rt:
        rt.register_agent(make_agent_config())

        # 在一次调用中索引所有三个文档。同一列表中可以混合
        # 字符串和 dict；dict 可以附加元数据。
        rc = rt.add_documents(DOCS)
        print(f"Indexed {len(DOCS)} documents (rc={rc})\n")

        # 同时直接嵌入每个问题以便我们自己检查相似度分数。
        # 这反映了 invoke_with_rag 内部做的事，对调试检索质量有用。
        for question in QUESTIONS:
            qvecs = rt.embed([question])
            print(f"Question embedding has {len(qvecs[0])} dims: "
                  f"{qvecs[0][:4]}...")

            answer = rt.invoke_with_rag("rag_agent", question, k=2)
            parsed = json.loads(answer)
            print(f"Q: {question}")
            print(f"A: {parsed.get('content', answer)}\n")

if __name__ == "__main__":
    main()
```

预期输出：

```
Indexed 3 documents (rc=0)

Question embedding has 8 dims: [0.0, 1.0, 1.0, 0.0]...
Q: How do I install PAR from Python?
A: [mock answer grounded in 612 chars of context] Question was: How do I install PAR from Python?

Question embedding has 8 dims: [1.0, 0.0, 1.0, 1.0]...
A: [mock answer grounded in 598 chars of context] Question was: The LLM keeps timing out, what do I do?

Question embedding has 8 dims: [0.0, 1.0, 0.0, 1.0]...
A: [mock answer grounded in 530 chars of context] Question was: What does par config do?
```

### 元数据如何流经检索

每个文档上的 `metadata` dict 对 PAR 是不透明的。runtime 将其与向量一起存储，不检查其内容。这意味着基于元数据的过滤（仅检索 `section == "install"` 的文档）在 v0.5.2 的 `add_documents` 和 `invoke_with_rag` Python 接口中尚未内置。目前你有两种过滤方式：

1. **为每个过滤切片维护独立的 runtime 实例。** 一个 runtime 用于 install 文档，一个用于 troubleshoot 文档。查询相关 runtime。简单，但丢失跨切片排名。
2. **宽检索窄过滤。** 用较大的 `k` 调用 `invoke_with_rag`，然后在构建最终提示词之前按元数据后过滤检索到的上下文。需要下降到 `embed` 加手动搜索路径，OCaml SDK 通过 `Vector_store.search` 直接暴露，Python 绑定将在后续版本中暴露。

[RAG 架构](../explanation/rag-architecture.md)中记录的 embedding 无关存储设计是为了让混合搜索和元数据过滤可以在不改变核心签名的情况下后续添加。在此之前，你存储的元数据主要用于引用和展示，而非服务端过滤。

## 运行示例

将四个文件保存在同一目录：`mock_server.py`、`shared.py`、`example1_short_text.py`、`example2_long_doc.py`、`example3_multi_doc.py`。然后：

```bash
python3 example1_short_text.py
python3 example2_long_doc.py
python3 example3_multi_doc.py
```

每个脚本在空闲端口上启动自己的 mock 服务器，构造一个 runtime，并在 `with Runtime(...) as rt:` 块退出时销毁一切。mock 服务器运行在守护线程上，随进程终止。无需清理。

如果看到 `PARInitError: Failed to initialize PAR runtime`，最可能的原因是配置格式错误。runtime 的 Python 包装器会规范化缺失字段，但无法修复 JSON 语法错误。在传给 `Runtime` 之前用 `json.loads(config)` 验证你的配置字符串。

如果 `embed` 抛出 `PARError("embed failed: embeddings not initialized")`，说明 `llm_providers` 列表为空或 provider 不支持 embeddings。Anthropic 没有 embeddings API，会抛出 `Embedding_unsupported`。OpenAI、Ollama 和 mock 服务器都支持 embeddings。

## 替换为真实 provider

当你准备好离开 mock 时，修改 `make_config` 中的 `llm_providers` 条目。将 `base_url` 指向真实端点，`api_key` 指向真实密钥。其他一切保持不变。

```python
"llm_providers": [
    ["rag_agent", ["Openai", {
        "api_key": "sk-...",          # 真实密钥
        "base_url": None,             # None = 默认 OpenAI 端点
        "organization": None,
        "embedding_model": None,      # None = text-embedding-3-small
    }]],
],
```

对于 Ollama，指向本地服务器：

```python
["rag_agent", ["Ollama", {"base_url": "http://localhost:11434/v1"}]]
```

Ollama 暴露 OpenAI 兼容的 embeddings 端点，因此通过同一检索管道工作。对嵌入文档和查询使用同一 provider。跨两者混合 provider 就是该架构设计要防止的漂移 bug，且 runtime 不会为你捕获它。

## v0.5.2 的限制

本指南未涵盖的一些事项及原因：

- **Python 接口中没有元数据过滤。** 如上所述，`invoke_with_rag` 纯粹按向量相似度检索。混合搜索（BM25 加向量重排）和元数据谓词在路线图上。
- **没有文档加载器。** 示例传入原始字符串。PAR 不解析 PDF、HTML 或 Markdown frontmatter。索引前请先转为文本。文档加载器层已规划。
- **Mock embeddings 不是语义的。** `mock_server.py` 中基于哈希的向量将完全匹配排在最高，但没有语义概念。它们的存在是为了证明管道端到端工作。真实的检索质量需要真实的 embedding 模型。
- **`add_documents` 在 v0.5.2 中成功返回 0。** 返回值是状态码，不是计数。未来版本可能返回已索引文档数量。今天不要依赖返回值是计数。
- **外部向量库已推迟。** Qdrant 和 Milvus 支持将在后续版本中落地。embedding 无关的存储接口设计确保切换后端不会改变 Python API。

## 另请参阅

- [RAG API 参考](../sdk/rag.md) — 完整函数签名、provider 支持表和 OCaml 示例
- [RAG 架构](../explanation/rag-architecture.md) — 设计决策：embedding 无关存储、为什么选 sqlite-vec、分数语义、三阶段管道
- [Streaming API](../sdk/streaming.md) — 逐 token 输出，与 RAG 组合使用时可流式输出有依据的回答
- [Agent API](../sdk/agent.md) — `register_agent`、`invoke`，以及未配置向量库时 `invoke_with_rag` 回退到的非 RAG 调用路径
