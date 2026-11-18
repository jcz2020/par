"""Typed models (v0.18 W1-S1).

The point of this file is drift detection:

- every model round-trips through its own JSON form;
- ``RuntimeConfig().to_json()`` normalizes to exactly the same OCaml config as
  a hand-written minimal JSON object;
- the OCaml FFI accepts an agent built from the typed models.
"""
import json

import pytest

from par_runtime import (
    AgentConfig,
    Error,
    InvokeResult,
    ModelConfig,
    Runtime,
    RuntimeConfig,
    Sqlite,
    ToolSpec,
    Usage,
)


def test_model_config_round_trip():
    model = ModelConfig(
        model_name="gpt-4o",
        provider="openai",
        api_base="http://127.0.0.1:9/v1",
        temperature=0.2,
        max_tokens=256,
        top_p=0.9,
        stop_sequences=["</end>"],
        thinking_budget_tokens=1024,
        context_window=128000,
    )
    assert ModelConfig.from_json(model.to_json()).to_dict() == model.to_dict()


def test_model_config_defaults_match_ffi():
    model = ModelConfig(model_name="gpt-4o")
    payload = model.to_dict()
    assert payload["provider"] == "openai"
    assert payload["temperature"] == 0.7
    assert payload["api_base"] is None
    assert payload["max_tokens"] is None


def test_tool_spec_default_schema_is_an_object():
    tool = ToolSpec(name="echo")
    assert tool.to_dict()["input_schema"] == {"type": "object"}
    assert ToolSpec.from_json(tool.to_json()).to_dict() == tool.to_dict()


def test_agent_config_round_trip():
    agent = AgentConfig(
        id="assistant",
        system_prompt="You are helpful.",
        model=ModelConfig(model_name="gpt-4o", temperature=0.2),
        tools=[ToolSpec(name="echo", description="Echo input")],
        max_iterations=8,
        max_execution_time=30.0,
        early_stopping_method="generate",
        on_max_tokens="continue",
        max_continuation_chunks=2,
        context_compression_threshold=0.8,
        compression_cooldown_messages=6,
        context_window_override=32000,
    )
    assert AgentConfig.from_json(agent.to_json()).to_dict() == agent.to_dict()


def test_agent_config_accepts_plain_dict_tools():
    agent = AgentConfig(
        id="assistant",
        model=ModelConfig(model_name="gpt-4o"),
        tools=[{"name": "echo", "description": "", "input_schema": {"type": "object"}}],
    )
    assert AgentConfig.from_json(agent.to_json()).to_dict() == agent.to_dict()


def test_runtime_config_defaults_match_json_normalization():
    typed = json.loads(Runtime._normalize_config(json.dumps(RuntimeConfig().to_dict())))
    legacy = json.loads(
        Runtime._normalize_config(json.dumps({"persistence": ["Sqlite", ":memory:"]}))
    )
    assert typed == legacy


def test_runtime_config_round_trip():
    config = RuntimeConfig(
        persistence=Sqlite(":memory:"),
        parallel_tool_execution=False,
        event_retention_seconds=60.0,
        max_tool_schema_tokens=4000,
        bash_confirm={"enabled": True},
        default_quota={"max_concurrent_tasks": 2},
    )
    assert RuntimeConfig.from_json(config.to_json()).to_dict() == config.to_dict()


def test_runtime_config_persistence_accepts_a_path():
    config = RuntimeConfig(persistence="par.db")
    assert config.to_dict()["persistence"] == ["Sqlite", "par.db"]


def test_typed_agent_registers_with_the_runtime():
    agent = AgentConfig(
        id="typed-agent",
        system_prompt="You are a typed fixture.",
        model=ModelConfig(model_name="gpt-4o", temperature=0.0),
    )
    with Runtime(RuntimeConfig().to_json()) as rt:
        rt.register_agent(agent.to_json())


def test_invoke_result_decodes_the_llm_response_envelope():
    raw = {
        "text": "hello",
        "reasoning": [],
        "tool_calls": [
            {"id": "call_1", "name": "echo", "arguments": {"text": "hi"}}
        ],
        "finish_reason": ["Tool_calls"],
        "usage": {
            "prompt_tokens": 5,
            "completion_tokens": 2,
            "total_tokens": 7,
            "cached_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        },
        "model": "gpt-4o",
    }
    result = InvokeResult.from_json(json.dumps(raw))
    assert result.text == "hello"
    assert result.finish_reason == "tool_calls"
    assert result.usage == Usage(prompt_tokens=5, completion_tokens=2, total_tokens=7)
    assert result.tool_calls[0].name == "echo"
    assert result.tool_calls[0].arguments == {"text": "hi"}
    assert InvokeResult.from_json(result.to_json()).to_dict() == result.to_dict()


def test_invoke_result_rejects_an_error_envelope():
    with pytest.raises(ValueError):
        InvokeResult.from_json({"error": "provider exploded"})


def test_error_decodes_both_shapes():
    assert Error.from_json({"error": "boom"}) == Error(message="boom")
    assert Error.from_json({"error": {"message": "boom", "category": "timeout"}}) == Error(
        message="boom", category="timeout"
    )
    assert Error.from_json(Error(message="boom", category="internal").to_json()) == Error(
        message="boom", category="internal"
    )
