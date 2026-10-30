"""Python bindings for P-A-R (Programmable Agent Runtime)."""
from par_runtime._errors import (
    PARError,
    PARInitError,
    PARInvokeError,
    PARToolError,
    PARWorkflowError,
)
from par_runtime.runtime import (
    Runtime,
    Done,
    Event,
    TextDelta,
    ToolCallStart,
    ToolCallDelta,
    UsageUpdate,
)
from par_runtime.content import (
    MAX_IMAGE_BYTES,
    SUPPORTED_IMAGE_MEDIA_TYPES,
    ContentBlock,
    ImageDetail,
    ImageError,
    image_base64,
    image_file,
    image_url,
    text,
)

__version__ = "0.12.0-beta.20261023"

__all__ = [
    "Runtime",
    "ContentBlock",
    "ImageDetail",
    "ImageError",
    "MAX_IMAGE_BYTES",
    "SUPPORTED_IMAGE_MEDIA_TYPES",
    "text",
    "image_url",
    "image_base64",
    "image_file",
    "Done",
    "Event",
    "TextDelta",
    "ToolCallStart",
    "ToolCallDelta",
    "UsageUpdate",
    "PARError",
    "PARInitError",
    "PARInvokeError",
    "PARToolError",
    "PARWorkflowError",
]
