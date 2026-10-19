"""Content constructors using the SDK's existing tagged-array JSON format."""

import base64
from pathlib import Path
from typing import Any, Literal


ContentBlock = list[Any]
ImageDetail = Literal["auto", "low", "high"]


def text(value: str) -> ContentBlock:
    """Build a text block for :meth:`Runtime.invoke_content`."""
    return ["Text_block", {"text": value, "cache_control": None}]


def image_url(
    url: str, *, media_type: str = "image/png", detail: ImageDetail | None = None,
) -> ContentBlock:
    """Reference a remote image; the provider, not PAR, fetches the URL."""
    return ["Image_block", {
        "source": ["Url", url], "media_type": media_type, "data": "",
        "detail": detail, "cache_control": None,
    }]


def image_base64(
    data: str, *, media_type: str = "image/png", detail: ImageDetail | None = None,
) -> ContentBlock:
    """Build an image block from already base64-encoded bytes."""
    return ["Image_block", {
        "source": ["Base64", data], "media_type": media_type, "data": "",
        "detail": detail, "cache_control": None,
    }]


def image_file(
    path: str | Path, *, media_type: str | None = None, detail: ImageDetail | None = None,
) -> ContentBlock:
    """Read an image, raising OSError on I/O failure; MIME type is overridable."""
    path = Path(path)
    media_types = {
        ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp",
    }
    mime = media_type if media_type is not None else media_types.get(path.suffix.lower(), "image/png")
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return image_base64(encoded, media_type=mime, detail=detail)
