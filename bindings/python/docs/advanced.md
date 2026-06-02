# par_runtime 进阶指南

高级用法: 从源码构建、自定义 FFI 绑定、调试、与 OCaml SDK 对比。

## 从源码构建

```bash
git clone https://github.com/jcz2020/par.git && cd par
eval $(opam env)
dune build lib/ffi/par_capi.so
pip install -e bindings/python
python3 -c "from par_runtime import Runtime; print('OK')"
cd bindings/python && python3 -m pytest tests/
```

修改 OCaml 代码后只需 `dune build lib/ffi/par_capi.so`，无需重装 Python 包。

安装到系统路径（可选）:

```bash
cp _build/default/lib/ffi/par_capi.so /usr/local/lib/ && sudo ldconfig
```

## 自定义 FFI 绑定

当 `Runtime` 高层接口不够时，可直接使用底层 FFI:

```python
from par_runtime._ffi import _lib, _c_str, _py_str

handle = _lib.par_init(_c_str('{"persistence": {"tag": "sqlite", "contents": ":memory:"}, ...}'))
if handle:
    ret = _lib.par_register_tool(handle, _c_str("t"), _c_str("desc"), _c_str('{"type": "object"}'))
    result_ptr = _lib.par_invoke(handle, _c_str("agent-id"), _c_str("msg"))
    result = _py_str(result_ptr)  # 自动 free
    _lib.par_shutdown(handle)
```

声明新增 C 函数:

```python
import ctypes
from par_runtime._ffi import _lib
_lib.par_new_func.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_new_func.restype = ctypes.c_int
```

内存管理规则: `c_void_p` 返回的字符串必须用 `_py_str()` 读取（自动 free），
切勿直接用 `c_char_p.value` 读取而不 free，否则内存泄漏。

## 线程安全

`Runtime` 实例**不是线程安全的**。所有方法（`register_tool`、`invoke`、工作流操作）
均不受 Python 侧同步保护。多线程使用需为每个线程创建独立实例:

```python
import threading

def worker(config):
    with Runtime(config) as rt:
        rt.register_tool("tool", "desc", '{"type": "object"}')

for i in range(3):
    threading.Thread(target=worker, args=(config,)).start()
```

不要跨线程共享 `Runtime` 或 `_handle`。底层 OCaml Eio 事件循环单线程运行，
跨线程并发调用会导致未定义行为。

## 性能注意事项

每次 FFI 调用涉及: Python 字符串 UTF-8 编码、ctypes 参数打包、C 调用、
返回字符串解码 + 内存释放。单次调用开销可忽略，高频场景建议批量处理。

每个 `Runtime` 实例对应一个 OCaml 运行时（事件队列、工具注册表、持久化连接），
大量并发实例会增加内存占用。

## 调试

启用 OCaml 日志:

```bash
export LOGS=par=debug
python3 your_script.py
```

追踪共享库加载:

```bash
strace -e trace=open,openat python3 -c "from par_runtime._ffi import _lib"
```

调试库路径:

```python
import os
from par_runtime._ffi import _find_library
print("PAR_RUNTIME_LIB:", os.environ.get("PAR_RUNTIME_LIB", "not set"))
print("Resolved:", _find_library())
```

检查 invoke 返回值:

```python
import json
with Runtime(config) as rt:
    result = rt.invoke("agent-id", "test")
    print(json.dumps(json.loads(result), indent=2))
```

## 与 OCaml SDK 对比

| 功能 | Python (par_runtime) | OCaml (par) |
|------|---------------------|-------------|
| 初始化运行时 | 支持 | 支持 |
| 注册工具 (no-op) | 支持 | 支持 |
| 注册工具 (handler) | 不支持 | 支持 |
| 注册 agent | 不支持 | 支持 |
| 调用 agent | 支持 (需 OCaml 注册) | 支持 |
| 工作流提交/审批/恢复 | 部分/支持/支持 | 全部支持 |
| 中间件 | 不支持 | 7 个内置 |
| PostgreSQL | 不支持 | 支持 (可选) |
| CLI REPL | 不适用 | `par` 命令 |

选择 Python: 已有 Python 技术栈、快速集成、原型验证、简单工作流。
选择 OCaml: 需完整 agent 定义、自定义 handler、中间件、PG 持久化、性能敏感。

## 从原始 ctypes 迁移

迁移前:

```python
import ctypes
lib = ctypes.CDLL("par_capi.so")
lib.par_init.argtypes = [ctypes.c_char_p]
lib.par_init.restype = ctypes.c_void_p
handle = lib.par_init(b'{...}')
# 手动管理内存和生命周期
```

迁移后:

```python
from par_runtime import Runtime, PARError
try:
    with Runtime(config) as rt:
        rt.register_tool("tool", "desc", '{"type": "object"}')
except PARError as e:
    print(f"Error: {e}")
```

迁移检查清单:
- 替换 `ctypes.CDLL` 为 `from par_runtime import Runtime`
- 替换手动 `argtypes`/`restype` 声明
- 替换手动内存管理为 `_py_str` 自动释放
- 替换错误码检查为异常捕获
- 替换手动 `par_shutdown` 为 `with` 语句
- 设置 `PAR_RUNTIME_LIB` 或确保共享库在搜索路径中
