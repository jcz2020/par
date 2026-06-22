"""High-level Runtime class wrapping the PAR C FFI."""
import ctypes
import json
import queue
import threading
from dataclasses import dataclass
from typing import Any, Iterator, Optional, Union

from par_runtime._ffi import (
    _lib,
    _c_str,
    _py_str,
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


_DONE = object()


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

    Calls par_invoke_stream on the calling thread (no daemon thread).
    The OCaml work loop buffers chunks internally and returns them all
    with the final result. This iterator then yields each chunk as an
    Event.
    """

    def __init__(self, rt_handle: Any, agent_id: str, message: str):
        self._rt = rt_handle
        self._agent_id = agent_id
        self._message = message
        self._events: list = []
        self._fetched = False

    def _fetch(self) -> None:
        if self._fetched:
            return
        self._fetched = True
        noop_cb = _STREAM_CALLBACK(lambda _data, _ud: None)
        result_ptr = _lib.par_invoke_stream(
            self._rt,
            _c_str(self._agent_id),
            _c_str(self._message),
            noop_cb,
            None,
        )
        raw = _py_str(result_ptr)
        if not raw:
            return
        parsed = json.loads(raw)
        if parsed.get("status") != "ok":
            return
        for item in parsed.get("chunks", []):
            chunk_data = item.get("chunk", item)
            self._events.append(_decode_event(chunk_data))

    def __iter__(self) -> Iterator[Event]:
        self._fetch()
        yield from self._events


class Runtime:
    """PAR Runtime — type-safe agent runtime with formal state guarantees.

    Usage:
        with Runtime('{"persistence": {"sqlite": "par.db"}}') as rt:
            rt.register_tool("echo", "Echoes input", '{"type": "object"}')
            rt.register_agent('{"id": "my-agent", ...}')
            result = rt.invoke("my-agent", "Hello!")
    """

    __slots__ = ("_handle",)

    _callbacks: dict = {}

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

        handler_id = len(Runtime._callbacks)
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

        Mirrors ``Runtime.invoke ~on_chunk`` on the OCaml side. Returns a
        lazy iterator: the underlying OCaml fiber only produces chunk N+1
        when the consumer asks for it via ``next()``. The iterator runs
        the OCaml invoke on a background daemon thread and bridges chunks
        through a bounded queue (maxsize=64, per docs/sdk/streaming.md).

        The CFUNCTYPE callback closure is held alive for the lifetime of
        the returned reader, so the caller may iterate at any pace.

        Raises:
            PARInvokeError: if OCaml returns an error envelope before any
                chunk is produced, or if a chunk callback raises.
            PARError: if the runtime has been shut down.

        Example:
            for event in rt.invoke_stream("agent", "hello"):
                if isinstance(event, TextDelta):
                    print(event.text, end="", flush=True)
        """
        self._check_handle()
        return iter(_StreamReader(self._handle, agent_id, message))

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

    def version() -> str:
        """Return the PAR runtime version string."""
        result_ptr = _lib.par_version()
        return _py_str(result_ptr)

    def __repr__(self) -> str:
        status = "active" if self._handle else "closed"
        return f"<PAR Runtime {status}>"
