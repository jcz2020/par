# par_runtime 快速入门

par_runtime 是 P-A-R (Programmable Agent Runtime) 的 Python ctypes 绑定，
允许在 Python 中使用 PAR 的 agent 运行时、工具注册和工作流编排功能。

版本: PAR v0.2.0 / par_runtime v0.1.0

## 什么是 par_runtime

par_runtime 通过 ctypes 调用 PAR 的 C FFI 接口 (`par_capi.so`)，提供:
`Runtime` 类（生命周期管理）、工具注册、agent 同步调用、工作流提交与审批。
它是 OCaml 运行时的薄包装层，核心逻辑（agent 循环、中间件、持久化）在 OCaml 层执行。

## 前置条件

| 依赖 | 要求 |
|------|------|
| Python | 3.8+ |
| PAR 源码 | 需先构建共享库 |
| OCaml 工具链 | 仅构建共享库时需要 |
| 操作系统 | Linux / macOS |

## 安装

从源码安装（推荐）:

```bash
git clone https://github.com/jcz2020/par.git && cd par
dune build lib/ffi/par_capi.so
pip install -e bindings/python
```

pip 安装（不含共享库，需手动构建或设置 `PAR_RUNTIME_LIB`）:

```bash
pip install par-runtime
```

## 构建共享库

```bash
dune build lib/ffi/par_capi.so
```

产物位于 `_build/default/lib/ffi/par_capi.so`。

## 环境变量

`PAR_RUNTIME_LIB` — 指定 `par_capi.so` 的绝对路径。

未设置时搜索顺序: `PAR_RUNTIME_LIB` > 包目录 `lib/` > 项目 `_build/default/lib/ffi/` > 系统库路径。

## 第一个运行时

```python
import json
from par_runtime import Runtime

config = json.dumps({
    "persistence": {"tag": "sqlite", "contents": ":memory:"},
    "event_bus": {"max_queue_size": 100, "dlq_enabled": False, "dlq_max_size": 10},
    "default_quota": {"max_tokens": 4096, "max_iterations": 10, "timeout_seconds": 30.0},
    "shutdown": {"grace_period_seconds": 5.0, "force_after_seconds": 10.0},
    "llm_providers": [],
    "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
})

with Runtime(config) as rt:
    print(rt)  # <PAR Runtime active>
    rt.register_tool(
        name="echo",
        description="Echo back the input",
        input_schema=json.dumps({
            "type": "object",
            "properties": {"message": {"type": "string"}},
            "required": ["message"],
        }),
    )
# 此处运行时已自动关闭
```

验证:

```bash
dune build lib/ffi/par_capi.so
cd bindings/python && python3 -m pytest tests/
cd bindings/python && python3 examples/basic_agent.py
```

## 配置 JSON 格式

```json
{
    "persistence": {"tag": "sqlite", "contents": "par.db"},
    "event_bus": {"max_queue_size": 100, "dlq_enabled": false, "dlq_max_size": 10},
    "default_quota": {"max_tokens": 4096, "max_iterations": 10, "timeout_seconds": 30.0},
    "shutdown": {"grace_period_seconds": 5.0, "force_after_seconds": 10.0},
    "llm_providers": [],
    "eval_limits": {"max_depth": 10, "max_node_visits": 1000}
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `persistence.tag` | string | `"sqlite"`; `contents` 为路径或 `":memory:"` |
| `event_bus.max_queue_size` | int | 事件队列最大容量 |
| `event_bus.dlq_enabled` | bool | 死信队列开关 |
| `event_bus.dlq_max_size` | int | 死信队列容量 |
| `default_quota.max_tokens` | int | 单次调用最大 token 数 |
| `default_quota.max_iterations` | int | agent 循环最大迭代数 |
| `default_quota.timeout_seconds` | float | 调用超时（秒） |
| `shutdown.grace_period_seconds` | float | 优雅关闭等待时间 |
| `shutdown.force_after_seconds` | float | 强制关闭时间 |
| `llm_providers` | array | LLM provider 列表，空数组表示无 provider |
| `eval_limits.max_depth` | int | 表达式递归深度限制 |
| `eval_limits.max_node_visits` | int | 表达式节点访问限制 |

## Context Manager 用法

推荐 `with` 语句，自动调用 `close()`:

```python
with Runtime(config) as rt:
    rt.register_tool("my_tool", "desc", '{"type": "object"}')
```

手动管理:

```python
rt = Runtime(config)
try:
    rt.register_tool("my_tool", "desc", '{"type": "object"}')
finally:
    rt.close()
```

`__del__` 也会调用 `close()`，但不建议依赖析构函数。

## 错误处理

异常层次: `PARError` > `PARInitError` / `PARInvokeError` / `PARToolError` / `PARWorkflowError`。

```python
from par_runtime import PARError, PARInitError, PARInvokeError, PARToolError, PARWorkflowError

try:
    with Runtime(config) as rt:
        rt.invoke("agent", "Hello")
except PARInitError as e:
    print(f"初始化失败: {e}")
except PARInvokeError as e:
    print(f"调用失败: {e}")
except PARError as e:
    print(f"PAR 错误: {e}")
```

| 异常 | 触发场景 |
|------|---------|
| `PARInitError` | 构造时配置无效或共享库加载失败 |
| `PARToolError` | `register_tool()` 失败（名称重复、schema 无效） |
| `PARInvokeError` | `invoke()` 失败或返回 JSON 含 `"error"` 字段 |
| `PARWorkflowError` | 工作流操作失败 |
| `PARError` | 运行时已关闭后调用方法 |

## 线程安全

`Runtime` 实例**不是线程安全的**。多线程环境需为每个线程创建独立实例。
底层 OCaml Eio 事件循环通过单线程序列化，但 Python 层未做同步。

## 常见问题

**OSError: 共享库找不到** — 执行 `dune build lib/ffi/par_capi.so` 或设置 `PAR_RUNTIME_LIB`。

**PARInitError: 初始化失败** — 检查 JSON 合法性和 `persistence` 字段格式。

**PARError: Runtime has been shut down** — `close()` 或 `with` 退出后不可再调用方法。

**register_agent** — 通过 JSON 配置注册 agent。参考 [API 文档](api.md) 获取支持的配置字段。

**invoke 失败** — 常见原因: 未注册 agent、未配置 LLM provider、API 密钥无效。

## 下一步

- [API 参考](api.md) — 完整方法签名与参数说明
- [进阶指南](advanced.md) — 自定义 FFI、调试、与 OCaml SDK 对比
