"""High-level Runtime class wrapping the PAR C FFI."""
import ctypes
import itertools
import json
import queue
import threading
from dataclasses import dataclass
from typing import Any, Callable, Iterator, Optional, Union

from par_runtime._ffi import (
    _lib,
    _c_str,
    _py_str,
    _free,
    _PYTHON_TOOL_CALLBACK,
    _STREAM_CALLBACK,
)
from par_runtime._errors import (
    PARError,
    PARInitError,
    PARInvokeError,
    PARToolError,
    PARWorkflowError,
)


@dataclass(frozen=True)
class TextDelta:
    text: str

@dataclass(frozen=True)
class ToolCallStart:
    tool_call_id: str
    name: str

@dataclass(frozen=True)
class ToolCallDelta:
    tool_call_id: str
    args_json: str

@dataclass(frozen=True)
class UsageUpdate:
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int

@dataclass(frozen=True)
class Done:
    finish_reason: str

Event = Union[TextDelta, ToolCallStart, ToolCallDelta, UsageUpdate, Done]


def _decode_event(payload) -> Event:
    """Decode a JSON-decoded llm_response_chunk payload into an Event.

    ppx_deriving_yojson (the version in this repo) encodes variants as
    ``[Constructor, {fields}]``. A future ppx_yojson may switch to
    ``{"tag": "Constructor", ...}``; we accept both so an OCaml upgrade
    does not silently break the Python binding.
    """
    if isinstance(payload, list) and len(payload) == 2:
        tag = payload[0]
        fields = payload[1] if isinstance(payload[1], dict) else {}
    elif isinstance(payload, dict):
        tag = payload.get("tag") or payload.get("constructor")
        fields = payload
    else:
        return TextDelta(text=str(payload))

    if tag == "Text_delta":
        return TextDelta(text=fields.get("text", ""))
    if tag == "Tool_call_start":
        return ToolCallStart(
            tool_call_id=fields.get("tool_call_id", ""),
            name=fields.get("name", ""),
        )
    if tag == "Tool_call_delta":
        return ToolCallDelta(
            tool_call_id=fields.get("tool_call_id", ""),
            args_json=fields.get("args_json", ""),
        )
    if tag == "Usage_update":
        return UsageUpdate(
            prompt_tokens=int(fields.get("prompt_tokens", 0)),
            completion_tokens=int(fields.get("completion_tokens", 0)),
            total_tokens=int(fields.get("total_tokens", 0)),
        )
    if tag == "Done":
        finish_reason = fields.get("finish_reason", "stop")
        # finish_reason is itself a polymorphic variant: ["Stop"], ["Tool_calls"]
        if isinstance(finish_reason, list) and finish_reason:
            finish_reason = finish_reason[0]
        return Done(finish_reason=str(finish_reason).lower())
    return TextDelta(text=str(payload))


class _StreamReader:
    """Iterator over streaming chunks from a single invoke_stream call.

    v0.5.3: True incremental streaming. ``par_invoke_stream`` runs in a
    background daemon thread; the ctypes closure pushes each JSON chunk
    onto a ``queue.Queue`` as the OCaml SSE parser produces it. The
    iterator's ``__next__`` consumes the queue concurrently, so chunks
    are delivered to the caller in real time — not buffered until the
    LLM completes. The terminal ``Done`` event signals iteration end.

    v0.5.4: ``cancel()`` interrupts an in-flight stream. The caller (or
    the runtime's ``__del__`` when the reader is garbage-collected) sets
    a process-global atomic flag via ``par_cancel_stream``; the OCaml
    ``on_chunk`` callback checks it at the next chunk boundary and
    aborts the stream, releasing ``ocaml_lock`` promptly (typically
    within 50-300ms).

    Threading model: the background thread holds the C ``ocaml_lock``
    for the duration of ``par_invoke_stream``. The ctypes closure is
    fired from the OCaml Eio domain (a separate OCaml Domain) which
    acquires the GIL to run the Python callback. The callback only
    does ``queue.put_nowait`` (non-blocking, unbounded) and never
    re-enters ``par_*``, so no deadlock is possible. ``cancel()`` is
    safe to call from any thread (it does NOT take ``ocaml_lock`` —
    it sets a lock-free flag instead).
    """

    _DONE_SENTINEL = object()

    def __init__(self, rt_handle: Any, agent_id: str, message: str,
                 *, queue_timeout: float = 60.0,
                 _inject_queue: Optional["queue.Queue"] = None,
                 _inject_error: Optional[BaseException] = None,
                 _inject_final_result: Optional[str] = None,
                 cancel_fn: Optional[Callable[[], None]] = None):
        self._rt = rt_handle
        self._agent_id = agent_id
        self._message = message
        self._queue: queue.Queue = _inject_queue if _inject_queue is not None else queue.Queue()
        self._error: Optional[BaseException] = _inject_error
        self._queue_timeout = queue_timeout
        self._fetched = _inject_queue is not None
        self._final_result: Optional[str] = _inject_final_result
        self._fetch_thread: Optional[threading.Thread] = None
        self._cancel_fn = cancel_fn
        self._cancel_called = False
        self._cancelled = False
        self._completed = False
        self._finished = False
        if _inject_queue is not None and _inject_error is None:
            # Injected-queue mode (used by tests): signal done immediately
            # so iteration terminates naturally without spawning a thread.
            self._queue.put_nowait(self._DONE_SENTINEL)

    def cancel(self) -> None:
        """Interrupt the in-flight stream, if any.

        Sets a process-global atomic flag read by the OCaml ``on_chunk``
        callback at the next chunk boundary; the stream then aborts and
        ``ocaml_lock`` is released. Idempotent: a no-op if there is no
        stream in flight, no ``cancel_fn`` was supplied, the stream
        already completed normally, or cancel was already requested.
        Safe to call from any thread.
        """
        if (self._cancel_fn is None or self._cancel_called
                or self._completed):
            return
        self._cancel_called = True
        try:
            self._cancel_fn()
        except Exception:
            # Swallow: cancel is best-effort. A failure here (e.g. the
            # runtime already shut down) must not mask the caller's
            # original control flow.
            pass

    def __del__(self):
        # GC may run on any thread (e.g. a non-FFI pthread). If the caller
        # dropped the reader without consuming it fully, cancel the
        # in-flight stream so ocaml_lock is released rather than held
        # until the LLM finishes naturally. par_cancel_stream is
        # signal/thread-safe, so this is safe from __del__.
        try:
            self.cancel()
        except Exception:
            pass

    def _push_chunk(self, json_chunk: bytes, _user_data: Any) -> None:
        """ctypes callback fired by par_invoke_stream for each chunk.

        Runs on the OCaml Eio domain thread (which acquired the GIL via
        ctypes CFUNCTYPE dispatch). The callback must be non-blocking
        and must not call back into par_* (would deadlock on ocaml_lock
        held by the fetch thread).
        """
        try:
            self._queue.put_nowait(json_chunk)
        except queue.Full:
            pass

    def _do_fetch(self) -> None:
        """Run par_invoke_stream and push terminal sentinel on completion.

        Runs in a background daemon thread so __iter__ can consume the
        queue concurrently. Any exception is stashed in self._error and
        the sentinel is always pushed so __iter__ unblocks.
        """
        def _wrapper(json_chunk, user_data):
            self._push_chunk(json_chunk, user_data)

        cb = _STREAM_CALLBACK(_wrapper)
        try:
            result_ptr = _lib.par_invoke_stream(
                self._rt,
                _c_str(self._agent_id),
                _c_str(self._message),
                cb,
                None,
            )
            raw = _py_str(result_ptr)
        except BaseException as e:
            self._error = e
            self._queue.put_nowait(self._DONE_SENTINEL)
            return

        if not raw:
            self._error = PARInvokeError("invoke_stream returned empty result")
        else:
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError as e:
                self._error = PARInvokeError(f"invoke_stream returned invalid JSON: {e}")
            else:
                status = parsed.get("status")
                if status == "ok":
                    self._final_result = raw
                elif status == "cancelled":
                    # Cancellation is an expected outcome (par_cancel_stream),
                    # not a failure: the stream returned cleanly and released
                    # ocaml_lock. Surface the partial result and end iteration
                    # normally rather than raising.
                    self._cancelled = True
                    self._final_result = raw
                else:
                    err = parsed.get("error", "unknown error")
                    self._error = PARInvokeError(f"invoke_stream failed: {err}")
        self._queue.put_nowait(self._DONE_SENTINEL)

    def _start_fetch(self) -> None:
        if self._fetched:
            return
        self._fetched = True
        self._fetch_thread = threading.Thread(target=self._do_fetch, daemon=True)
        self._fetch_thread.start()

    def __iter__(self) -> Iterator[Event]:
        self._start_fetch()
        try:
            while True:
                try:
                    item = self._queue.get(timeout=self._queue_timeout)
                except queue.Empty:
                    raise PARInvokeError(
                        f"invoke_stream timed out after {self._queue_timeout}s "
                        "waiting for next chunk"
                    )
                if item is self._DONE_SENTINEL:
                    if self._fetch_thread is not None:
                        self._fetch_thread.join(timeout=5.0)
                    if self._error is not None:
                        raise self._error
                    self._completed = True
                    return
                try:
                    payload = json.loads(item) if isinstance(item, (bytes, str)) else item
                    yield _decode_event(payload)
                except json.JSONDecodeError as e:
                    raise PARInvokeError(f"invoke_stream chunk was invalid JSON: {e}")
        finally:
            # Covers three exit paths: normal completion (_completed=True,
            # cancel is a no-op), caller `break`/scope-exit (GeneratorExit
            # lands here with _completed=False — cancel the in-flight
            # stream so ocaml_lock is released), and error/timeout. This
            # is what actually closes the v0.5.3 "break early blocks
            # subsequent calls" limitation: __del__ alone cannot, because
            # the background fetch thread holds a reference to the reader
            # and keeps it alive past the caller's `del`.
            self._finished = True
            self.cancel()


class Runtime:
    """PAR Runtime — type-safe agent runtime with formal state guarantees.

    Usage:
        with Runtime('{"persistence": {"sqlite": "par.db"}}') as rt:
            rt.register_tool("echo", "Echoes input", '{"type": "object"}')
            rt.register_agent('{"id": "my-agent", ...}')
            result = rt.invoke("my-agent", "Hello!")
    """

    __slots__ = ("_handle", "_callback_ids")

    _callbacks: dict = {}
    _callback_counter = itertools.count()

    def __init__(self, config_json: str):
        """Initialize PAR runtime from JSON config string.

        Args:
            config_json: Runtime configuration as JSON string.

        Raises:
            PARInitError: If initialization fails.
        """
        normalized = self._normalize_config(config_json)
        handle = _lib.par_init(_c_str(normalized))
        if not handle:
            raise PARInitError("Failed to initialize PAR runtime")
        self._handle: Any = handle
        self._callback_ids: set = set()

    @staticmethod
    def _normalize_config(config_json: str) -> str:
        """Fill in required OCaml runtime_config fields that the Python
        caller may have omitted, so that the OCaml yojson decoder accepts
        the payload. Returns the original JSON if it already parses.
        """
        try:
            cfg = json.loads(config_json)
        except json.JSONDecodeError as e:
            raise PARInitError(f"config_json is not valid JSON: {e}")
        if not isinstance(cfg, dict):
            raise PARInitError("config_json must decode to a JSON object")

        defaults = {
            "default_quota": {
                "max_concurrent_tasks": 4,
                "max_concurrent_tools_per_agent": 2,
                "max_tokens_per_turn": None,
                "max_total_tokens": None,
            },
            "shutdown": {
                "drain_timeout": 5.0,
                "cancel_grace_period": 2.0,
                "flush_batch_size": 100,
            },
            "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
            "llm_providers": [],
            "parallel_tool_execution": True,
            "event_retention_seconds": 604800.0,
        }
        for key, default in defaults.items():
            if key not in cfg:
                cfg[key] = default
            elif isinstance(default, dict) and isinstance(cfg[key], dict):
                for sub_key, sub_default in default.items():
                    cfg[key].setdefault(sub_key, sub_default)
        if "event_bus" in cfg and isinstance(cfg["event_bus"], dict):
            cfg["event_bus"].setdefault("buffer_capacity", 100)
            cfg["event_bus"].setdefault("dlq_enabled", False)
            cfg["event_bus"].setdefault("dlq_max_size", 10)
            cfg["event_bus"].setdefault("critical_event_types", [])
            if isinstance(cfg["event_bus"].get("delivery"), dict):
                cfg["event_bus"]["delivery"].setdefault("max_delivery_attempts", 3)
                cfg["event_bus"]["delivery"].setdefault("initial_retry_delay", 0.1)
                cfg["event_bus"]["delivery"].setdefault("retry_backoff", ["Fixed", 0.5])
                cfg["event_bus"]["delivery"].setdefault("delivery_timeout", 5.0)
        return json.dumps(cfg)

    def __enter__(self) -> "Runtime":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def __del__(self):
        if hasattr(self, "_handle"):
            self.close()

    def close(self):
        """Shut down the runtime and release resources."""
        if getattr(self, "_handle", None):
            _lib.par_shutdown(self._handle)
            self._handle = None
        for cb_id in getattr(self, "_callback_ids", ()):
            Runtime._callbacks.pop(cb_id, None)
        if hasattr(self, "_callback_ids"):
            self._callback_ids.clear()

    def _check_handle(self):
        if not self._handle:
            raise PARError("Runtime has been shut down")

    def register_tool(self, name: str, description: str, input_schema: str) -> None:
        """Register a tool with the runtime.

        Args:
            name: Tool name.
            description: Tool description.
            input_schema: JSON Schema for tool input.

        Raises:
            PARToolError: If registration fails.
        """
        self._check_handle()
        result = _lib.par_register_tool(
            self._handle,
            _c_str(name),
            _c_str(description),
            _c_str(input_schema),
        )
        if result != 0:
            raise PARToolError(f"Failed to register tool: {name}")

    def register_tool_with_handler(self, name: str, description: str,
                                   input_schema: str, handler) -> None:
        """Register a tool with a Python callback handler.

        Args:
            name: Tool name.
            description: Tool description.
            input_schema: JSON Schema for tool input.
            handler: Python callable (str) -> str that processes tool input
                     JSON and returns output JSON.

        Raises:
            PARToolError: If registration fails.
        """
        self._check_handle()

        def _wrapper(handler_id: int, input_json: bytes) -> bytes:
            try:
                result = handler(input_json.decode("utf-8"))
                return result.encode("utf-8")
            except Exception as e:
                return json.dumps({"error": str(e)}).encode("utf-8")

        c_callback = _PYTHON_TOOL_CALLBACK(_wrapper)

        handler_id = next(Runtime._callback_counter)
        Runtime._callbacks[handler_id] = c_callback

        _lib.par_store_python_handler(handler_id, c_callback)

        result = _lib.par_register_tool_with_handler(
            self._handle,
            _c_str(name),
            _c_str(description),
            _c_str(input_schema),
            handler_id,
        )
        if result != 0:
            Runtime._callbacks.pop(handler_id, None)
            raise PARToolError(f"Failed to register tool with handler: {name}")
        self._callback_ids.add(handler_id)

    def register_agent(self, config_json: str) -> None:
        """Register an agent from JSON config.

        Args:
            config_json: Agent configuration as JSON string.

        Raises:
            PARError: If registration fails.
        """
        self._check_handle()
        result = _lib.par_register_agent(self._handle, _c_str(config_json))
        if result != 0:
            raise PARError("Failed to register agent")

    def register_skill(self, descriptor_json: str) -> None:
        self._check_handle()
        result = _lib.par_register_skill(self._handle, _c_str(descriptor_json))
        if result != 0:
            raise PARError(f"Failed to register skill (code {result})")

    def list_skills(self) -> list:
        self._check_handle()
        ptr = _lib.par_list_skills(self._handle)
        if not ptr:
            return []
        try:
            raw = ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8")
            return json.loads(raw) if raw else []
        finally:
            _free(ptr)

    def list_llm_providers(self) -> list[str]:
        """List registered LLM provider ids (v0.5.4 PAR-tiu)."""
        self._check_handle()
        ptr = _lib.par_list_llm_providers(self._handle)
        if not ptr:
            return []
        try:
            raw = ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8")
            return json.loads(raw) if raw else []
        finally:
            _free(ptr)

    def set_default_llm_provider(self, provider_id: str) -> None:
        """Switch the default LLM provider (v0.5.4 PAR-tiu).

        Raises PARError if [provider_id] is not registered.
        """
        self._check_handle()
        rc = _lib.par_set_default_llm_provider(
            self._handle, _c_str(provider_id))
        if rc != 0:
            raise PARError(
                f"set_default_llm_provider failed: {provider_id!r}")

    def set_session_id(self, session_id: str) -> None:
        """Set the session id for this runtime (v0.5.4 PAR-mkm)."""
        self._check_handle()
        _lib.par_set_session_id(self._handle, _c_str(session_id))

    def get_session_id(self) -> str:
        """Return the current session id, lazy-initializing if needed."""
        self._check_handle()
        ptr = _lib.par_get_session_id(self._handle)
        if not ptr:
            return ""
        try:
            return ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8")
        finally:
            _free(ptr)

    def save_conversation(self) -> int:
        """Persist the current conversation. Returns 0 on success."""
        self._check_handle()
        return _lib.par_save_conversation(self._handle)

    def load_conversation(self, session_id: str):
        """Load a conversation by session id. Returns None if not found."""
        self._check_handle()
        rc = _lib.par_load_conversation(
            self._handle, _c_str(session_id))
        if rc == 0:
            return True
        return None

    def invoke(self, agent_id: str, message: str) -> str:
        """Invoke an agent synchronously.

        Args:
            agent_id: The agent's identifier.
            message: The user message.

        Returns:
            JSON response string.

        Raises:
            PARInvokeError: If invocation fails.
        """
        self._check_handle()
        result_ptr = _lib.par_invoke(
            self._handle, _c_str(agent_id), _c_str(message)
        )
        result = _py_str(result_ptr)
        if not result:
            raise PARInvokeError(f"Invoke failed for agent: {agent_id}")
        try:
            parsed = json.loads(result)
            if isinstance(parsed, dict) and "error" in parsed:
                raise PARInvokeError(parsed["error"])
        except json.JSONDecodeError:
            pass
        return result

    def embed(self, messages: list[str]) -> list[list[float]]:
        """Embed a batch of texts.

        Args:
            messages: List of text strings to embed.

        Returns:
            List of embedding vectors (each a list of floats).

        Raises:
            PARError: If embedding fails.
        """
        self._check_handle()
        messages_json = json.dumps(messages)
        result_ptr = _lib.par_embed(self._handle, _c_str(messages_json))
        result = _py_str(result_ptr)
        if not result:
            raise PARError("Embed failed: null result from runtime")
        parsed = json.loads(result)
        if isinstance(parsed, dict) and "error" in parsed:
            raise PARError(parsed["error"])
        return [[float(x) for x in vec] for vec in parsed]

    def add_documents(self, documents: list[str | dict]) -> int:
        """Add documents to the runtime's internal vector store for RAG.

        Documents are embedded via the configured provider and stored
        in an in-memory sqlite-vec index. The vector store is created
        lazily on first call.

        Args:
            documents: List of text strings or dicts with id/content/metadata.

        Returns:
            Number of documents added.

        Raises:
            PARError: If embedding or storage fails.
        """
        self._check_handle()
        docs_json = json.dumps(documents)
        result = _lib.par_add_documents(self._handle, _c_str(docs_json))
        if result < 0:
            raise PARError(f"add_documents failed with code {result}")
        return result

    def invoke_with_rag(self, agent_id: str, message: str, k: int = 4) -> str:
        """Invoke an agent with RAG-augmented context.

        Embeds the query, retrieves top-k documents from the internal
        vector store, augments the prompt with retrieved context, and
        invokes the agent.

        Args:
            agent_id: The agent's identifier.
            message: The user message.
            k: Number of documents to retrieve (default 4).

        Returns:
            JSON response string.

        Raises:
            PARError: If invocation fails.
        """
        self._check_handle()
        result_ptr = _lib.par_invoke_with_rag(
            self._handle, _c_str(agent_id), _c_str(message), _c_str(str(k))
        )
        result = _py_str(result_ptr)
        if not result:
            raise PARError(f"invoke_with_rag failed for agent: {agent_id}")
        try:
            parsed = json.loads(result)
            if isinstance(parsed, dict) and "error" in parsed:
                raise PARError(parsed["error"])
        except json.JSONDecodeError:
            pass
        return result

    def invoke_stream(self, agent_id: str, message: str) -> Iterator[Event]:
        """Invoke an agent and yield each LLM response chunk as an Event.

        v0.5.3: True incremental streaming. ``par_invoke_stream`` runs in
        a background daemon thread; the OCaml SSE parser fires a ctypes
        callback for each chunk as the LLM produces it, which pushes onto
        a ``queue.Queue``. This generator consumes the queue concurrently,
        so chunks are delivered in real time — the first token arrives
        within milliseconds of the LLM producing it, not after the full
        response completes.

        .. note::

            v0.5.4: ``break``-ing early from this iterator (or letting it
            go out of scope) now cancels the in-flight stream via
            ``par_cancel_stream`` — the background thread's ``ocaml_lock``
            is released at the next chunk boundary (typically 50-300ms),
            so subsequent ``par_*`` calls no longer block until the LLM
            finishes naturally. You can also call ``self.cancel_stream()``
            explicitly to interrupt a stream started elsewhere. (In
            v0.5.3, breaking early left the lock held for the whole
            remaining stream duration.)

        Raises:
            PARInvokeError: if OCaml returns an error or the queue times out.
            PARError: if the runtime has been shut down.

        Example:
            for event in rt.invoke_stream("agent", "hello"):
                if isinstance(event, TextDelta):
                    print(event.text, end="", flush=True)
        """
        self._check_handle()
        handle = self._handle
        return iter(_StreamReader(handle, agent_id, message,
                                  cancel_fn=lambda: _lib.par_cancel_stream(handle)))

    def cancel_stream(self) -> None:
        """Cancel any in-flight ``invoke_stream`` on this runtime.

        Sets a process-global atomic flag read by the OCaml ``on_chunk``
        callback at the next chunk boundary; the stream then aborts and
        the process-global ``ocaml_lock`` is released, unblocking
        subsequent ``par_*`` calls.

        Takes effect at the next chunk boundary (typically 50-300ms for
        streaming providers, ~1s worst case for slow providers) — NOT
        immediately, because the LLM stream must reach a chunk boundary
        for the flag to be observed.

        Safe to call from any thread (including Python's GC-triggered
        ``__del__`` on a non-FFI pthread): it does NOT acquire
        ``ocaml_lock`` (which is held by the in-flight stream) — it
        performs a single lock-free atomic store instead.

        A no-op if no stream is in flight. Idempotent.
        """
        self._check_handle()
        _lib.par_cancel_stream(self._handle)

    def invoke_structured(self, agent_id: str, message: str,
                          response_schema: dict) -> dict:
        """Invoke an agent with structured output constraint.

        Args:
            agent_id: The agent's identifier.
            message: The user message.
            response_schema: JSON Schema dict describing the desired output.

        Returns:
            Parsed JSON dict matching response_schema.

        Raises:
            PARInvokeError: If invocation fails or output doesn't match schema.
        """
        self._check_handle()
        schema_json = json.dumps(response_schema)
        result_ptr = _lib.par_invoke_structured(
            self._handle, _c_str(agent_id), _c_str(message), _c_str(schema_json)
        )
        result = _py_str(result_ptr)
        if not result:
            raise PARInvokeError(f"Invoke_structured failed for agent: {agent_id}")
        try:
            parsed = json.loads(result)
            if isinstance(parsed, dict) and "status" in parsed:
                if parsed["status"] == "ok":
                    return json.loads(parsed["value"])
                if "message" in parsed:
                    raise PARInvokeError(parsed["message"])
            if isinstance(parsed, dict) and "error" in parsed:
                raise PARInvokeError(parsed["error"])
        except json.JSONDecodeError:
            pass
        raise PARInvokeError(f"Invoke_structured returned unexpected: {result}")

    def submit_workflow(self, workflow_json: str) -> str:
        """Submit a workflow for execution.

        Args:
            workflow_json: Workflow definition as JSON string.

        Returns:
            JSON result string.

        Raises:
            PARWorkflowError: If submission fails.
        """
        self._check_handle()
        result_ptr = _lib.par_submit_workflow(
            self._handle, _c_str(workflow_json)
        )
        result = _py_str(result_ptr)
        try:
            parsed = json.loads(result)
            if isinstance(parsed, dict) and "error" in parsed:
                raise PARWorkflowError(parsed["error"])
        except json.JSONDecodeError:
            pass
        return result

    def approve_workflow(self, run_id: str, approver: str) -> None:
        """Approve a pending workflow step.

        Args:
            run_id: Workflow run identifier.
            approver: Approver identity.

        Raises:
            PARWorkflowError: If approval fails.
        """
        self._check_handle()
        result = _lib.par_approve_workflow(
            self._handle, _c_str(run_id), _c_str(approver)
        )
        if result != 0:
            raise PARWorkflowError(f"Failed to approve workflow: {run_id}")

    def resume_workflow(self, run_id: str) -> str:
        """Resume a paused workflow.

        Args:
            run_id: Workflow run identifier.

        Returns:
            JSON result string.

        Raises:
            PARWorkflowError: If resume fails.
        """
        self._check_handle()
        result_ptr = _lib.par_resume_workflow(
            self._handle, _c_str(run_id)
        )
        return _py_str(result_ptr)

    def health(self) -> dict:
        """Return runtime health status.

        Returns:
            Dict with keys: runtime_alive (bool), persistence_ok (bool),
            last_llm_call_at (float|None), last_llm_call_status (str).
        """
        self._check_handle()
        result_ptr = _lib.par_health(self._handle)
        result = _py_str(result_ptr)
        if not result:
            raise PARError("health() returned empty")
        try:
            parsed = json.loads(result)
            if "error" in parsed:
                raise PARError(parsed["error"])
            return parsed
        except json.JSONDecodeError as e:
            raise PARError(f"Invalid health JSON: {e}")

    def metrics(self) -> dict:
        """Return runtime metrics snapshot.

        Returns:
            Dict with keys: llm_requests_total, task_completed_total,
            task_failed_total, tool_invocations_total,
            events_published_total, events_dropped_total.
        """
        self._check_handle()
        result_ptr = _lib.par_metrics(self._handle)
        result = _py_str(result_ptr)
        if not result:
            raise PARError("metrics() returned empty")
        try:
            parsed = json.loads(result)
            if "error" in parsed:
                raise PARError(parsed["error"])
            return parsed.get("metrics", parsed)
        except json.JSONDecodeError as e:
            raise PARError(f"Invalid metrics JSON: {e}")

    def steer(self, message: str) -> None:
        """Inject a steering message into the agent's running loop.

        Args:
            message: User message to inject.

        Raises:
            PARError: If steering fails.
        """
        self._check_handle()
        rc = _lib.par_steer(self._handle, _c_str(message))
        if rc != 0:
            raise PARError(f"steer() failed with code {rc}")

    def follow_up(self, message: str) -> None:
        """Queue a follow-up message for after the agent's current loop ends."""
        self._check_handle()
        rc = _lib.par_follow_up(self._handle, _c_str(message))
        if rc != 0:
            raise PARError(f"follow_up() failed with code {rc}")

    def mcp_server(self, server_id: str) -> dict:
        """Query an MCP server's tools by server ID.

        Args:
            server_id: Name of the MCP server to query.

        Returns:
            dict with server_id and tools list.

        Raises:
            PARError: If server not found or query fails.
        """
        self._check_handle()
        result_ptr = _lib.par_mcp_server(self._handle, _c_str(server_id))
        result = _py_str(result_ptr)
        parsed = json.loads(result)
        if "error" in parsed:
            raise PARError(parsed["error"])
        return parsed

    def mcp_list_tools(self, server_id: str) -> list:
        """List tools available on an MCP server.

        Args:
            server_id: Name of the MCP server.

        Returns:
            list of dicts with tool name and description.

        Raises:
            PARError: If server not found or query fails.
        """
        self._check_handle()
        result_ptr = _lib.par_mcp_list_tools(self._handle, _c_str(server_id))
        result = _py_str(result_ptr)
        parsed = json.loads(result)
        if "error" in parsed:
            raise PARError(parsed["error"])
        return parsed.get("tools", [])

    def workflow_status(self, run_id: str) -> dict:
        """Query the status of a workflow run.

        Args:
            run_id: ID of the workflow run.

        Returns:
            dict with run_id and status.

        Raises:
            PARError: If query fails.
        """
        self._check_handle()
        result_ptr = _lib.par_workflow_status(self._handle, _c_str(run_id))
        result = _py_str(result_ptr)
        parsed = json.loads(result)
        if "error" in parsed:
            raise PARError(parsed["error"])
        return parsed

    def workflow_cancel(self, run_id: str) -> None:
        """Cancel a running workflow.

        Args:
            run_id: ID of the workflow run to cancel.

        Raises:
            PARWorkflowError: If cancellation fails.
        """
        self._check_handle()
        rc = _lib.par_workflow_cancel(self._handle, _c_str(run_id))
        if rc != 0:
            raise PARWorkflowError(f"workflow_cancel({run_id}) failed")

    @staticmethod
    def version() -> str:
        """Return the PAR runtime version string."""
        result_ptr = _lib.par_version()
        return _py_str(result_ptr)

    def __repr__(self) -> str:
        status = "active" if self._handle else "closed"
        return f"<PAR Runtime {status}>"
