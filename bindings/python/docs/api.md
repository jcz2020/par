# par_runtime API 参考

par_runtime 包的完整 API 参考。所有符号从 `par_runtime` 顶层导入。

## Runtime 类

```python
from par_runtime import Runtime
```

agent 运行时的高层包装，管理完整生命周期。支持 context manager 协议。

### 构造函数

```python
Runtime(config_json: str) -> Runtime
```

从 JSON 配置字符串初始化运行时。

| 参数 | 类型 | 说明 |
|------|------|------|
| `config_json` | `str` | 运行时配置 JSON 字符串 |

异常: `PARInitError` — 初始化失败。

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
rt = Runtime(config)
```

### close

```python
close() -> None
```

关闭运行时，释放资源。关闭后实例不可再用。重复调用安全（幂等）。

```python
rt.close()
rt.close()  # 安全，不报错
```

### register_tool

```python
register_tool(name: str, description: str, input_schema: str) -> None
```

注册工具到运行时。

| 参数 | 类型 | 说明 |
|------|------|------|
| `name` | `str` | 工具名称，不能为空 |
| `description` | `str` | 工具描述 |
| `input_schema` | `str` | 输入的 JSON Schema（JSON 字符串） |

异常: `PARToolError`（注册失败）, `PARError`（运行时已关闭）。

C FFI 返回码: `0` 成功, `-1` 通用错误, `-2` schema 无效, `-3` 名称为空, `-4` 名称重复。

> 当前版本注册的工具使用 no-op handler，不会执行实际逻辑。

```python
import json
with Runtime(config) as rt:
    rt.register_tool(
        name="calculator",
        description="Evaluate arithmetic expressions",
        input_schema=json.dumps({
            "type": "object",
            "properties": {"expression": {"type": "string"}},
            "required": ["expression"],
        }),
    )
```

### register_agent

```python
register_agent(config_json: str) -> None
```

> 通过 JSON 配置注册 agent，支持 `id`、`system_prompt`、`model` 等字段。

### invoke

```python
invoke(agent_id: str, message: str) -> str
```

同步调用 agent。

| 参数 | 类型 | 说明 |
|------|------|------|
| `agent_id` | `str` | agent 标识符 |
| `message` | `str` | 用户消息 |

返回: `str` — JSON 响应。成功时: `{"status": "ok", "content": "..."}`。

异常: `PARInvokeError`（调用失败或返回含 `"error"` 的 JSON）, `PARError`（运行时已关闭）。

```python
with Runtime(config) as rt:
    result = rt.invoke("my-agent", "Hello, world!")
    print(result)
```

### submit_workflow

```python
submit_workflow(workflow_json: str) -> str
```

提交工作流执行。返回 JSON 结果字符串。

异常: `PARError`（运行时已关闭）。

> 当前版本工作流提交功能尚未完全实现。

### approve_workflow

```python
approve_workflow(run_id: str, approver: str) -> None
```

审批待处理的工作流步骤。

| 参数 | 类型 | 说明 |
|------|------|------|
| `run_id` | `str` | 工作流运行标识符 |
| `approver` | `str` | 审批者身份 |

异常: `PARWorkflowError`（审批失败）, `PARError`（运行时已关闭）。

```python
rt.approve_workflow("run-abc123", "admin")
```

### resume_workflow

```python
resume_workflow(run_id: str) -> str
```

恢复暂停的工作流。返回 JSON 结果字符串。

异常: `PARError`（运行时已关闭）。

```python
result = rt.resume_workflow("run-abc123")
```

### __repr__

```python
repr(rt)  # "<PAR Runtime active>" 或 "<PAR Runtime closed>"
```

### Context Manager

```python
Runtime.__enter__() -> Runtime
Runtime.__exit__(exc_type, exc_val, exc_tb) -> bool
```

`__enter__` 返回 `self`，`__exit__` 调用 `close()` 并返回 `False`。

## PARError 异常层次

```
PARError (基类, 继承 Exception)
  PARInitError      — 运行时初始化失败
  PARInvokeError   — agent 调用失败
  PARToolError     — 工具注册失败
  PARWorkflowError — 工作流操作失败
```

| 异常 | 触发场景 |
|------|---------|
| `PARError` | 运行时已关闭后调用方法 |
| `PARInitError` | `par_init` 返回空句柄 |
| `PARInvokeError` | `par_invoke` 返回空指针或 JSON 含 `"error"` |
| `PARToolError` | `par_register_tool` 返回非零 |
| `PARWorkflowError` | `par_approve_workflow` 返回非零 |

## FFI 内部模块

`par_runtime._ffi` 封装所有 ctypes 声明，通常不需要直接使用。

### 共享库加载

```python
from par_runtime._ffi import _lib  # ctypes.CDLL 实例
```

### C 函数签名

| C 函数 | 返回类型 | 说明 |
|--------|---------|------|
| `par_init(c_char_p)` | `c_void_p` | 初始化运行时 |
| `par_shutdown(c_void_p)` | `None` | 关闭运行时 |
| `par_register_tool(c_void_p, c_char_p, c_char_p, c_char_p)` | `c_int` | 注册工具 |
| `par_register_agent(c_void_p, c_char_p)` | `c_int` | 注册 agent |
| `par_invoke(c_void_p, c_char_p, c_char_p)` | `c_void_p` | 调用 agent（需 free） |
| `par_submit_workflow(c_void_p, c_char_p)` | `c_void_p` | 提交工作流（需 free） |
| `par_approve_workflow(c_void_p, c_char_p, c_char_p)` | `c_int` | 审批工作流 |
| `par_resume_workflow(c_void_p, c_char_p)` | `c_void_p` | 恢复工作流（需 free） |

返回 `c_void_p` 的字符串由 C 分配，`_py_str()` 读取后自动 `free()`。

### 辅助函数

```python
from par_runtime._ffi import _c_str, _py_str
_c_str("hello")  # b"hello" (UTF-8)
_py_str(ptr)      # 从 C char* 读取并 free
```

## 配置 JSON Schema

传递给 `Runtime(config_json)` 的完整 JSON 结构:

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

| 字段路径 | 类型 | 说明 |
|----------|------|------|
| `persistence.tag` | string | 持久化类型，当前仅 `"sqlite"` |
| `persistence.contents` | string | 数据库路径，`":memory:"` 为内存模式 |
| `event_bus.max_queue_size` | int | 事件队列容量 |
| `event_bus.dlq_enabled` | bool | 死信队列开关 |
| `event_bus.dlq_max_size` | int | 死信队列容量 |
| `default_quota.max_tokens` | int | 最大 token 用量 |
| `default_quota.max_iterations` | int | agent 最大迭代数 |
| `default_quota.timeout_seconds` | float | 调用超时（秒） |
| `shutdown.grace_period_seconds` | float | 优雅关闭时间 |
| `shutdown.force_after_seconds` | float | 强制关闭时间 |
| `llm_providers` | array | LLM provider 列表 |
| `eval_limits.max_depth` | int | 表达式递归深度 |
| `eval_limits.max_node_visits` | int | 表达式节点访问数 |

## 工具注册 Schema

`input_schema` 参数遵循 JSON Schema 格式，必须是 JSON 对象。

最小化:

```python
rt.register_tool("my_tool", "Description", '{"type": "object"}')
```

带属性:

```python
rt.register_tool(
    "search", "Search for information",
    json.dumps({
        "type": "object",
        "properties": {"query": {"type": "string", "description": "Search query"}},
        "required": ["query"]
    })
)
```
