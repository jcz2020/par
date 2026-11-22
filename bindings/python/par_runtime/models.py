"""Typed request/response models for the PAR Python binding (v0.18 W1).

JSON stays at the FFI boundary: these dataclasses build the exact payload the
OCaml runtime decodes and parse the envelopes it returns. Defaults mirror
``Runtime._normalize_config`` and ``lib/ffi/par_capi.ml`` so a typed call and a
hand-written JSON call produce the same runtime configuration; the
equivalence tests in ``tests/test_models.py`` lock that promise.

Nothing here imports :mod:`par_runtime.runtime`, so the models can be used
(and tested) without loading ``par_capi.so``.
"""
import json
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple, TypedDict, Union

__all__ = [
    "Sqlite",
    "ModelConfig",
    "ToolSpec",
    "AgentConfig",
    "RuntimeConfig",
    "MCPSampling",
    "Usage",
    "ToolCall",
    "InvokeResult",
    "Error",
    "RUNTIME_CONFIG_DEFAULTS",
]

# Defaults copied from Runtime._normalize_config. Kept as module constants so
# the equivalence tests have one object to compare against instead of
# re-listing the numbers.
DEFAULT_QUOTA: Dict[str, Any] = {
    "max_concurrent_tasks": 4,
    "max_concurrent_tools_per_agent": 2,
    "max_tokens_per_turn": None,
    "max_total_tokens": None,
}

DEFAULT_SHUTDOWN: Dict[str, Any] = {
    "drain_timeout": 5.0,
    "cancel_grace_period": 2.0,
    "flush_batch_size": 100,
}

DEFAULT_EVAL_LIMITS: Dict[str, Any] = {
    "max_depth": 10,
    "max_node_visits": 1000,
}

DEFAULT_EVENT_BUS: Dict[str, Any] = {
    "buffer_capacity": 100,
    "delivery": {
        "max_delivery_attempts": 3,
        "initial_retry_delay": 0.1,
        "retry_backoff": ["Fixed", 0.5],
        "delivery_timeout": 5.0,
    },
    "dlq_enabled": False,
    "dlq_max_size": 10,
    "critical_event_types": [],
}

RUNTIME_CONFIG_DEFAULTS: Dict[str, Any] = {
    "default_quota": DEFAULT_QUOTA,
    "shutdown": DEFAULT_SHUTDOWN,
    "eval_limits": DEFAULT_EVAL_LIMITS,
    "llm_providers": [],
    "parallel_tool_execution": True,
    "event_retention_seconds": 604800.0,
    "event_bus": DEFAULT_EVENT_BUS,
}


def _load(data: Union[str, Dict[str, Any]]) -> Dict[str, Any]:
    """Accept either a JSON string or an already-decoded object."""
    if isinstance(data, str):
        parsed = json.loads(data)
    else:
        parsed = data
    if not isinstance(parsed, dict):
        raise ValueError("model input must be a JSON object")
    return parsed


def _json_string(data: Union[str, Dict[str, Any]]) -> str:
    return data if isinstance(data, str) else json.dumps(data)


def _merge(base: Dict[str, Any], override: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """One-level deep merge used for the free-form config escape hatches."""
    merged = dict(base)
    if override:
        for key, value in override.items():
            if isinstance(value, dict) and isinstance(merged.get(key), dict):
                merged[key] = _merge(merged[key], value)
            else:
                merged[key] = value
    return merged


def _provider_name(value: Any) -> str:
    """Accept ``"openai"`` and the OCaml ``["Openai"]`` form."""
    if isinstance(value, list) and value:
        return str(value[0]).lower()
    return str(value)


@dataclass
class Sqlite:
    """Persistence backend: an on-disk (or ``:memory:``) SQLite database."""

    path: str = ":memory:"

    def to_json(self) -> List[str]:
        return ["Sqlite", self.path]

    def to_dict(self) -> List[str]:
        return self.to_json()

    @classmethod
    def from_json(cls, data: Union[str, List[Any]]) -> "Sqlite":
        parsed = json.loads(data) if isinstance(data, str) else data
        if isinstance(parsed, dict) and "path" in parsed:
            return cls(path=str(parsed["path"]))
        if isinstance(parsed, list) and len(parsed) == 2:
            return cls(path=str(parsed[1]))
        if isinstance(parsed, str):
            return cls(path=parsed)
        raise ValueError("persistence must be ['Sqlite', path] or a path string")


@dataclass
class ModelConfig:
    """Model selection and sampling parameters."""

    model_name: str
    provider: str = "openai"
    api_base: Optional[str] = None
    temperature: float = 0.7
    max_tokens: Optional[int] = None
    top_p: Optional[float] = None
    stop_sequences: Optional[List[str]] = None
    thinking_budget_tokens: Optional[int] = None
    context_window: Optional[int] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "provider": self.provider,
            "model_name": self.model_name,
            "api_base": self.api_base,
            "temperature": self.temperature,
            "max_tokens": self.max_tokens,
            "top_p": self.top_p,
            "stop_sequences": self.stop_sequences,
            "thinking_budget_tokens": self.thinking_budget_tokens,
            "context_window": self.context_window,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict())

    @classmethod
    def from_json(cls, data: Union[str, Dict[str, Any]]) -> "ModelConfig":
        raw = _load(data)
        return cls(
            model_name=str(raw["model_name"]),
            provider=_provider_name(raw.get("provider", "openai")),
            api_base=raw.get("api_base"),
            temperature=float(raw.get("temperature", 0.7)),
            max_tokens=raw.get("max_tokens"),
            top_p=raw.get("top_p"),
            stop_sequences=raw.get("stop_sequences"),
            thinking_budget_tokens=raw.get("thinking_budget_tokens"),
            context_window=raw.get("context_window"),
        )


@dataclass
class ToolSpec:
    """A tool descriptor registered with the runtime."""

    name: str
    description: str = ""
    input_schema: Optional[Dict[str, Any]] = None
    timeout: Optional[float] = None
    concurrency_limit: Optional[int] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "input_schema": (
                self.input_schema
                if self.input_schema is not None
                else {"type": "object"}
            ),
            "timeout": self.timeout,
            "concurrency_limit": self.concurrency_limit,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict())

    @classmethod
    def from_json(cls, data: Union[str, Dict[str, Any]]) -> "ToolSpec":
        raw = _load(data)
        return cls(
            name=str(raw["name"]),
            description=str(raw.get("description", "")),
            input_schema=raw.get("input_schema"),
            timeout=raw.get("timeout"),
            concurrency_limit=raw.get("concurrency_limit"),
        )


@dataclass
class AgentConfig:
    """An agent definition accepted by ``Runtime.register_agent``."""

    id: str
    model: ModelConfig
    system_prompt: str = ""
    tools: List[Union[ToolSpec, Dict[str, Any]]] = field(default_factory=list)
    max_iterations: int = 1_000_000
    max_execution_time: Optional[float] = None
    early_stopping_method: str = "force"
    on_max_tokens: Optional[str] = None
    max_continuation_chunks: Optional[int] = None
    context_compression_threshold: Optional[float] = None
    compression_cooldown_messages: Optional[int] = None
    context_window_override: Optional[int] = None

    def to_dict(self) -> Dict[str, Any]:
        tools = [
            tool.to_dict() if isinstance(tool, ToolSpec) else ToolSpec.from_json(tool).to_dict()
            for tool in self.tools
        ]
        return {
            "id": self.id,
            "system_prompt": self.system_prompt,
            "model": self.model.to_dict(),
            "tools": tools,
            "max_iterations": self.max_iterations,
            "max_execution_time": self.max_execution_time,
            "early_stopping_method": self.early_stopping_method,
            "on_max_tokens": self.on_max_tokens,
            "max_continuation_chunks": self.max_continuation_chunks,
            "context_compression_threshold": self.context_compression_threshold,
            "compression_cooldown_messages": self.compression_cooldown_messages,
            "context_window_override": self.context_window_override,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict())

    @classmethod
    def from_json(cls, data: Union[str, Dict[str, Any]]) -> "AgentConfig":
        raw = _load(data)
        tools: List[Union[ToolSpec, Dict[str, Any]]] = []
        for tool in raw.get("tools") or []:
            tools.append(ToolSpec.from_json(tool))
        model = raw.get("model")
        if not isinstance(model, dict):
            raise ValueError("agent config requires a 'model' object")
        return cls(
            id=str(raw["id"]),
            model=ModelConfig.from_json(model),
            system_prompt=str(raw.get("system_prompt", "")),
            tools=tools,
            max_iterations=int(raw.get("max_iterations", 1_000_000)),
            max_execution_time=raw.get("max_execution_time"),
            early_stopping_method=str(raw.get("early_stopping_method", "force")),
            on_max_tokens=raw.get("on_max_tokens"),
            max_continuation_chunks=raw.get("max_continuation_chunks"),
            context_compression_threshold=raw.get("context_compression_threshold"),
            compression_cooldown_messages=raw.get("compression_cooldown_messages"),
            context_window_override=raw.get("context_window_override"),
        )


@dataclass
class MCPSampling:
    """Opt-in MCP sampling policy (v0.18 W3).

    ``Disabled`` is the runtime default. ``MCPSampling`` corresponds to the
    ``Auto`` variant: the server's ``sampling/createMessage`` is answered by one
    plain LLM call using ``model``, with hard per-invoke and token limits.
    """

    model: ModelConfig
    max_tokens: int = 1024
    max_requests_per_invoke: int = 8
    timeout: float = 60.0

    def to_dict(self) -> List[Any]:
        return ["Auto", {
            "model": self.model.to_dict(),
            "max_tokens": self.max_tokens,
            "max_requests_per_invoke": self.max_requests_per_invoke,
            "timeout": self.timeout,
        }]

    def to_json(self) -> str:
        return json.dumps(self.to_dict())

    @classmethod
    def from_json(cls, data: Union[str, Dict[str, Any], List[Any]]) -> "MCPSampling":
        raw = json.loads(data) if isinstance(data, str) else data
        if isinstance(raw, list) and len(raw) == 2 and raw[0] == "Auto":
            fields = raw[1]
            if not isinstance(fields, dict):
                raise ValueError("Auto sampling policy requires an object")
            return cls(
                model=ModelConfig.from_json(fields["model"]),
                max_tokens=int(fields.get("max_tokens", 1024)),
                max_requests_per_invoke=int(fields.get("max_requests_per_invoke", 8)),
                timeout=float(fields.get("timeout", 60.0)),
            )
        raise ValueError("only the Auto sampling policy can be constructed")


@dataclass
class RuntimeConfig:
    """Runtime configuration accepted by ``Runtime``.

    The four config blocks that have no typed surface yet (``event_bus``,
    ``default_quota``, ``shutdown``, ``eval_limits``) accept overrides as
    plain dicts; they are merged over the same defaults the JSON path uses.
    """

    persistence: Union[Sqlite, str] = field(default_factory=Sqlite)
    event_bus: Optional[Dict[str, Any]] = None
    default_quota: Optional[Dict[str, Any]] = None
    shutdown: Optional[Dict[str, Any]] = None
    eval_limits: Optional[Dict[str, Any]] = None
    llm_providers: List[Tuple[str, Any]] = field(default_factory=list)
    parallel_tool_execution: bool = True
    event_retention_seconds: float = 604800.0
    max_tool_schema_tokens: Optional[int] = None
    max_tool_result_chars: int = 100_000
    bash_confirm: Optional[Dict[str, Any]] = None
    mcp_sampling: Optional[MCPSampling] = None

    def _persistence_dict(self) -> List[str]:
        if isinstance(self.persistence, Sqlite):
            return self.persistence.to_json()
        if isinstance(self.persistence, str):
            return ["Sqlite", self.persistence]
        if isinstance(self.persistence, (list, tuple)) and len(self.persistence) == 2:
            return [str(self.persistence[0]), str(self.persistence[1])]
        raise ValueError("persistence must be a Sqlite, a path string, or ['Sqlite', path]")

    def to_dict(self) -> Dict[str, Any]:
        cfg: Dict[str, Any] = {
            "persistence": self._persistence_dict(),
            "event_bus": _merge(DEFAULT_EVENT_BUS, self.event_bus),
            "default_quota": _merge(DEFAULT_QUOTA, self.default_quota),
            "shutdown": _merge(DEFAULT_SHUTDOWN, self.shutdown),
            "eval_limits": _merge(DEFAULT_EVAL_LIMITS, self.eval_limits),
            "llm_providers": [list(entry) for entry in self.llm_providers],
            "parallel_tool_execution": self.parallel_tool_execution,
            "event_retention_seconds": self.event_retention_seconds,
        }
        if self.max_tool_schema_tokens is not None:
            cfg["max_tool_schema_tokens"] = self.max_tool_schema_tokens
        if self.max_tool_result_chars != 100_000:
            cfg["max_tool_result_chars"] = self.max_tool_result_chars
        if self.bash_confirm is not None:
            cfg["bash_confirm"] = dict(self.bash_confirm)
        if self.mcp_sampling is not None:
            cfg["mcp_sampling"] = self.mcp_sampling.to_dict()
        return cfg

    def to_json(self) -> str:
        return json.dumps(self.to_dict())

    @classmethod
    def from_json(cls, data: Union[str, Dict[str, Any]]) -> "RuntimeConfig":
        raw = _load(data)
        persistence = raw.get("persistence", [":memory:"])
        return cls(
            persistence=Sqlite.from_json(persistence),
            event_bus=raw.get("event_bus"),
            default_quota=raw.get("default_quota"),
            shutdown=raw.get("shutdown"),
            eval_limits=raw.get("eval_limits"),
            llm_providers=[
                (str(entry[0]), entry[1])
                for entry in (raw.get("llm_providers") or [])
                if isinstance(entry, (list, tuple)) and len(entry) == 2
            ],
            parallel_tool_execution=bool(raw.get("parallel_tool_execution", True)),
            event_retention_seconds=float(raw.get("event_retention_seconds", 604800.0)),
            max_tool_schema_tokens=raw.get("max_tool_schema_tokens"),
            max_tool_result_chars=int(raw.get("max_tool_result_chars", 100_000)),
            bash_confirm=raw.get("bash_confirm"),
            mcp_sampling=(
                MCPSampling.from_json(raw["mcp_sampling"])
                if isinstance(raw.get("mcp_sampling"), list)
                else None
            ),
        )


@dataclass(frozen=True)
class Usage:
    """Token accounting from one provider call."""

    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0
    cached_tokens: int = 0
    cache_creation_input_tokens: int = 0
    cache_read_input_tokens: int = 0

    def to_dict(self) -> Dict[str, int]:
        return {
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "total_tokens": self.total_tokens,
            "cached_tokens": self.cached_tokens,
            "cache_creation_input_tokens": self.cache_creation_input_tokens,
            "cache_read_input_tokens": self.cache_read_input_tokens,
        }

    @classmethod
    def from_json(cls, data: Union[str, Dict[str, Any]]) -> "Usage":
        raw = _load(data)
        return cls(
            prompt_tokens=int(raw.get("prompt_tokens") or 0),
            completion_tokens=int(raw.get("completion_tokens") or 0),
            total_tokens=int(raw.get("total_tokens") or 0),
            cached_tokens=int(raw.get("cached_tokens") or 0),
            cache_creation_input_tokens=int(raw.get("cache_creation_input_tokens") or 0),
            cache_read_input_tokens=int(raw.get("cache_read_input_tokens") or 0),
        )


class ToolCallDict(TypedDict):
    id: str
    name: str
    arguments: Any


@dataclass(frozen=True)
class ToolCall:
    """A tool call requested by the model."""

    id: str
    name: str
    arguments: Any = None

    def to_dict(self) -> ToolCallDict:
        return {"id": self.id, "name": self.name, "arguments": self.arguments}

    @classmethod
    def from_json(cls, data: Union[str, Dict[str, Any]]) -> "ToolCall":
        raw = _load(data)
        return cls(
            id=str(raw.get("id", "")),
            name=str(raw.get("name", "")),
            arguments=raw.get("arguments"),
        )


_FINISH_REASONS = {
    "stop": "stop",
    "tool_calls": "tool_calls",
    "max_tokens": "max_tokens",
    "content_filter": "content_filter",
}


def _finish_reason(value: Any) -> str:
    if isinstance(value, list) and value:
        value = value[0]
    text = str(value).lower() if value is not None else "stop"
    return _FINISH_REASONS.get(text, text)


@dataclass(frozen=True)
class InvokeResult:
    """Decoded ``llm_response`` envelope returned by ``Runtime.invoke``."""

    text: Optional[str]
    reasoning: List[Dict[str, Any]] = field(default_factory=list)
    tool_calls: List[ToolCall] = field(default_factory=list)
    finish_reason: str = "stop"
    usage: Usage = field(default_factory=Usage)
    model: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "text": self.text,
            "reasoning": list(self.reasoning),
            "tool_calls": [call.to_dict() for call in self.tool_calls],
            "finish_reason": [self.finish_reason.capitalize()],
            "usage": self.usage.to_dict(),
            "model": self.model,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict())

    @classmethod
    def from_json(cls, data: Union[str, Dict[str, Any]]) -> "InvokeResult":
        raw = _load(data)
        if "error" in raw:
            raise ValueError(str(raw["error"]))
        status = raw.get("status")
        if status == "cancelled":
            raise ValueError(f"invoke was cancelled: {raw.get('reason')}")
        # The FFI envelope is {"status": "ok", "content": <llm_response>}.
        # Accept the bare llm_response too so callers can decode a persisted
        # envelope or a raw provider fixture with the same class.
        for wrapper in ("content", "response"):
            inner = raw.get(wrapper)
            if isinstance(inner, dict):
                raw = inner
                break
        calls = [
            ToolCall.from_json(call) if isinstance(call, dict) else ToolCall(id="", name="", arguments=call)
            for call in (raw.get("tool_calls") or [])
        ]
        return cls(
            text=raw.get("text"),
            reasoning=list(raw.get("reasoning") or []),
            tool_calls=calls,
            finish_reason=_finish_reason(raw.get("finish_reason")),
            usage=Usage.from_json(raw.get("usage") or {}),
            model=str(raw.get("model", "")),
        )


@dataclass(frozen=True)
class Error:
    """An error envelope returned by the FFI (``{"error": ...}``)."""

    message: str
    category: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        payload: Dict[str, Any] = {"error": self.message}
        if self.category is not None:
            payload["category"] = self.category
        return payload

    def to_json(self) -> str:
        return json.dumps(self.to_dict())

    @classmethod
    def from_json(cls, data: Union[str, Dict[str, Any]]) -> "Error":
        raw = data if isinstance(data, dict) else json.loads(_json_string(data))
        if isinstance(raw, str):
            return cls(message=raw)
        if not isinstance(raw, dict) or "error" not in raw:
            raise ValueError("not an error envelope")
        error = raw["error"]
        if isinstance(error, dict):
            return cls(
                message=str(error.get("message", "")),
                category=error.get("category"),
            )
        return cls(message=str(error), category=raw.get("category"))
