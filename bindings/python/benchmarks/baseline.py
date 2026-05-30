"""Pure Python ReAct agent baseline for FFI overhead comparison.

Provides the same API surface as par_runtime.Runtime but implemented
entirely in Python. Uses scripted mock responses (no network/IO).
This isolates the Python-side work from the FFI transport cost.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any


@dataclass
class MockToolCall:
    """Simulated tool call from LLM response."""

    name: str
    arguments: dict[str, Any]


@dataclass
class MockResponse:
    """Scripted LLM response (mirrors OCaml mock_provider variants)."""

    text: str | None = None
    tool_calls: list[MockToolCall] | None = None
    error: str | None = None


class ToolRegistry:
    """Simple tool registry matching PAR's tool registration."""

    def __init__(self) -> None:
        self._tools: dict[str, dict[str, str]] = {}

    def register(self, name: str, description: str, schema: str) -> None:
        self._tools[name] = {"description": description, "schema": schema}

    def get(self, name: str) -> dict[str, str] | None:
        return self._tools.get(name)

    @property
    def count(self) -> int:
        return len(self._tools)

    def first_name(self) -> str | None:
        """Return the name of the first registered tool, or None."""
        return next(iter(self._tools), None)


class PurePythonRuntime:
    """Pure Python agent runtime matching par_runtime.Runtime API.

    Simulates the ReAct loop without FFI overhead:
    - Parse user message
    - Select tool (scripted response)
    - Execute tool
    - Return JSON result

    All responses are deterministic. No network, no IO, no external deps.
    """

    def __init__(self, config_json: str) -> None:
        """Initialize runtime from JSON config string."""
        self._config = json.loads(config_json)
        self._tools = ToolRegistry()
        self._closed = False
        self._call_count = 0
        # Simulate config parsing work (matches OCaml runtime init)
        self._persistence = self._config.get("persistence", {})
        self._quota = self._config.get("default_quota", {})
        self._shutdown_cfg = self._config.get("shutdown", {})
        self._event_bus = self._config.get("event_bus", {})
        # Pre-extract nested values to simulate OCaml variant parsing
        _ = self._persistence.get("tag")
        _ = self._persistence.get("contents")
        _ = self._quota.get("max_tokens")
        _ = self._quota.get("max_iterations")
        _ = self._shutdown_cfg.get("grace_period_seconds")
        _ = self._event_bus.get("max_queue_size")
        _ = self._event_bus.get("dlq_enabled")

    def close(self) -> None:
        """Shutdown runtime."""
        if not self._closed:
            self._closed = True

    def register_tool(self, name: str, description: str, schema: str) -> None:
        """Register a tool (mirrors par_runtime.Runtime.register_tool)."""
        if self._closed:
            raise RuntimeError("Runtime is closed")
        self._tools.register(name, description, schema)

    def invoke(self, agent_id: str, message: str) -> str:
        """Invoke agent with message (mirrors par_runtime.Runtime.invoke).

        Simulates the ReAct loop:
        1. Parse message -> extract intent
        2. Look up matching tool
        3. Execute tool with mock arguments
        4. Return JSON result string
        """
        if self._closed:
            raise RuntimeError("Runtime is closed")

        self._call_count += 1

        # Simulate ReAct parsing work (string operations)
        _tokens = message.split()
        _char_count = len(message)
        _ = message.lower()[:64]

        if self._tools.count == 0:
            return json.dumps({"status": "error", "error": "No tools registered"})

        # Select tool (simulates OCaml tool selection logic)
        tool_name = self._tools.first_name()
        if tool_name is None:
            return json.dumps({"status": "error", "error": "Tool registry empty"})
        tool_info = self._tools.get(tool_name)
        if tool_info is None:
            return json.dumps({"status": "error", "error": f"Tool {tool_name} not found"})

        # Simulate tool schema validation (parse JSON schema)
        _schema_obj = json.loads(tool_info["schema"])
        _param_count = len(_schema_obj.get("properties", {}))

        # Build mock tool execution result
        mock_args = {k: f"mock_value_{self._call_count}" for k in _schema_obj.get("properties", {}).keys()}

        result = {
            "status": "success",
            "agent_id": agent_id,
            "message": message,
            "tool_used": tool_name,
            "tool_args": mock_args,
            "iteration": self._call_count,
            "response": f"Mock response for: {message[:50]}",
        }

        # Serialize (matches OCaml Yojson serialization)
        return json.dumps(result)

    def __enter__(self) -> PurePythonRuntime:
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()

    def __repr__(self) -> str:
        state = "closed" if self._closed else "active"
        return f"<PurePythonRuntime {state} tools={self._tools.count} calls={self._call_count}>"


def _default_config() -> str:
    """Generate a default config matching test_runtime.py format."""
    return json.dumps(
        {
            "persistence": {"tag": "sqlite", "contents": ":memory:"},
            "event_bus": {
                "max_queue_size": 100,
                "dlq_enabled": False,
                "dlq_max_size": 10,
            },
            "default_quota": {
                "max_tokens": 4096,
                "max_iterations": 10,
                "timeout_seconds": 30.0,
            },
            "shutdown": {
                "grace_period_seconds": 5.0,
                "force_after_seconds": 10.0,
            },
            "llm_providers": [],
        }
    )
