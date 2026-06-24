<!-- language: en -->

# Concurrency Model

This document explains *why* PAR runs on OCaml 5.4 effects plus Eio, and what that choice buys you in practice. It is not an API reference. For the function signatures, read `lib/core/runtime.ml` and the streaming reference at `docs/sdk/streaming.md`. Here we walk through the design rationale, compare it to the alternatives, and trace the path a single Python call takes through the runtime.

## The problem PAR set out to solve

An agent runtime is a concurrency-heavy system. A single `Runtime.invoke` may fan out into several tool calls running in parallel, a streaming LLM connection holding a socket open, a persistence writer batching events in the background, and a cancellation token that has to reach every one of those fibers the instant the caller changes their mind. The classic ways to express that in a language are threads, callbacks, promises, async/await, or green-thread runtimes. Each makes a different tradeoff between ergonomics, safety, and resource cost.

PAR's target user is a backend engineer shipping an LLM-powered service. They care about latency, memory footprint, and the cost of getting concurrency wrong: a leaked fiber holding a database connection, a callback that fires after the caller has already torn down its state, a timeout that does not actually cancel the work. The concurrency model is the load-bearing decision that makes those failure modes either easy to hit or hard to hit. PAR chose OCaml 5.4 effect handlers plus the Eio library specifically because structured concurrency makes the bad states hard to reach.

## OCaml 5.4 effects, in one paragraph

OCaml 5.0 introduced effect handlers to the language. An effect is a suspensible operation: when user code performs it, the runtime captures the current continuation as a first-class value and hands it to a handler. The handler can resume the continuation later, on the same domain, after some I/O completes. This is the substrate Eio builds on. Because the continuation is resumable rather than discarded, user code can be written in direct style, straight-line code that *looks* blocking, while underneath the runtime multiplexes many such computations onto a small pool of OS-level domains. There is no color trick: every function is the same color, because there is no async keyword.

## Eio: structured concurrency for OCaml

[Eio](https://github.com/ocaml-multicore/eio) is the concurrency library PAR uses on top of effects. Its central abstraction is the *switch*. A switch (`Eio.Switch.t`) is a scope. Every fiber spawned inside a switch is a child of that switch, and when the switch exits, every child fiber is guaranteed to be cancelled and joined before control returns to the caller. There is no way to spawn a fiber that outlives its switch. This is what "structured concurrency" means here, and it is the same idea as Python's `TaskGroup` (3.11+) or Java's structured concurrency preview, except Eio has enforced it from the start.

```
Eio.Switch.run (fun switch ->
  (* every fiber forked here is a child of `switch` *)
  ...
  (* when this function returns, all children are cancelled and joined *)
)
```

PAR hands every `Runtime` exactly one switch, stored as `cancellation_root` (`lib/core/runtime.ml`, the `runtime` record). That switch is the cancellation root for the entire runtime's lifetime. `Runtime.close` tears it down, and every fiber it spawned, tool handler it forked, SSE stream it opened, and persistence drain loop it started all die together. There is no orphan fiber cleanup to forget.

## Why not the alternatives

The choice is easier to defend by comparing it to what PAR did not pick.

**Python asyncio** is the obvious comparison because LangChain, OpenAI Agents SDK, AutoGen, and most of the Python agent ecosystem run on it. asyncio is callback-based under the `async`/`await` syntax. The syntax hides the callbacks, but they are still there: every `await` is a suspension point, and the continuation is scheduled by an event loop. The cost is the function-color split: an `async def` cannot be called from a sync context without a bridge, and a sync helper cannot `await` without being rewritten `async`. Tool handlers, middleware, and provider adapters all have to pick a color and stay consistent. PAR's effect-based runtime has no color. A tool handler is just a function. The `with_timeout` wrapper suspends it via effects, not via a coroutine wrapper.

**Go goroutines** are close to effects in spirit: cheap, multiplexed, direct-style. The difference is cancellation. Go goroutines have no built-in parent-child relationship. A goroutine spawned with `go func()` is fire-and-forget; the parent has to pass a `context.Context` and the child has to *check* it cooperatively, or it leaks. The classic Go bug is a goroutine that blocks on a channel send after the receiver has moved on, holding a reference forever. Eio's switch model makes that structurally impossible: the child cannot outlive the parent, because the parent's switch exit blocks until the child is joined.

**Rust tokio** is the closest peer in terms of safety, but it pays for it with the `Send` and lifetime annotations on every async function. PAR's target user is not writing `Pin<Box<dyn Future<Output = Result<...>> + Send>>`. OCaml's GC plus effect handlers get the same direct-style ergonomics without that tax. The tradeoff is that OCaml domains share a single GC, so true shared-memory parallelism across domains is more constrained than Rust's fearless concurrency. PAR accepts that: agent workloads are I/O bound, not CPU bound, and one OCaml domain with many fibers is enough for most services.

## The work-loop architecture (v0.5.1 FFI)

PAR is callable from three surfaces: the OCaml SDK, the CLI, and the Python binding. The Python binding is the interesting one, because Python is not OCaml. The binding links `par_capi.so` (built by `lib/ffi/par_capi.ml`) into the Python process and calls it through ctypes. The question is how Python threads and OCaml fibers cooperate.

The naive design is: Python calls a C function, the C function runs Eio code, Eio spawns fibers, the function returns. That breaks because Eio fibers are bound to a domain, and ctypes callbacks arrive on arbitrary Python threads. A fiber started on one callback cannot be cancelled or awaited from the next callback.

The v0.5.1 design solves this with a *persistent domain and a work loop*. When `par_init` is called from Python, `do_init` (`lib/ffi/par_capi.ml`) spawns a dedicated OCaml `Domain` and runs `Eio_main.run` inside it. That domain owns the `Runtime`, its switch, and all the fibers it will ever spawn. It then enters `work_loop`, a function that blocks on a `Mutex`-protected queue waiting for work items.

```
Python thread                  par_capi domain (owns Runtime)
─────────────                  ────────────────────────────────
par_invoke("agent", "hi")
   │
   │ dispatch(state_id, work_fn)
   │   ├─ enqueue { work_fn; result_slot }
   │   ├─ Condition.signal work_cond
   │   └─ slot_take result_slot   ◄── blocks
   │                                    │
   │                                    │
   │              work_loop wakes ◄─────┘
   │              ├─ Queue.pop item
   │              ├─ run work_fn rt env
   │              │   └─ Runtime.invoke ... (spawns fibers, etc.)
   │              └─ slot_put result_slot ◄── fills
   │                                          │
   ◄── slot_take returns ─────────────────────┘
   │
   return JSON to Python
```

Every Python entrypoint, `par_invoke`, `par_invoke_stream`, `par_embed`, `par_add_documents`, `par_invoke_with_rag`, follows this same pattern: package the work as a closure, enqueue it, wait on a slot, hand the result back. The OCaml domain is the single owner of the `Runtime`. Python threads can call in concurrently; each gets its own slot, and the work loop serializes execution. This is why the Python binding is thread-safe without holding a global lock on the Python side.

The closures cross the OCaml/Python boundary as `Obj.t` (existential). The queue is monomorphic, holding `work_item` records whose `work` field is an `Obj.repr`-encoded `runtime -> env -> Obj.t` closure. When the work loop pops an item, it downcasts back to the typed closure and applies it. This is the one place PAR reaches below the type system, and it is contained to the FFI bridge. The OCaml SDK and CLI never see it.

## Cancellation, timeouts, and the switch

Cancellation flows from the runtime's switch down to the leaves. The mechanism:

- `Runtime` holds `cancellation_root : Eio.Switch.t`. Every fiber the runtime forks, directly or transitively, is a child.
- Tool handlers receive a `cancellation_token` derived from `cancellation_root` (`Cancellation.create_token rt.cancellation_root` in `lib/core/runtime.ml`). A handler inside `with_timeout` checks the token, or the timeout fires and Eio cancels the fiber.
- Timeouts use `Eio.Fiber.first`, which races two fibers and cancels the loser. There is no manual timer-thread bookkeeping.
- `Runtime.close` shuts down the whole tree. It drains the steering and follow-up queues, flushes the persistence writer synchronously, closes the persistence and LLM services, and returns. Because every fiber is a child of the runtime's switch, anything still running is cancelled by the switch teardown.

The payoff is that a Python `with Runtime(...) as rt:` block, or an OCaml `Eio.Switch.run` block, cannot leak a fiber. If the caller walks away early, the switch exit joins the children. A hung tool handler holding a connection does not outlive its runtime.

## What this means in practice

For the OCaml SDK user, the concurrency model is almost invisible. You write direct-style code, call `Runtime.invoke`, get a result. Eio and effects do the multiplexing. The one thing you must do is spawn the runtime inside `Eio_main.run` and `Eio.Switch.run`, because the runtime needs a live switch to fork its background fibers.

For the Python user, the concurrency model is *also* mostly invisible, and that is the point. The persistent domain means you can call `rt.invoke` and `rt.invoke_stream` from multiple threads without managing the OCaml side. Cancellation is implicit: `del rt` or leaving the `with` block triggers `par_shutdown`, which dispatches `Runtime.close` to the work loop and joins the domain. You do not have to think about fibers at all.

For the contributor, the rules are: every fiber you fork goes inside the runtime's switch (or a child switch you create and exit cleanly); every blocking call should accept or derive a cancellation token; never use `Domain.spawn` outside the FFI bridge, because the runtime is not designed to be shared across domains. The work-loop architecture is the boundary, and everything inside it is single-domain Eio.

## See also

- [Architecture](architecture.md) for the module map and how concurrency fits into the larger Runtime structure
- [Persistence and Durability](persistence-and-durability.md) for how the persistence writer's drain fiber cooperates with cancellation
- [Streaming API](../sdk/streaming.md) for the incremental chunk delivery path (v0.5.3 background-thread + queue model)
- [Concurrency how-to](../howto/concurrency.md) for practical patterns: timeouts, parallel tools, cancellation
