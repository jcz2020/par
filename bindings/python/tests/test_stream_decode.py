"""Decoding of streaming chunks into Python events.

``test_streaming.py`` is skipped wholesale (its ``_StreamReader`` fixture
predates the current API), so the chunk-decoding contract is pinned here
instead. Only ``_decode_event`` is exercised, which is the part that turns an
``llm_response_chunk`` into a Python object.
"""

import pytest

from par_runtime import Event, ReasoningDelta, ReasoningSignature, TextDelta
from par_runtime.runtime import _decode_event


def test_reasoning_delta_is_not_decoded_as_text():
    """A reasoning chunk used to fall through to the text branch, which showed
    a reasoning model's chain of thought as part of the answer."""
    event = _decode_event(["Reasoning_delta", {"text": "step one"}])
    assert isinstance(event, ReasoningDelta)
    assert event.text == "step one"


def test_reasoning_signature_is_decoded():
    event = _decode_event(["Reasoning_signature", {"signature": "sig-1"}])
    assert isinstance(event, ReasoningSignature)
    assert event.signature == "sig-1"


def test_text_delta_still_decodes_as_text():
    event = _decode_event(["Text_delta", {"text": "hello"}])
    assert isinstance(event, TextDelta)
    assert event.text == "hello"


def test_event_union_covers_reasoning():
    assert ReasoningDelta in Event.__args__
    assert ReasoningSignature in Event.__args__


def test_reasoning_events_are_frozen():
    for event in (ReasoningDelta("r"), ReasoningSignature("s")):
        with pytest.raises(AttributeError):
            event.text = "mutate"  # type: ignore[misc]
