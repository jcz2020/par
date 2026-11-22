"""Asyncio front end for the PAR runtime (v0.18 W1-S3).

``AsyncRuntime`` is a thin scheduling layer over one synchronous
:class:`~par_runtime.runtime.Runtime`. It deliberately does **not** move FFI
calls to worker threads: the OCaml runtime is initialized on the thread that
calls ``par_init`` (D0), and calling the C bridge from a foreign thread is what
caused the v0.5.4 SIGABRT class. Instead the async path uses the handle APIs
that are already non-blocking:

- ``invoke``: ``invoke_start`` (enqueues on the OCaml work loop) plus
  ``invoke_poll`` every few milliseconds;
- ``stream``: the per-stream handle is polled with a zero timeout, and the
  coroutine yields with ``asyncio.sleep`` between polls;
- ``invoke_cancel`` / ``par_stream_cancel`` are atomic flags, safe to set from
  the event loop.

Nothing blocks the event loop for longer than the C-side call itself (a poll
with timeout 0).
"""
import asyncio
from typing import Any, AsyncIterator, Callable, Dict, List, Optional, Set, Union

from par_runtime._errors import PARError, PARInvokeError
from par_runtime.models import AgentConfig, InvokeResult, RuntimeConfig
from par_runtime.runtime import Event, Runtime

__all__ = ["AsyncRuntime"]

_POLL_TIMEOUT_MS = 10


class AsyncRuntime:
    """Asynchronous wrapper around :class:`Runtime`.

    Usage::

        async with AsyncRuntime(RuntimeConfig()) as rt:
            await rt.register_agent(agent)
            result = await rt.invoke("assistant", "hello")
            async for event in rt.stream("assistant", "hello"):
                ...

    Construction does not start the OCaml runtime; the first ``await`` in the
    context manager does. Initialization runs on the event loop thread because
    the OCaml runtime is bound to the thread that calls ``par_init``.
    """

    def __init__(self, config: Union[str, Dict[str, Any], RuntimeConfig]):
        self._config = config
        self._sync: Optional[Runtime] = None
        self._drain_tasks: Set[asyncio.Task[Any]] = set()

    @property
    def sync(self) -> Runtime:
        """The underlying synchronous runtime (advanced use only)."""
        if self._sync is None:
            raise PARError("AsyncRuntime has not been started")
        return self._sync

    async def _ensure(self) -> Runtime:
        if self._sync is None:
            self._sync = Runtime(self._config)
        return self._sync

    async def __aenter__(self) -> "AsyncRuntime":
        await self._ensure()
        return self

    async def __aexit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        await self.close()

    async def close(self) -> None:
        """Shut down the runtime and release its resources."""
        for task in list(self._drain_tasks):
            task.cancel()
        self._drain_tasks.clear()
        if self._sync is not None:
            runtime, self._sync = self._sync, None
            runtime.close()

    async def register_agent(
        self, config: Union[str, Dict[str, Any], AgentConfig]
    ) -> None:
        runtime = await self._ensure()
        runtime.register_agent(config)

    async def register_tool(
        self, name: str, description: str, input_schema: str
    ) -> None:
        runtime = await self._ensure()
        runtime.register_tool(name, description, input_schema)

    async def register_tool_with_handler(
        self, name: str, description: str, input_schema: str,
        handler: Callable[[str], str],
    ) -> None:
        runtime = await self._ensure()
        runtime.register_tool_with_handler(name, description, input_schema, handler)

    async def load_most_recent_conversation(
        self, *, scope: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """Return the newest conversation; see :meth:`Runtime`."""
        runtime = await self._ensure()
        return runtime.load_most_recent_conversation(scope=scope)

    async def list_models(self, provider_id: Optional[str] = None) -> List[str]:
        """List models from a provider; see :meth:`Runtime.list_models`."""
        runtime = await self._ensure()
        return runtime.list_models(provider_id)

    async def set_trace_callbacks(
        self,
        on_start: Callable[[Dict[str, Any]], None],
        on_end: Callable[[Dict[str, Any], str], None],
    ) -> None:
        """Install a host tracer; see :meth:`Runtime.set_trace_callbacks`."""
        runtime = await self._ensure()
        runtime.set_trace_callbacks(on_start, on_end)

    async def invoke(
        self,
        agent_id: str,
        message: str,
        *,
        save: Optional[bool] = None,
        update_current: Optional[bool] = None,
    ) -> InvokeResult:
        """Invoke an agent and return a typed result.

        Cancelling the asyncio task sets the per-handle cancel flag before the
        cancellation propagates. The runtime observes it at its existing
        cancellation points (chunk/step boundaries). A background drain keeps
        polling until the handle is consumed so a cancelled run does not leak
        its C-side registry slot.
        """
        runtime = await self._ensure()
        save_flag = bool(save) if save is not None else False
        update_flag = bool(update_current) if update_current is not None else True
        handle = runtime.invoke_start(
            agent_id, message, save=save_flag, update_current=update_flag
        )
        try:
            while True:
                # A zero-timeout poll would return immediately without
                # releasing the OCaml runtime; the work-loop domain can then
                # deadlock in a major GC waiting for D0 to acknowledge. A
                # short blocking poll releases the runtime while it parks.
                response = runtime.invoke_poll(handle, _POLL_TIMEOUT_MS)
                status = response.get("status")
                if status == "pending":
                    await asyncio.sleep(0)
                    continue
                if status == "ok":
                    return InvokeResult.from_json(response)
                if status == "cancelled":
                    raise PARInvokeError(
                        f"Invoke cancelled: {response.get('reason', 'User_cancelled')}"
                    )
                raise PARInvokeError(
                    str(response.get("error") or f"Invoke failed: {response}")
                )
        except asyncio.CancelledError:
            runtime.invoke_cancel(handle)
            self._spawn_drain(runtime, handle)
            raise

    def _spawn_drain(self, runtime: Runtime, handle: str) -> None:
        async def drain() -> None:
            try:
                while True:
                    response = runtime.invoke_poll(handle, _POLL_TIMEOUT_MS)
                    if response.get("status") != "pending":
                        return
                    await asyncio.sleep(0)
            except Exception:
                pass

        task = asyncio.create_task(drain())
        self._drain_tasks.add(task)
        task.add_done_callback(self._drain_tasks.discard)

    async def stream(self, agent_id: str, message: str) -> AsyncIterator[Event]:
        """Yield events from one invoke as they are produced."""
        runtime = await self._ensure()
        reader = runtime.invoke_stream(agent_id, message)
        try:
            while not reader.is_done:
                event = reader.poll_chunk(_POLL_TIMEOUT_MS)
                if event is not None:
                    yield event
                else:
                    await asyncio.sleep(0)
        finally:
            # Breaking out of ``async for`` cancels the OCaml stream and frees
            # the per-stream handle.
            reader.close()
