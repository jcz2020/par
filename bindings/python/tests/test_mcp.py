"""MCP from Python: configure a server, and hand its tools to an agent.

Before this, a Python program could not use MCP at all: ``Runtime.create`` did
not read ``mcp_servers`` from the config, so no server could be configured, and
there was no way to obtain the descriptors a server exposes. The OCaml surface
had both.

The assertions here are about PAR's own wiring — config parsing, spawning,
listing, descriptor shape. No external MCP server or model provider is
contacted.
"""

import json
import sys
from pathlib import Path

import pytest

from par_runtime import PARInitError, Runtime


def _config(mcp_servers=None) -> str:
    config = {
        "persistence": ["Sqlite", ":memory:"],
        "event_bus": {
            "buffer_capacity": 10,
            "delivery": {
                "max_delivery_attempts": 1,
                "initial_retry_delay": 0.1,
                "retry_backoff": ["Fixed", 0.5],
                "delivery_timeout": 5.0,
            },
            "dlq_enabled": False,
            "critical_event_types": [],
        },
        "default_quota": {"max_concurrent_tasks": 4, "max_concurrent_tools_per_agent": 2},
        "shutdown": {"drain_timeout": 3.0, "cancel_grace_period": 1.0, "flush_batch_size": 100},
        "llm_providers": [],
        "eval_limits": {"max_depth": 10, "max_node_visits": 1000},
        "parallel_tool_execution": True,
        "bash_confirm": {
            "allow_confirm": False, "always_allow": False, "timeout_seconds": 30.0,
        },
        "event_retention_seconds": 604800.0,
    }
    if mcp_servers is not None:
        config["mcp_servers"] = mcp_servers
    return json.dumps(config)


def _mock_server_config() -> dict:
    script = Path(__file__).with_name("mcp_mock_server.py")
    return {
        "type": "stdio",
        "name": "python-mock",
        "command": sys.executable,
        "args": [str(script)],
        "env": {},
        "cwd": None,
        "startup_timeout": 10.0,
    }


@pytest.fixture
def mcp_runtime():
    with Runtime(_config([_mock_server_config()])) as runtime:
        yield runtime


def test_runtime_accepts_mcp_servers(mcp_runtime):
    # The runtime only exists if the server was spawned and handshook; the
    # descriptor list below proves it is reachable. (Runtime.mcp_server looks
    # up the instance-qualified id, which has no public list API yet.)
    assert mcp_runtime.mcp_tool_descriptors()


def test_tool_descriptors_are_listed(mcp_runtime):
    descriptors = mcp_runtime.mcp_tool_descriptors()
    names = sorted(d["name"] for d in descriptors)
    assert names == ["add", "echo"]
    echo = next(d for d in descriptors if d["name"] == "echo")
    assert echo["description"] == "Echoes the message back"
    assert echo["input_schema"]["properties"]["message"]["type"] == "string"


def test_descriptors_can_be_given_to_an_agent(mcp_runtime):
    """The whole point: the descriptor shape is what register_agent reads."""
    descriptors = mcp_runtime.mcp_tool_descriptors()
    # register_agent raises on any descriptor it cannot parse, so returning
    # normally is the assertion.
    mcp_runtime.register_agent(json.dumps({
        "id": "mcp-agent",
        "system_prompt": "Use the tools.",
        "model": {"provider": "openai", "model_name": "unused", "temperature": 0.0},
        "tools": descriptors,
    }))


def test_runtime_without_servers_reports_none():
    with Runtime(_config()) as runtime:
        assert runtime.mcp_tool_descriptors() == []


def test_a_malformed_server_entry_fails_the_init():
    """A bad entry must fail the init, not be silently skipped.

    The init error message is generic ("Failed to initialize PAR runtime") for
    every config problem, so the exception type is the observable contract.
    """
    bad = {"type": "stdio", "name": "broken"}  # no command
    with pytest.raises(PARInitError):
        Runtime(_config([bad]))
