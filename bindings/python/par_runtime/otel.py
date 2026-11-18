"""Optional OpenTelemetry adapter for PAR spans (v0.18 W2-S4).

The runtime produces spans; this module turns them into OTel spans. It is an
optional extra so the base install stays dependency-free::

    pip install "par-runtime[otel]"

Usage::

    from opentelemetry.sdk.trace import TracerProvider
    from par_runtime.otel import OTelTracer

    provider = TracerProvider()
    otel = OTelTracer(provider.get_tracer("my-service"))
    with Runtime(RuntimeConfig()) as rt:
        otel.attach(rt)
        ...

Span names and the frozen attribute subset (`gen_ai.system`,
`gen_ai.request.model`, `tool.name`, `mcp.server`) are the contract; anything
else uses the `par.` namespace.
"""
from typing import Any, Dict, Optional

__all__ = ["OTelTracer"]


class OTelTracer:
    """Bridge PAR spans to an OpenTelemetry ``Tracer``.

    Reuses the W3C ids produced by the runtime: the OTel span carries the same
    ``trace_id`` and ``span_id``, and a child's parent context is built from
    ``parent_span_id`` rather than relying on the current OTel context.
    """

    def __init__(self, tracer: Optional[Any] = None):
        from opentelemetry import trace

        self._trace = trace
        self._tracer = tracer or trace.get_tracer("par_runtime")
        self._spans: Dict[str, Any] = {}
        self._otel_ids: Dict[str, Any] = {}

    def attach(self, runtime: Any) -> None:
        """Install this adapter as the runtime's tracer.

        ``runtime`` is a synchronous :class:`par_runtime.Runtime`. For
        :class:`par_runtime.AsyncRuntime`, await
        ``rt.set_trace_callbacks(otel.on_start, otel.on_end)`` instead.
        """
        runtime.set_trace_callbacks(self.on_start, self.on_end)

    def on_start(self, span: Dict[str, Any]) -> None:
        from opentelemetry.trace import (
            NonRecordingSpan,
            SpanContext,
            TraceFlags,
            set_span_in_context,
        )

        runtime_span_id = str(span["span_id"])
        parent_id = span.get("parent_span_id")
        if parent_id and str(parent_id) in self._otel_ids:
            # Normal case: the parent was already started by this adapter.
            parent_context = self._otel_ids[str(parent_id)]
        else:
            # Pin the runtime trace id. For the root this is a synthetic
            # remote parent: OTel assigns its own span ids, but accepts the
            # trace id and flags we give it.
            parent_context = SpanContext(
                trace_id=int(span["trace_id"], 16),
                span_id=int(parent_id or runtime_span_id, 16),
                is_remote=True,
                trace_flags=TraceFlags(TraceFlags.SAMPLED),
            )
        context = set_span_in_context(NonRecordingSpan(parent_context))
        otel_span = self._tracer.start_span(
            span["name"],
            context=context,
            attributes=dict(span.get("attributes") or {}),
            start_time=int(float(span["started_at"]) * 1_000_000_000),
        )
        self._spans[runtime_span_id] = otel_span
        self._otel_ids[runtime_span_id] = otel_span.get_span_context()

    def on_end(self, span: Dict[str, Any], status: str) -> None:
        from opentelemetry.trace import Status, StatusCode

        otel_span = self._spans.pop(str(span["span_id"]), None)
        if otel_span is None:
            return
        if status == "ok":
            otel_span.set_status(Status(StatusCode.OK))
        elif status == "cancelled":
            otel_span.set_attribute("par.cancelled", True)
            otel_span.set_status(Status(StatusCode.ERROR, "cancelled"))
        else:
            otel_span.set_status(Status(StatusCode.ERROR))
        otel_span.end()
