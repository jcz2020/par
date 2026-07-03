<!-- language: zh -->

**[English](../explanation/concurrency-model.md)** · 简体中文

# 并发模型

本文解释*为什么* PAR 运行在 OCaml 5.4 effects 加 Eio 上，以及这个选择在实践中给你带来了什么。这不是 API 参考。函数签名请阅读 `lib/core/runtime.ml` 和 `docs/sdk/streaming.md` 中的 streaming 参考。这里我们走过设计原理，与替代方案对比，并追踪一次 Python 调用在运行时中的路径。

## PAR 要解决的问题

Agent 运行时是并发密集的系统。一次 `Runtime.invoke` 可能扇出到多个并行运行的工具调用、一个持有 socket 的流式 LLM 连接、一个在后台批量处理事件的持久化写入器，以及一个需要在调用方改变主意的瞬间到达每一个 fiber 的取消令牌。在语言中表达这件事的经典方式是线程、回调、promise、async/await 或绿色线程运行时。每种方式在易用性、安全性和资源成本之间做了不同的权衡。

PAR 的目标用户是发布 LLM 驱动服务的后端工程师。他们关心延迟、内存占用，以及并发出错的代价：泄漏的 fiber 持有数据库连接、回调在调用方已经拆解状态后触发、超时实际上没有取消工作。并发模式是承载性决策，决定了那些故障模式是容易撞上还是很难撞上。PAR 选择 OCaml 5.4 effect handlers 加 Eio 库，正是因为结构化并发让坏状态难以到达。

## OCaml 5.4 effects，一段话讲清

OCaml 5.0 把 effect handlers 引入了语言。Effect 是一个可挂起的操作：当用户代码执行它时，运行时把当前 continuation 捕获为一等值，交给 handler。Handler 可以稍后在同一 domain 上恢复 continuation，等 I/O 完成后。这是 Eio 构建的基础。因为 continuation 是可恢复的而非丢弃的，用户代码可以用直接风格编写，看起来是阻塞的直线代码，而底层运行时把多个这样的计算复用到少量 OS 级 domain 上。没有颜色技巧：每个函数颜色相同，因为没有 async 关键字。

## Eio：OCaml 的结构化并发

[Eio](https://github.com/ocaml-multicore/eio) 是 PAR 在 effects 之上使用的并发库。它的核心抽象是 *switch*。Switch（`Eio.Switch.t`）是一个作用域。在 switch 内部 spawn 的每个 fiber 都是该 switch 的子 fiber，当 switch 退出时，每个子 fiber 保证在控制权返回给调用方之前被取消并 join。不可能 spawn 一个比它的 switch 活得更久的 fiber。这就是"结构化并发"在此处的含义，和 Python 的 `TaskGroup`（3.11+）或 Java 的结构化并发预览是同一个理念，只是 Eio 从第一天起就强制执行。

```
Eio.Switch.run (fun switch ->
  (* 在此 fork 的每个 fiber 都是 `switch` 的子 fiber *)
  ...
  (* 当此函数返回时，所有子 fiber 被取消并 join *)
)
```

PAR 给每个 `Runtime` 恰好一个 switch，存储为 `cancellation_root`（`lib/core/runtime.ml`，`runtime` record）。那个 switch 是整个运行时生命周期的取消根。`Runtime.close` 拆解它，运行时 fork 的每个 fiber、工具处理器、SSE 流、持久化 drain 循环全部一起终止。没有需要遗忘的孤儿 fiber 清理。

## 为什么不用替代方案

通过与 PAR 没有选择的方案对比，这个选择更容易辩护。

**Python asyncio** 是最显然的对比对象，因为 LangChain、OpenAI Agents SDK、AutoGen 和大多数 Python agent 生态都运行在它上面。asyncio 在 `async`/`await` 语法下是基于回调的。语法隐藏了回调，但它们仍然在：每个 `await` 是一个挂起点，continuation 由事件循环调度。代价是函数颜色分裂：`async def` 不能从同步上下文直接调用而不加桥接，同步 helper 不能 `await` 而不重写为 `async`。工具处理器、中间件和 provider 适配器都必须选一种颜色并保持一致。PAR 基于 effect 的运行时没有颜色。工具处理器就是一个函数。`with_timeout` 包装器通过 effects 挂起它，而非通过协程包装器。

**Go goroutines** 在精神上接近 effects：便宜、复用、直接风格。区别在取消。Go goroutine 没有内置的父子关系。用 `go func()` 启动的 goroutine 是 fire-and-forget；父任务必须传递 `context.Context`，子任务必须*协作式检查*它，否则就泄漏。经典的 Go bug 是 goroutine 在接收者已经离开后还在 channel 发送上阻塞，永远持有引用。Eio 的 switch 模型让这在结构上不可能：子任务不能比父任务活得更久，因为父任务的 switch 退出会阻塞直到子任务被 join。

**Rust tokio** 在安全性方面最接近，但它为每个 async 函数付出 `Send` 和生命周期标注的代价。PAR 的目标用户不会写 `Pin<Box<dyn Future<Output = Result<...>> + Send>>`。OCaml 的 GC 加 effect handlers 获得了同样的直接风格易用性而没有那个负担。代价是 OCaml domain 共享单一 GC，所以跨 domain 的真共享内存并行比 Rust 的无畏并发更受限。PAR 接受这一点：agent 工作负载是 I/O 密集而非 CPU 密集，一个 OCaml domain 配多个 fiber 对大多数服务足够。

## 工作循环架构（v0.5.1 FFI）

PAR 可从三个入口调用：OCaml SDK、CLI 和 Python 绑定。Python 绑定是有趣的那个，因为 Python 不是 OCaml。绑定把 `par_capi.so`（由 `lib/ffi/par_capi.ml` 构建）链接到 Python 进程中，通过 ctypes 调用它。问题是 Python 线程和 OCaml fiber 如何协作。

朴素设计是：Python 调用 C 函数，C 函数运行 Eio 代码，Eio spawn fiber，函数返回。这行不通，因为 Eio fiber 绑定到 domain 上，而 ctypes 回调到达任意 Python 线程。在一个回调上启动的 fiber 不能在下一个回调上取消或 await。

v0.5.1 设计通过*持久 domain 和工作循环*解决这个问题。当从 Python 调用 `par_init` 时，`do_init`（`lib/ffi/par_capi.ml`）spawn 一个专用的 OCaml `Domain`，在其中运行 `Eio_main.run`。那个 domain 拥有 `Runtime`、它的 switch 和它将要 spawn 的所有 fiber。然后进入 `work_loop`，一个在 mutex 保护的队列上阻塞等待工作项的函数。

```
Python 线程                     par_capi domain（拥有 Runtime）
────────────                    ────────────────────────────────
par_invoke("agent", "hi")
   │
   │ dispatch(state_id, work_fn)
   │   ├─ enqueue { work_fn; result_slot }
   │   ├─ Condition.signal work_cond
   │   └─ slot_take result_slot   ◄── 阻塞
   │                                    │
   │                                    │
   │              work_loop 唤醒  ◄─────┘
   │              ├─ Queue.pop item
   │              ├─ run work_fn rt env
   │              │   └─ Runtime.invoke ...（spawn fiber 等）
   │              └─ slot_put result_slot ◄── 填充
   │                                          │
   ◄── slot_take 返回  ──────────────────────┘
   │
   返回 JSON 给 Python
```

每个 Python 入口点，`par_invoke`、`par_invoke_stream`、`par_embed`、`par_add_documents`、`par_invoke_with_rag`，都遵循相同的模式：把工作打包成闭包，入队，等待 slot，把结果交回。OCaml domain 是 `Runtime` 的唯一所有者。Python 线程可以并发调入；每个获得自己的 slot，工作循环串行化执行。这就是为什么 Python 绑定线程安全而无需在 Python 侧持有全局锁。

闭包通过 `Obj.t`（存在类型）跨越 OCaml/Python 边界。队列是单态的，持有 `work_item` 记录，其 `work` 字段是 `Obj.repr` 编码的 `runtime -> env -> Obj.t` 闭包。工作循环弹出项时，向下转型回类型化闭包并应用它。这是 PAR 唯一一处触及类型系统之下的地方，局限在 FFI 桥接内。OCaml SDK 和 CLI 永远不会看到它。

## 取消、超时和 switch

取消从运行时的 switch 向下流到叶子。机制如下：

- `Runtime` 持有 `cancellation_root : Eio.Switch.t`。运行时直接或间接 fork 的每个 fiber 都是它的子 fiber。
- 工具处理器接收从 `cancellation_root` 派生的 `cancellation_token`（`Cancellation.create_token rt.cancellation_root`，在 `lib/core/runtime.ml` 中）。`with_timeout` 内的处理器检查 token，超时触发时 Eio 取消 fiber。
- 超时使用 `Eio.Fiber.first`，它竞争两个 fiber 并取消输者。没有手动的 timer-thread 簿记。
- `Runtime.close` 关闭整棵树。它排空 steering 和 follow-up 队列，同步刷新持久化写入器，关闭持久化和 LLM 服务，然后返回。因为每个 fiber 都是运行时 switch 的子 fiber，任何仍在运行的都被 switch 拆解取消。

回报是 Python 的 `with Runtime(...) as rt:` 块或 OCaml 的 `Eio.Switch.run` 块不会泄漏 fiber。如果调用方提前离开，switch 退出时 join 子 fiber。卡住的工具处理器持有连接不会比运行时活得更久。

## 实践中的意义

对 OCaml SDK 用户，并发模型几乎不可见。你写直接风格的代码，调用 `Runtime.invoke`，拿到结果。Eio 和 effects 做复用。你必须做的一件事是在 `Eio_main.run` 和 `Eio.Switch.run` 内部 spawn 运行时，因为运行时需要一个活跃的 switch 来 fork 后台 fiber。

对 Python 用户，并发模型*也*大部分不可见，这就是要点。持久 domain 意味着你可以从多个线程调用 `rt.invoke` 和 `rt.invoke_stream` 而无需管理 OCaml 侧。取消是隐式的：`del rt` 或离开 `with` 块触发 `par_shutdown`，它把 `Runtime.close` 分发到工作循环并 join domain。你根本不需要想 fiber。

对贡献者的规则是：你 fork 的每个 fiber 都在运行时的 switch 内部（或你创建并干净退出的子 switch）；每个阻塞调用应该接受或派生一个取消 token；永远不要在 FFI 桥接之外使用 `Domain.spawn`，因为运行时不是为跨 domain 共享设计的。工作循环架构是边界，里面的一切都是单 domain Eio。

## 另请参阅

- [架构](architecture.md) 模块映射以及并发如何融入更大的 Runtime 结构
- [持久化与持久性](persistence-and-durability.md) 持久化写入器的 drain fiber 如何与取消协作
- [Streaming API](../sdk/streaming.md) 增量 chunk 交付路径（v0.5.3 后台线程 + 队列模型）
- [并发 how-to](../howto/concurrency.md) 实用模式：超时、并行工具、取消
