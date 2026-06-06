"""High-level Runtime class wrapping the PAR C FFI."""
import json
from typing import Any, Optional

from par_runtime._ffi import _lib, _c_str, _py_str
from par_runtime._errors import (
    PARError,
    PARInitError,
    PARInvokeError,
    PARToolError,
    PARWorkflowError,
)


class Runtime:
    """PAR Runtime — type-safe agent runtime with formal state guarantees.

    Usage:
        with Runtime('{"persistence": {"sqlite": "par.db"}}') as rt:
            rt.register_tool("echo", "Echoes input", '{"type": "object"}')
            rt.register_agent('{"id": "my-agent", ...}')
            result = rt.invoke("my-agent", "Hello!")
    """

    __slots__ = ("_handle",)

    def __init__(self, config_json: str):
        """Initialize PAR runtime from JSON config string.

        Args:
            config_json: Runtime configuration as JSON string.

        Raises:
            PARInitError: If initialization fails.
        """
        handle = _lib.par_init(_c_str(config_json))
        if not handle:
            raise PARInitError("Failed to initialize PAR runtime")
        self._handle: Any = handle

    def __enter__(self) -> "Runtime":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def __del__(self):
        self.close()

    def close(self):
        """Shut down the runtime and release resources."""
        if self._handle:
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
        self._check_handle()
        result_ptr = _lib.par_mcp_server(self._handle, _c_str(server_id))
        result = _py_str(result_ptr)
        parsed = json.loads(result)
        if "error" in parsed:
            raise PARError(parsed["error"])
        return parsed

    def mcp_list_tools(self, server_id: str) -> list:
        self._check_handle()
        result_ptr = _lib.par_mcp_list_tools(self._handle, _c_str(server_id))
        result = _py_str(result_ptr)
        parsed = json.loads(result)
        if "error" in parsed:
            raise PARError(parsed["error"])
        return parsed.get("tools", [])

    def workflow_status(self, run_id: str) -> dict:
        self._check_handle()
        result_ptr = _lib.par_workflow_status(self._handle, _c_str(run_id))
        result = _py_str(result_ptr)
        parsed = json.loads(result)
        if "error" in parsed:
            raise PARError(parsed["error"])
        return parsed

    def workflow_cancel(self, run_id: str) -> None:
        self._check_handle()
        rc = _lib.par_workflow_cancel(self._handle, _c_str(run_id))
        if rc != 0:
            raise PARWorkflowError(f"workflow_cancel({run_id}) failed")

    @staticmethod
    def version() -> str:
        result_ptr = _lib.par_version()
        return _py_str(result_ptr)

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
